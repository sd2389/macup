import ArgumentParser
import Foundation
import MacUpCore

struct DependentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dependents",
        abstract: "Show what on this Mac depends on an installed Homebrew formula (read-only).",
        discussion: """
            Asks Homebrew which installed formulae and casks need the formula to run, \
            directly or through another formula: the software an upgrade of it could \
            affect. MacUp runs `brew uses --installed`, which changes nothing but reads \
            the install record of every formula, so it runs only when you ask; `macup \
            check` never does.

            When MacUp upgrades a formula, it asks Homebrew to leave these alone, so none \
            of them changes without your review.

            Exit status: 0 Homebrew answered (including "nothing"); 2 Homebrew could not \
            be asked, or named something MacUp could not read; 3 the configuration is \
            invalid; 64 not a Homebrew formula, or not installed; 130 cancelled.
            """
    )

    @Argument(help: "The formula, for example brew:openssl@3.")
    var item: String

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Also show every command MacUp ran.")
    var verbose = false

    func validate() throws {
        try PackageSelection.validate([item])
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        guard let id = try? PackageID(parsing: item) else { throw MacUpExitCode.usage.exitCode }

        // The same providers as `macup check`, so both see the same Mac.
        let lookup = DependentsLookup(providers: context.engine.providers)
        let environment = context.checkEnvironment
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await lookup.run(id, configuration: loaded, environment: environment)
        }

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(DependentsRenderer(report: report, style: style, verbose: verbose).render())
        }

        switch report.outcome {
        case .cancelled: throw MacUpExitCode.cancelled.exitCode
        case .unsupported, .notInstalled: throw MacUpExitCode.usage.exitCode
        case .failed: throw MacUpExitCode.providerErrors.exitCode
        case .listed: break
        }
        if report.resultsIncomplete { throw MacUpExitCode.providerErrors.exitCode }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

/// Human-readable output for `macup dependents`.
///
/// An answer of "nothing" is said plainly, and an answer MacUp does not have
/// is never shown as one: a failed lookup says what failed, not that nothing
/// depends on the formula.
struct DependentsRenderer {
    let report: DependentsReport
    let style: TextStyle
    let verbose: Bool

    func render() -> String {
        let name = style.safe(report.item.name)
        var lines = [style.bold("MacUp dependents") + style.dim(" · read-only · nothing was changed")]
        lines.append(style.safe(report.item.rawValue))
        lines.append("")

        switch report.outcome {
        case .listed:
            let dependents = report.dependents ?? []
            if dependents.isEmpty {
                lines.append("Nothing installed with Homebrew needs \(name).")
            } else {
                lines.append(dependents.count == 1
                    ? "1 installed item needs \(name), directly or through another formula:"
                    : "\(dependents.count) installed items need \(name), directly or through another formula:")
                lines += dependents.map { "  " + style.safe($0.rawValue) }
                lines.append("")
                lines.append(dependents.count == 1
                    ? "When MacUp upgrades \(name), it asks Homebrew to leave this one alone rather than upgrade or "
                        + "rebuild it. It uses the new \(name) the next time it starts."
                    : "When MacUp upgrades \(name), it asks Homebrew to leave these alone rather than upgrade or "
                        + "rebuild them. They use the new \(name) the next time they start.")
            }
            if report.resultsIncomplete {
                lines.append("Homebrew also named something MacUp could not read, so this list may be missing it:")
            }
            for finding in report.findings {
                lines.append("  " + style.dim(style.text(finding.detail ?? finding.title)))
            }
        case .cancelled:
            lines.append("Cancelled before Homebrew answered, so MacUp cannot say what depends on \(name).")
        case .unsupported, .notInstalled, .failed:
            if let error = report.error {
                lines += errorLines(error)
            } else {
                lines.append("MacUp could not find out what depends on \(name).")
            }
        }

        if verbose {
            lines.append("")
            lines += commands()
        }
        return lines.joined(separator: "\n")
    }

    private func errorLines(_ error: MacUpError) -> [String] {
        var lines = ["error: " + style.text(error.message)]
        if let command = error.command {
            let exit = error.exitStatus.map { " (exit status \($0))" } ?? ""
            lines.append("  Ran: " + style.text(command) + exit)
        }
        if let detail = error.detail {
            lines += detail.split(separator: "\n").prefix(verbose ? 12 : 4).map { "  " + style.dim(style.text(String($0))) }
        }
        if let suggestion = error.recoverySuggestion {
            lines.append("  " + style.text(suggestion))
        }
        return lines
    }

    private func commands() -> [String] {
        guard !report.commands.isEmpty else { return ["No commands were run."] }
        var lines = ["Commands MacUp ran" + (report.commands.allSatisfy { $0.effect == .readOnly } ? " (all read-only):" : ":")]
        for record in report.commands {
            let outcome: String
            switch record.outcome {
            case .exited: outcome = "exit \(record.exitStatus.map(String.init) ?? "?")"
            case .signaled: outcome = "signaled"
            case .timedOut: outcome = "timed out"
            case .cancelled: outcome = "cancelled"
            case .refused: outcome = "refused"
            case .failedToLaunch: outcome = "not launched"
            }
            lines.append("  " + style.dim(String(format: "%6.2fs  %@", record.durationSeconds, TextStyle.pad(outcome, to: 12)))
                + style.text(record.command))
        }
        return lines
    }
}
