import ArgumentParser
import Foundation
import MacUpCore

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Apply the updates your policy allows. With `macup uninstall`, the only commands that change packages.",
        discussion: """
            MacUp shows the plan first, then runs it one item at a time, then reports \
            what happened and whether it could confirm each new version. Every attempt \
            is recorded in MacUp's history, including the ones it decided not to make.

            With no arguments it considers every update your policy allows. Name items \
            to limit it to those. Naming an item is a request, not a confirmation: an \
            item set to Ask First still waits for you.

            Confirmation. Items your policy marks Ask First, and Auto Update items that \
            risk raised the bar for, need your word. In a terminal MacUp shows the plan \
            and asks once. When output is not a terminal — a script, a pipe, a log — it \
            asks nobody and leaves those items alone, because there is no one to answer. \
            --yes confirms every item in the plan it just showed you.

            Nothing else is implied. An ignored item, a pinned item, one the provider \
            itself holds back, and a provider you turned off are never run, whatever \
            you pass. Policy is read again immediately before each item, so a rule you \
            change after reading the plan still applies.

            Exit status: 0 everything attempted succeeded; 2 a provider failed, so the \
            plan may be incomplete; 3 the configuration is invalid and nothing may \
            change; 4 at least one update failed; 64 you named an item with no update \
            available, and nothing ran; 77 the device owner did not approve; 130 \
            cancelled.
            """
    )

    @Argument(help: "Update only these items, for example brew:git or npm:@scope/name. Default: everything policy allows.")
    var items: [String] = []

    @Flag(name: .long, help: "Show what would run and launch nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Confirm every item in the plan MacUp shows, instead of asking.")
    var yes = false

    @Flag(help: "Refresh provider metadata first, so the plan is not built from stale package lists.")
    var refresh = false

    @Flag(name: .long, help: "Stop at the first failure instead of moving on to the next item.")
    var stopOnFailure = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1). Never asks anything; use --yes.")
    var json = false

    @Flag(name: .shortAndLong, help: "Show every command MacUp ran, with its exit status and timing.")
    var verbose = false

    func validate() throws {
        try PackageSelection.validate(items)
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)

        if refresh && !json {
            context.printError("Refreshing provider metadata first. That refresh changes no packages.")
        }

        let plan = await PlanWorkflow.plan(
            PlanRequest(
                selection: PackageSelection.parse(items),
                intent: .interactive,
                refreshMetadata: refresh
            ),
            configuration: loaded,
            context: context
        )

        // A cancelled plan is an incomplete picture of the machine, and MacUp
        // does not change anything on an incomplete picture.
        if plan.cancelled {
            context.printError("Cancelled before MacUp finished looking. Nothing was changed.")
            throw MacUpExitCode.cancelled.exitCode
        }
        // An item the user named but no provider offered means MacUp and the
        // user disagree about what is going to happen, so nothing happens.
        if !plan.unmatchedSelection.isEmpty {
            context.printError("error: " + PackageSelection.unmatchedMessage(plan.unmatchedSelection))
            context.printError("Nothing was changed. `macup check` lists the updates MacUp found.")
            throw MacUpExitCode.usage.exitCode
        }

        if !json {
            context.print(PlanRenderer(
                report: plan,
                style: style,
                verbose: verbose,
                purpose: dryRun ? .dryRun : .beforeRunning
            ).render())
        }

        let confirmed = try confirmations(plan, context: context, style: style)
        let willRun = plan.planned.filter { $0.decision.action == .allow || confirmed.contains($0.item) }

        if !dryRun {
            guard !willRun.isEmpty else {
                context.printError("Nothing was changed.")
                if let code = exitCode(plan: plan, report: nil) { throw code }
                return
            }
            // The gate is the last thing before anything runs, and only when
            // something will: MacUp does not ask the owner to approve a run
            // that would change nothing.
            try await context.requireApproval(
                "update \(TextStyle.plural(willRun.count, "item")) on this Mac",
                loaded.configuration,
                paths: paths
            )
            if !json {
                context.print("")
                context.print(style.bold("Running \(TextStyle.plural(willRun.count, "change")).")
                    + style.dim(" Press Ctrl+C to stop after the current one."))
            }
        }

        let environment = narrating(context.checkEnvironment, context: context)
        let engine = ExecutionEngine.standard(paths: paths)
        let options = ExecutionOptions(
            origin: .cli,
            intent: .interactive,
            confirmed: confirmed,
            dryRun: dryRun,
            stopOnFailure: stopOnFailure
        )
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(plan, configuration: loaded, options: options, environment: environment)
        }

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            context.print("")
            if dryRun {
                context.print(ExecutionRenderer.dryRunFooter(plan: plan, report: report, style: style)
                    .joined(separator: "\n"))
            } else {
                context.print(ExecutionRenderer(report: report, style: style, verbose: verbose).render())
            }
        }

        if let code = exitCode(plan: plan, report: report) { throw code }
    }

    /// The same environment, with each change announced as it starts and
    /// finishes. A dry run launches nothing to narrate, and `--json` output is
    /// a single document that progress lines would corrupt.
    private func narrating(_ environment: CheckEnvironment, context: CLIContext) -> CheckEnvironment {
        guard !json, !dryRun else { return environment }
        var narrated = environment
        narrated.runner = ProgressRunner(base: environment.runner) { line in context.print(line) }
        return narrated
    }

    // MARK: Confirmation

    /// The items the user has confirmed, and nothing else.
    ///
    /// A dry run confirms everything the plan proposed, because it launches
    /// nothing and the point of a dry run is to see the whole command list.
    /// A real run confirms only what `--yes` covered or what the user just
    /// answered yes to at a terminal. With no terminal there is nobody to ask,
    /// so those items are left alone and MacUp says how to confirm them.
    private func confirmations(
        _ plan: PlanReport,
        context: CLIContext,
        style: TextStyle
    ) throws -> Set<PackageID> {
        let waiting = plan.needingConfirmation
        guard !waiting.isEmpty else { return [] }
        let all = Set(waiting.map(\.item))

        if dryRun { return all }
        if yes { return all }

        // JSON output is for automation, and prompting in the middle of a
        // document nobody is reading would be worse than refusing.
        guard !json else {
            context.printError("error: \(TextStyle.plural(waiting.count, "item")) needs your confirmation, and "
                + "--json never asks. Re-run with --yes to confirm them, or without --json to be asked.")
            return []
        }

        guard context.standardOutputIsTerminal else {
            context.print("")
            context.print("\(TextStyle.plural(waiting.count, "item")) needs your confirmation, and this is not a "
                + "terminal, so MacUp is leaving them alone:")
            for planned in waiting {
                context.print("  " + style.safe(planned.item.rawValue) + "  " + style.text(planned.decision.reason))
            }
            context.print("Run `macup update` in a terminal to be asked, pass --yes to confirm them, or set one to "
                + "update without asking with `macup policy set <package-id> auto`.")
            return []
        }

        context.print("")
        let question = waiting.count == 1
            ? "Run the 1 change that needs your confirmation, shown above?"
            : "Run the \(waiting.count) changes that need your confirmation, shown above?"
        guard context.askToProceed(question) else {
            context.print("Left alone: " + waiting.map { style.safe($0.item.rawValue) }.joined(separator: ", ") + ".")
            return []
        }
        return all
    }

    // MARK: Exit status

    /// The status this run should exit with, or `nil` for success.
    ///
    /// A failed update wins over a partial check, because it is the thing that
    /// happened to the machine. Everything else follows the order documented
    /// in docs/CLI.md.
    private func exitCode(plan: PlanReport, report: ExecutionReport?) -> ExitCode? {
        if report?.cancelled == true { return MacUpExitCode.cancelled.exitCode }
        if report?.hasFailures == true { return MacUpExitCode.updateFailed.exitCode }
        if plan.configuration?.valid == false { return MacUpExitCode.configurationInvalid.exitCode }
        if plan.providers.contains(where: { !$0.errors.isEmpty }) { return MacUpExitCode.providerErrors.exitCode }
        return nil
    }
}
