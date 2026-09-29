import ArgumentParser
import Foundation
import MacUpCore

struct AskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Ask for a rule change in plain words. MacUp shows the exact change and asks before making it.",
        discussion: """
            Part of AI help from TypeSafe, which is off until `macup ai enable`. MacUp \
            reads what is installed (read-only), then sends what you typed and the names \
            of those packages to TypeSafe, which picks from MacUp's own short list of \
            actions and from the packages MacUp found; it never invents either. MacUp \
            then shows exactly what it would write, and where, and changes nothing until \
            you say yes. The change is made by the same code as `macup policy set`.

            At a terminal MacUp asks. Anywhere else, and with --json, it asks nobody and \
            changes nothing, and prints the command that would. --yes makes the change \
            without asking only when TypeSafe is at least 85% sure and the change makes \
            MacUp more careful: it never turns on Auto Update, turns a package manager \
            back on, or stops skipping a version without you seeing it first.

            Examples:
              macup ask "stop updating mysql"
              macup ask "ask me before any postgres update"
              macup ask "turn off mise"
              macup ask "skip this node version"
              macup ask "note on php: waiting for 8.4 support"
              macup ask "why is mysql held?"
            """
    )

    @Argument(help: "What you would like, in quotes.")
    var words: [String]

    @Flag(name: [.customShort("y"), .long], help: "Make the change without asking, when MacUp is sure and the change only adds caution.")
    var yes = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1). Never asks anything.")
    var json = false

    func validate() throws {
        guard !words.joined().trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ValidationError("Say what you would like, for example: macup ask \"stop updating mysql\"")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        // Refused before the check, so nobody waits for a check to be told AI
        // help is off.
        if let refusal = context.ai.service.status(loaded, environment: context.environment).refusal {
            throw context.fail(refusal)
        }

        if !json { context.printError("Reading what is installed on this Mac (read-only)…") }
        let engine = context.engine
        let environment = context.checkEnvironment
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(configuration: loaded, options: CheckOptions(includeInventoryItems: true), environment: environment)
        }
        if report.cancelled {
            context.printError("Cancelled before MacUp finished looking. Nothing was sent or changed.")
            throw MacUpExitCode.cancelled.exitCode
        }

        let interpretation: AskInterpretation
        do {
            interpretation = try await context.ai.service.ask(
                words.joined(separator: " "),
                context: AskContext(
                    report: context.aiCautioned(report, configuration: loaded),
                    configuration: loaded,
                    homeDirectory: context.homeDirectory
                ),
                environment: context.environment
            )
        } catch let error as AIError {
            throw context.fail(error)
        }

        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        if !json { context.print(AskRenderer(interpretation: interpretation, style: style).render()) }

        var applied: PolicyChange?
        var notApplied: String?
        if let proposal = interpretation.proposal {
            switch confirmation(for: proposal, context: context) {
            case .confirmed:
                applied = try await apply(proposal, paths: paths, context: context)
            case .declined(let reason):
                notApplied = reason
            }
        }

        if json {
            context.print(try JSONOutput.encode(AskDocument(interpretation: interpretation, applied: applied, notApplied: notApplied)))
            return
        }
        if let applied {
            context.print(style.text(applied.summary))
            for warning in applied.warnings { context.print("  warning: " + style.text(warning)) }
            if applied.changed { context.print(style.dim("Saved to " + style.path(loaded.path) + ".")) }
        } else if let notApplied {
            context.print(notApplied)
        }
    }

    private enum Confirmation {
        case confirmed
        case declined(String)
    }

    /// Whether the user has agreed to this exact change. Anything short of an
    /// explicit yes is a no, and says how to make the change instead.
    private func confirmation(for proposal: AskProposal, context: CLIContext) -> Confirmation {
        let instead = "Nothing was changed. To make this change yourself, run: \(proposal.command)"
        if yes {
            if proposal.appliesWithoutReview { return .confirmed }
            return .declined(proposal.loosens
                ? "--yes never makes a change that lets MacUp do more without asking. \(instead)"
                : "--yes needs TypeSafe to be at least \(AskMacUp.percent(AskMacUp.unattendedConfidence)) sure, and it was \(AskMacUp.percent(proposal.confidence)). \(instead)")
        }
        if json { return .declined("--json never asks. \(instead)") }
        guard context.standardOutputIsTerminal else {
            return .declined("This is not a terminal, so MacUp asked nobody. \(instead)")
        }
        context.print("")
        guard context.askToProceed("Make this change?") else { return .declined("Nothing was changed.") }
        return .confirmed
    }

    /// The change, through the same gate and the same editor as `macup policy`.
    private func apply(_ proposal: AskProposal, paths: MacUpPaths, context: CLIContext) async throws -> PolicyChange {
        let store = ConfigurationStore(paths: paths)
        let current = store.load()
        try context.requireReadableConfiguration(current)
        try await context.requireApproval("change what MacUp may update", current.configuration, paths: paths)
        do {
            return try proposal.apply(with: PolicyEditor(store: store))
        } catch let error as MacUpError {
            throw AISettingsOutput.fail(error, context: context)
        }
    }
}

/// Human-readable output for `macup ask`.
struct AskRenderer {
    let interpretation: AskInterpretation
    let style: TextStyle

    func render() -> String {
        var lines = [style.bold("Ask MacUp") + style.dim(" · TypeSafe " + style.safe(interpretation.model))]
        lines.append("You asked: " + style.safe(interpretation.request))
        if interpretation.knownItems > interpretation.offeredItems {
            lines.append(style.dim("MacUp offered TypeSafe the \(interpretation.offeredItems) packages closest to that, of \(interpretation.knownItems)."))
        }
        lines.append("")
        lines.append(style.text(interpretation.message))

        switch interpretation.outcome {
        case .proposal(let proposal):
            lines.append("")
            lines += describe(proposal).map { "  " + $0 }
        case .explanation(let explanation):
            lines.append("")
            lines += explanation.lines.map { "  " + style.text($0) }
        case .unsure(let guesses), .noMatch(let guesses):
            if !guesses.isEmpty {
                lines.append("")
                let width = guesses.map { style.safe($0.title).count }.max() ?? 0
                for guess in guesses {
                    lines.append("  " + TextStyle.pad(AskMacUp.percent(guess.confidence), to: 4) + "  "
                        + TextStyle.pad(style.safe(guess.title), to: width) + "  " + style.dim(style.safe(guess.command)))
                }
                lines.append("")
                lines.append("Nothing was changed. Run one of these, or ask again in other words.")
            }
        case .notPossible, .notUnderstood:
            break
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ proposal: AskProposal) -> [String] {
        var lines = [style.bold(style.safe(proposal.title))]
        lines.append(style.text(proposal.effect))
        lines.append(style.safe(proposal.path) + ": " + style.safe(proposal.currentValue) + " → " + style.safe(proposal.newValue))
        if proposal.loosens {
            lines.append("This lets MacUp do more without asking you.")
        }
        lines.append(style.dim("Same as: " + style.safe(proposal.command)))
        return lines
    }
}

/// The machine-readable form of `macup ask`.
struct AskDocument: Encodable {
    let schemaVersion = 1
    let kind = "ask"
    let macupVersion = MacUp.version
    let interpretation: AskInterpretation
    /// The change MacUp made, when the user confirmed one.
    let applied: PolicyChange?
    /// Why a proposal was not applied, when there was one.
    let notApplied: String?
}
