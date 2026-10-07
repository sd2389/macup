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

        _ = try await UpdateRun(
            dryRun: dryRun,
            yes: yes,
            stopOnFailure: stopOnFailure,
            json: json,
            verbose: verbose
        ).apply(plan, configuration: loaded, paths: paths, context: context, style: style)
    }
}
