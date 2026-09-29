import ArgumentParser
import Foundation
import MacUpCore

struct PlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Show exactly what `macup update` would do, and change nothing.",
        discussion: """
            A plan is the review MacUp asks you to read before anything runs. For every \
            change it shows the provider, the current and proposed versions, the policy \
            that let it in, how risky it is and why, and the exact executable and \
            arguments MacUp would launch. It also lists every item it would leave \
            alone — ignored, pinned, held back by the provider, or something MacUp \
            cannot plan — with the reason for each.

            Planning launches nothing. It runs the same read-only check as `macup \
            check` and then asks each provider to describe its commands.

            Exit status: 0 planned; 2 a provider failed, so the plan may be missing \
            updates; 3 the configuration is invalid, so nothing may change; 64 you \
            named an item with no update available; 130 cancelled.
            """
    )

    @Argument(help: "Plan only these items, for example brew:git or npm:@scope/name. Default: everything.")
    var items: [String] = []

    @Flag(help: "Refresh provider metadata first, so the plan is not built from stale package lists.")
    var refresh = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Show every rationale, risk reason, verification step, and whether the change can be undone.")
    var verbose = false

    func validate() throws {
        try PackageSelection.validate(items)
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()

        if refresh && !json {
            context.printError("Refreshing provider metadata first. No packages will be changed.")
        }

        let report = await PlanWorkflow.plan(
            PlanRequest(
                selection: PackageSelection.parse(items),
                intent: .interactive,
                refreshMetadata: refresh
            ),
            configuration: loaded,
            context: context
        )

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(PlanRenderer(report: report, style: style, verbose: verbose).render())
        }

        if report.cancelled { throw MacUpExitCode.cancelled.exitCode }
        if !report.unmatchedSelection.isEmpty {
            context.printError("error: " + PackageSelection.unmatchedMessage(report.unmatchedSelection))
            context.printError("`macup check` lists the updates MacUp found.")
            throw MacUpExitCode.usage.exitCode
        }
        if report.providers.contains(where: { !$0.errors.isEmpty }) { throw MacUpExitCode.providerErrors.exitCode }
        if report.configuration?.valid == false { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

/// Planning, shared by `macup plan` and `macup update` so both build the plan
/// the same way and a difference between them cannot creep in.
enum PlanWorkflow {
    static func plan(
        _ request: PlanRequest,
        configuration: LoadedConfiguration,
        context: CLIContext
    ) async -> PlanReport {
        let planner = UpdatePlanner.standard()
        let environment = context.checkEnvironment
        return await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            // The same check the planner would run itself, so that saved AI
            // cautions can be added before policy decides (AI/UpdateInsight.swift).
            let report = await CheckEngine(providers: planner.providers).run(
                configuration: configuration,
                options: CheckOptions(refreshMetadata: request.refreshMetadata),
                environment: environment
            )
            return await planner.plan(
                context.aiCautioned(report, configuration: configuration),
                request: request,
                configuration: configuration,
                environment: environment
            )
        }
    }
}
