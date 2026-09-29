import ArgumentParser
import Foundation
import MacUpCore

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Show what is outdated without changing anything (the default command).",
        discussion: """
            Detects Homebrew, npm global packages, mise, and macOS software updates and \
            lists available updates. A check never installs, upgrades, removes, or cleans \
            anything, and never rewrites configuration.

            Homebrew and macOS results come from locally cached metadata. With --refresh, \
            MacUp first runs `brew update` (which updates Homebrew itself and its package \
            lists, but no installed packages) and a fresh `softwareupdate --list` scan. \
            npm and mise always ask their registries.

            Exit status: 0 checked; 2 a provider failed (partial results); 3 the \
            configuration is invalid; 130 cancelled.
            """
    )

    @Flag(help: "Refresh provider metadata before checking (network; see above).")
    var refresh = false

    @Option(name: .customLong("provider"), help: "Check only this provider: homebrew, npm, mise, or macos. Repeatable.")
    var providers: [String] = []

    @Flag(help: "Also list installed items.")
    var inventory = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Show ownership, risk reasons, notes, and every command MacUp ran.")
    var verbose = false

    @Flag(
        name: .customLong("save-state"),
        help: "Also write the report to ~/.local/state/macup/last-check.json. This is how a scheduled check leaves its result behind."
    )
    var saveState = false

    func validate() throws {
        for name in providers where !ProviderID(rawValue: name).isKnown {
            throw ValidationError(
                "Unknown provider '\(TerminalText.sanitize(name))'. Known providers: \(ProviderID.known.map(\.rawValue).joined(separator: ", "))."
            )
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let options = CheckOptions(
            refreshMetadata: refresh,
            providers: providers.isEmpty ? nil : Set(providers.map(ProviderID.init(rawValue:))),
            includeInventoryItems: inventory
        )
        if refresh && !json {
            context.printError("Refreshing provider metadata (brew update, softwareupdate scan). No packages will be changed.")
        }

        let engine = context.engine
        let environment = context.checkEnvironment
        let checked = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(configuration: loaded, options: options, environment: environment)
        }
        // Saved AI cautions, only while AI help is on; they can only add caution.
        let report = context.aiCautioned(checked, configuration: loaded)

        let encoded = (json || saveState) ? try JSONOutput.encode(report) : nil
        if let encoded, json {
            context.print(encoded)
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(CheckRenderer(report: report, style: style, verbose: verbose, rules: PolicyListing(loaded)).render())
        }

        if report.cancelled { throw MacUpExitCode.cancelled.exitCode }

        // A cancelled run has nothing worth saving; anything else is recorded
        // even when a provider failed, so a scheduled run leaves evidence.
        var saveFailed = false
        if saveState, let encoded {
            do {
                try PrivateDirectory(paths.stateDirectory).write(Data(encoded.utf8), named: MacUpPaths.lastCheckFileName)
            } catch {
                let message = (error as? MacUpError)?.message ?? "The report could not be saved."
                context.printError("error: \(TerminalText.sanitize(message))")
                saveFailed = true
            }
        }

        if report.hasProviderErrors || report.summary.providersIncomplete > 0 { throw MacUpExitCode.providerErrors.exitCode }
        if !report.configuration.valid { throw MacUpExitCode.configurationInvalid.exitCode }
        if saveFailed { throw MacUpExitCode.failure.exitCode }
    }
}
