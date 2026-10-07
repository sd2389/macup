import ArgumentParser
import Foundation
import MacUpCore

/// Everything that happens after a plan exists, shared by the two commands
/// that apply updates: `macup update` and `macup self-update`.
///
/// Show the plan, ask for what needs asking, put the whole run behind the
/// approval gate, execute through the one execution engine, report, and
/// exit with the documented status. Keeping it in one place is the point:
/// updating MacUp itself must not become a second, softer path that skips a
/// confirmation the ordinary path makes (CLAUDE.md §2).
struct UpdateRun {
    var dryRun = false
    var yes = false
    var stopOnFailure = false
    var json = false
    var verbose = false

    /// Runs what the plan allows and what the user confirms.
    ///
    /// `approvalNoun` is what the approval gate asks about, for example
    /// "update 3 items on this Mac".
    func apply(
        _ plan: PlanReport,
        configuration loaded: LoadedConfiguration,
        paths: MacUpPaths,
        context: CLIContext,
        style: TextStyle,
        approvalNoun: (Int) -> String = { "update \(TextStyle.plural($0, "item")) on this Mac" }
    ) async throws -> ExecutionReport? {
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
                return nil
            }
            // The gate is the last thing before anything runs, and only when
            // something will: MacUp does not ask the owner to approve a run
            // that would change nothing.
            try await context.requireApproval(approvalNoun(willRun.count), loaded.configuration, paths: paths)
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
        return report
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
    func confirmations(_ plan: PlanReport, context: CLIContext, style: TextStyle) throws -> Set<PackageID> {
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
    func exitCode(plan: PlanReport, report: ExecutionReport?) -> ExitCode? {
        if report?.cancelled == true { return MacUpExitCode.cancelled.exitCode }
        if report?.hasFailures == true { return MacUpExitCode.updateFailed.exitCode }
        if plan.configuration?.valid == false { return MacUpExitCode.configurationInvalid.exitCode }
        if plan.providers.contains(where: { !$0.errors.isEmpty }) { return MacUpExitCode.providerErrors.exitCode }
        return nil
    }
}
