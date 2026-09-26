import ArgumentParser
import MacUpCore

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Inspect MacUp's configuration (read-only).",
        subcommands: [ConfigPathCommand.self]
    )
}

struct ConfigPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print where MacUp reads configuration and keeps state."
    )

    @Flag(name: .long, help: "Print machine-readable JSON.")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths: MacUpPaths
        do {
            paths = try MacUpPaths.resolve(homeDirectory: context.homeDirectory, environment: context.environment)
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            throw MacUpExitCode.configurationInvalid.exitCode
        }

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
