import ArgumentParser
import Foundation
import MacUpCore

struct ExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Show everything MacUp knows about one item, and change nothing.",
        discussion: """
            For one package ID: the installed and available versions, what changes \
            between them and where to read about the release, how risky the update is \
            and every reason why, the provider's notes, who manages the item, the \
            policy that decides what MacUp may do with it and the rule behind that, \
            the exact command MacUp would run — or the exact reason it would run \
            nothing — and the item's most recent history.

            Explaining launches nothing that changes the machine. It runs the same \
            read-only check as `macup check`, for the item's provider only, plans the \
            item the way `macup plan` would, and reads MacUp's history. The app's Copy \
            Details copies this same text.

            Exit status: 0 explained; 2 the provider could not be checked completely, \
            so something may be missing; 3 the configuration is invalid, so nothing may \
            change; 64 MacUp knows nothing about the item (its provider does not list \
            it, is turned off, or is not installed); 130 cancelled.
            """
    )

    @Argument(help: "The item to explain, for example brew:git, npm:@scope/name, or mise:node.")
    var item: String

    @Flag(help: "Refresh provider metadata first, so the explanation is not built from stale package lists.")
    var refresh = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        try PackageSelection.validate([item])
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let id: PackageID
        do {
            id = try PackageID(parsing: item)
        } catch let error as PackageID.ValidationError {
            throw ValidationError(error.description)
        }

        if refresh && !json {
            context.printError("Refreshing provider metadata first. No packages will be changed.")
        }

        let explainer = ItemExplainer(
            checkEngine: context.engine,
            planner: UpdatePlanner(providers: context.engine.providers)
        )
        let environment = context.checkEnvironment
        let history = HistoryStore(paths: paths)
        let refresh = refresh
        let explanation = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await explainer.explain(
                id,
                configuration: loaded,
                environment: environment,
                history: history,
                refreshMetadata: refresh
            )
        }

        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        if json {
            context.print(try JSONOutput.encode(explanation))
        } else if !explanation.status.isUnknownItem {
            context.print(ExplanationText(
                homeDirectory: context.homeDirectory,
                bold: style.bold,
                dim: style.dim
            ).render(explanation))
        }

        if explanation.cancelled { throw MacUpExitCode.cancelled.exitCode }
        // An item MacUp knows nothing about is an error, not an explanation
        // of nothing, and it says why and what to run instead. Standard error
        // is not styled: it is not the terminal check the style made.
        if explanation.status.isUnknownItem {
            let message = ExplanationText(homeDirectory: context.homeDirectory).unknownItemMessage(explanation)
            if let first = message.first { context.printError("error: " + first) }
            for line in message.dropFirst() { context.printError(line) }
            throw MacUpExitCode.usage.exitCode
        }
        if !explanation.configuration.valid { throw MacUpExitCode.configurationInvalid.exitCode }
        if explanation.status == .checkFailed || explanation.status == .updateUnknown
            || explanation.providerReport?.hasErrors == true {
            throw MacUpExitCode.providerErrors.exitCode
        }
    }
}
