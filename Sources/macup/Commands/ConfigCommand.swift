import ArgumentParser
import Foundation
import MacUpCore

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show MacUp's configuration (read-only).",
        subcommands: [ConfigShowCommand.self, ConfigPathCommand.self],
        defaultSubcommand: ConfigShowCommand.self
    )
}

struct ConfigPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print where MacUp reads configuration and keeps state."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        if json {
            context.print(try JSONOutput.encode(ConfigPathsDocument(paths: paths)))
            return
        }
        context.print("Configuration file: \(TerminalText.sanitize(paths.configFile))\(sourceNote(paths.configDirectorySource, MacUpPaths.configDirectoryVariable))")
        context.print("State directory:    \(TerminalText.sanitize(paths.stateDirectory))\(sourceNote(paths.stateDirectorySource, MacUpPaths.stateDirectoryVariable))")
    }

    private func sourceNote(_ source: MacUpPaths.Source, _ variable: String) -> String {
        source == .environment ? " (from \(variable))" : ""
    }
}

struct ConfigShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the configuration in effect and any problems with it.",
        discussion: """
            Reading never creates or changes the file. If the file is missing, MacUp uses \
            conservative defaults: every provider enabled, everything Ask First, no \
            scheduling, no telemetry. Any error disables automatic modifications until it \
            is fixed (exit status 3).
            """
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()

        if json {
            context.print(try JSONOutput.encode(ConfigurationDocument(loaded)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            var lines = [style.bold("Configuration") + " " + style.path(loaded.path)]
            switch loaded.source {
            case .defaults: lines.append("No configuration file; using built-in defaults.")
            case .file: lines.append(loaded.hasErrors ? "The file has errors." : "The file is valid.")
            }
            lines.append(loaded.allowsAutomaticModification
                ? "Changes: `macup update` may run items set to Auto Update without asking. Nothing runs on a schedule."
                : "Changes: disabled until the errors below are fixed. MacUp will update nothing.")
            if loaded.configuration.schedule.enabled {
                lines.append(
                    "Scheduling: \(loaded.configuration.schedule.summary), read-only. "
                        + "`macup schedule status` shows whether the agent is installed."
                )
            }
            if !loaded.issues.isEmpty {
                lines.append("")
                for issue in loaded.issues {
                    let location = issue.path.isEmpty ? "" : style.safe(issue.path) + ": "
                    lines.append("  \(issue.severity.rawValue): \(location)\(style.text(issue.message))")
                }
            }
            lines.append("")
            lines.append(loaded.hasErrors && loaded.source == .file ? "Settings in effect for read-only commands:" : "Settings in effect:")
            lines.append(try JSONOutput.encode(loaded.configuration))
            context.print(lines.joined(separator: "\n"))
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

struct ConfigPathsDocument: Encodable {
    let schemaVersion = 1
    let kind = "configPaths"
    let configFile: String
    let configDirectory: String
    let stateDirectory: String
    let configDirectorySource: MacUpPaths.Source
    let stateDirectorySource: MacUpPaths.Source

    init(paths: MacUpPaths) {
        configFile = paths.configFile
        configDirectory = paths.configDirectory
        stateDirectory = paths.stateDirectory
        configDirectorySource = paths.configDirectorySource
        stateDirectorySource = paths.stateDirectorySource
    }
}

struct ConfigurationDocument: Encodable {
    let schemaVersion = 1
    let kind = "configuration"
    let path: String
    let source: LoadedConfiguration.Source
    let valid: Bool
    let automaticModificationsAllowed: Bool
    let issues: [ConfigurationIssue]
    let configuration: MacUpConfiguration

    init(_ loaded: LoadedConfiguration) {
        path = loaded.path
        source = loaded.source
        valid = !loaded.hasErrors
        automaticModificationsAllowed = loaded.allowsAutomaticModification
        issues = loaded.issues
        configuration = loaded.configuration
    }
}
