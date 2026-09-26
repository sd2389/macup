import ArgumentParser
import MacUpCore

struct ProviderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Inspect providers (read-only).",
        subcommands: [ProviderListCommand.self]
    )
}

struct ProviderListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show which providers MacUp found and exactly which installation it uses."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let engine = context.engine
        let environment = context.checkEnvironment
        let result = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.detect(configuration: loaded, environment: environment)
        }

        if json {
            context.print(try JSONOutput.encode(ProviderListDocument(providers: result.providers, commands: result.commands)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(render(result.providers, style: style))
        }
        if !loaded.allowsAutomaticModification {
            context.printError("The configuration has errors; run `macup config show` for details.")
            throw MacUpExitCode.configurationInvalid.exitCode
        }
    }

    private func render(_ providers: [ProviderReport], style: TextStyle) -> String {
        let nameWidth = providers.map(\.displayName.count).max() ?? 0
        var lines: [String] = []
        for provider in providers {
            let state: String
            switch provider.availability {
            case .available: state = "found"
            case .unavailable: state = "not found"
            case .disabled: state = "disabled"
            case .failed: state = "not usable"
            }
            var line = style.bold(TextStyle.pad(provider.displayName, to: nameWidth)) + "  " + TextStyle.pad(state, to: 10)
            if let version = provider.version { line += "  " + TextStyle.pad(style.safe(version), to: 10) }
            if let executable = provider.executable { line += "  " + style.path(executable.path) }
            lines.append(line)
            if let executable = provider.executable, executable.canonicalPath != executable.path {
                lines.append("    " + style.dim("→ " + style.path(executable.canonicalPath)))
            }
            for fact in provider.facts {
                lines.append("    " + style.dim("\(fact.label): \(style.path(fact.value))"))
            }
            for finding in provider.findings {
                lines.append("    \(finding.severity == .info ? "note" : finding.severity.rawValue): \(style.text(finding.title))")
            }
            for failure in provider.errors {
                lines.append("    error: \(style.text(failure.error.message))")
                if let suggestion = failure.error.recoverySuggestion {
                    lines.append("      " + style.text(suggestion))
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct ProviderListDocument: Encodable {
    let schemaVersion = 1
    let kind = "providerList"
    let macupVersion = MacUp.version
    let providers: [ProviderReport]
    let commands: [CommandRecord]
}
