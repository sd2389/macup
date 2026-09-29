import ArgumentParser
import Foundation
import MacUpCore

struct InsightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "insight",
        abstract: "Ask TypeSafe whether an update needs extra care. An answer can only add caution.",
        discussion: """
            Part of AI help from TypeSafe, which is off until `macup ai enable`. For each \
            update, MacUp sends the package's ID, name, package manager, and the two \
            versions, and asks what kind of software it is and whether a major upgrade of \
            it commonly migrates its data. Code decides what follows: only a confident \
            judgment that a major upgrade puts data at risk adds a note, and makes an item \
            set to Auto Update wait for you. Nothing is ever judged safer than it was.

            The answer is saved on this Mac, so the same version change is not sent again, \
            and `macup check`, `plan`, and `update` apply saved cautions while AI help is \
            on. `macup ai forget` deletes them. macOS updates are never sent: they always \
            wait for you anyway.

            Examples:
              macup insight brew:mysql
              macup insight --all
              macup insight brew:postgresql@16 --fresh
            """
    )

    @Argument(help: "Updates to ask about, for example brew:mysql.")
    var items: [String] = []

    @Flag(help: "Ask about every update MacUp found, except macOS updates.")
    var all = false

    @Flag(help: "Ask again even when MacUp saved an answer for this version change.")
    var fresh = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        guard all != !items.isEmpty else {
            throw ValidationError(all ? "Name updates or pass --all, not both." : "Name at least one update, such as brew:mysql, or pass --all.")
        }
        try PackageSelection.validate(items)
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        if let refusal = context.ai.service.status(loaded, environment: context.environment).refusal {
            throw context.fail(refusal)
        }

        if !json { context.printError("Looking for updates (read-only)…") }
        let engine = context.engine
        let environment = context.checkEnvironment
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(configuration: loaded, environment: environment)
        }
        if report.cancelled {
            context.printError("Cancelled before MacUp finished looking. Nothing was sent.")
            throw MacUpExitCode.cancelled.exitCode
        }

        let candidates: [UpdateCandidate]
        if all {
            candidates = report.updates.filter { $0.provider != .macos }
        } else {
            let wanted = PackageSelection.parse(items) ?? []
            let unmatched = wanted.subtracting(report.updates.map(\.id)).sorted()
            guard unmatched.isEmpty else {
                context.printError("error: " + PackageSelection.unmatchedMessage(unmatched))
                context.printError("Nothing was sent. `macup check` lists the updates MacUp found.")
                throw MacUpExitCode.usage.exitCode
            }
            candidates = report.updates.filter { wanted.contains($0.id) }
        }

        let policy = PolicyEngine(loaded)
        var results: [InsightDocument.Entry] = []
        var failure: AIError?
        for candidate in candidates {
            do {
                let result = try await context.ai.service.estimate(
                    candidate,
                    configuration: loaded,
                    environment: context.environment,
                    paths: paths,
                    refresh: fresh
                )
                let cautioned = UpdateInsight.applying(result.estimate, to: candidate)
                results.append(InsightDocument.Entry(
                    candidate: candidate,
                    result: result,
                    before: policy.decide(candidate, intent: .interactive),
                    after: policy.decide(cautioned, intent: .interactive)
                ))
            } catch let error as AIError {
                // The next request would fail the same way; stop here and say so.
                failure = error
                break
            }
        }

        if json {
            context.print(try JSONOutput.encode(InsightDocument(entries: results)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            if candidates.isEmpty {
                context.print("There are no updates to ask about.")
            }
            context.print(results.map { InsightRenderer(entry: $0, style: style).render() }.joined(separator: "\n\n"))
        }
        if let failure { throw context.fail(failure) }
    }
}

struct InsightRenderer {
    let entry: InsightDocument.Entry
    let style: TextStyle

    func render() -> String {
        let estimate = entry.estimate
        var lines = [style.bold(style.safe(entry.item.rawValue)) + "  "
            + style.safe(entry.installedVersion ?? "Unknown") + " → " + style.safe(entry.availableVersion)
            + style.dim(" (\(entry.versionChange.displayName))")]
        lines.append("  TypeSafe: \(estimate.softwareKind.displayName) (\(AskMacUp.percent(estimate.softwareKindProbability))); "
            + "a major upgrade migrates its data: \(AskMacUp.percent(estimate.dataMigrationProbability)).")
        if let caution = entry.caution {
            lines.append("  " + style.bold("Caution: ") + style.text(caution.note))
            if entry.before.action == .allow && entry.after.action == .confirm {
                lines.append("  Because of this, MacUp will ask before updating it, even though its rule is \(entry.before.policy.displayName).")
            }
        } else if [VersionChange.major, .unknown].contains(entry.versionChange) {
            lines.append("  No caution: TypeSafe's judgments do not point to data at risk.")
        } else {
            lines.append("  No caution: this is a \(entry.versionChange.displayName) change, and these judgments are about major ones.")
        }
        var provenance = "  " + (entry.fromCache ? "Saved answer from " : "Asked ") + estimate.askedAt.formatted(date: .abbreviated, time: .shortened)
            + " · " + style.safe(estimate.model)
        if !entry.fromCache { provenance += " · saved on this Mac" }
        lines.append(style.dim(provenance))
        if let problem = entry.saveProblem {
            lines.append("  warning: " + style.text(problem))
        }
        return lines.joined(separator: "\n")
    }
}

/// The machine-readable form of `macup insight`.
struct InsightDocument: Encodable {
    struct Entry: Encodable {
        let item: PackageID
        let installedVersion: String?
        let availableVersion: String
        let versionChange: VersionChange
        let estimate: AIEstimate
        let caution: AICaution?
        let fromCache: Bool
        let saveProblem: String?
        /// What policy decided without the estimate, and with it.
        let before: PolicyDecision
        let after: PolicyDecision

        init(candidate: UpdateCandidate, result: UpdateEstimateResult, before: PolicyDecision, after: PolicyDecision) {
            item = candidate.id
            installedVersion = candidate.installedVersion?.raw
            availableVersion = candidate.availableVersion.raw
            versionChange = candidate.versionChange
            estimate = result.estimate
            caution = result.caution
            fromCache = result.fromCache
            saveProblem = result.saveProblem
            self.before = before
            self.after = after
        }
    }

    let schemaVersion = 1
    let kind = "insight"
    let macupVersion = MacUp.version
    let entries: [Entry]
}
