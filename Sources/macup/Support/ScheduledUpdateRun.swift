import ArgumentParser
import Foundation
import MacUpCore

/// `macup update --scheduled`: what the launchd agent runs when the person
/// turned installing on (ADR-023).
///
/// Nobody is watching, so this run is defined entirely by what was decided
/// in advance:
///
/// - the plan is built with the unattended intent, so only items whose rule
///   resolves to Auto Update are allowed and everything else is skipped with
///   its reason — an Ask First item is never confirmed by a schedule;
/// - the execution engine refuses, per item, anything that may ask for an
///   administrator password or need a restart;
/// - policy is read again immediately before each item, as in any run;
/// - a configuration MacUp cannot read fully stops the run before it starts;
/// - approval that needs the device owner stops it too, because a schedule
///   has nobody to ask;
/// - the check is saved exactly as `macup check --save-state` saves it, so
///   the app and `macup schedule status` can say what happened, and every
///   attempt and skip is in the history.
struct ScheduledUpdateRun {
    var refresh = false
    var json = false
    var verbose = false

    func run(
        configuration loaded: LoadedConfiguration,
        paths: MacUpPaths,
        context: CLIContext,
        style: TextStyle
    ) async throws {
        guard loaded.allowsAutomaticModification else {
            context.printError("MacUp will not install anything on a schedule while its configuration has errors.")
            throw MacUpExitCode.configurationInvalid.exitCode
        }
        // Someone who asked to approve every change has to be there to
        // approve it. A scheduled run cannot ask, so it does not run.
        if loaded.configuration.security.requireApproval {
            context.printError(
                "MacUp asks you to approve every change, and a scheduled run has nobody to ask, so it installed nothing. "
                    + "Turn off approval, or turn off installing on a schedule."
            )
            throw MacUpExitCode.notApproved.exitCode
        }

        let (check, plan) = await PlanWorkflow.checkAndPlan(
            PlanRequest(selection: nil, intent: .unattended, refreshMetadata: refresh),
            configuration: loaded,
            context: context
        )
        if plan.cancelled {
            context.printError("The scheduled run was stopped before MacUp finished looking. Nothing was changed.")
            throw MacUpExitCode.cancelled.exitCode
        }

        let engine = ExecutionEngine.standard(paths: paths)
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(
                plan,
                configuration: loaded,
                options: ExecutionOptions(origin: .scheduled, intent: .unattended, confirmed: []),
                environment: context.checkEnvironment
            )
        }

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            context.print(ExecutionRenderer(report: report, style: style, verbose: verbose).render())
            // Under the unattended intent an Ask First item never reaches
            // the plan as something to confirm: it is skipped with its
            // reason, and this is where the person hears about it.
            let waiting = report.skipped.filter { $0.decision?.policy == .ask }.count
            if waiting > 0 {
                context.print("")
                context.print("\(TextStyle.plural(waiting, "update")) \(waiting == 1 ? "needs" : "need") your word, "
                    + "so the schedule left " + (waiting == 1 ? "it" : "them") + " alone. `macup update` shows "
                    + (waiting == 1 ? "it" : "them") + ".")
            }
        }

        // Saved last, and even when something failed: the point of a
        // scheduled run is to leave evidence behind.
        var saveFailed = false
        do {
            try PrivateDirectory(paths.stateDirectory)
                .write(Data(try JSONOutput.encode(check).utf8), named: MacUpPaths.lastCheckFileName)
        } catch {
            let message = (error as? MacUpError)?.message ?? "The check could not be saved."
            context.printError("error: \(TerminalText.sanitize(message))")
            saveFailed = true
        }

        if report.cancelled { throw MacUpExitCode.cancelled.exitCode }
        if report.hasFailures { throw MacUpExitCode.updateFailed.exitCode }
        if check.hasProviderErrors { throw MacUpExitCode.providerErrors.exitCode }
        if saveFailed { throw MacUpExitCode.failure.exitCode }
    }
}
