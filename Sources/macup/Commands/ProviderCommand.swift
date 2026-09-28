import ArgumentParser
import MacUpCore

struct ProviderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provider",
        abstract: "Show which providers MacUp found, and turn one on or off.",
        discussion: """
            `macup provider list` reads. `enable` and `disable` change MacUp's own \
            configuration file and no packages.

            A provider that is off is not checked and never proposes an update, so \
            disabling one is how you take a whole ecosystem out of MacUp's hands \
            without touching the tool itself.
            """,
        subcommands: [ProviderListCommand.self, ProviderEnableCommand.self, ProviderDisableCommand.self],
        defaultSubcommand: ProviderListCommand.self,
        aliases: ["providers"]
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
        let versionWidth = providers.compactMap { $0.version.map { style.safe($0).count } }.max() ?? 0
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
            if provider.executable != nil { line += "  " + TextStyle.pad(style.safe(provider.version ?? ""), to: versionWidth) }
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

/// `macup provider enable` and `macup provider disable`, which differ only in
/// the value they write, so they share everything else.
struct ProviderSwitch {
    let enabled: Bool
    let provider: String
    let json: Bool

    static func validate(_ provider: String) throws {
        guard ProviderID(rawValue: provider).isKnown else {
            throw ValidationError(
                "Unknown provider '\(TerminalText.sanitize(provider))'. Known providers: "
                    + ProviderID.known.map(\.rawValue).joined(separator: ", ") + "."
            )
        }
    }

    func run() async throws {
        let id = ProviderID(rawValue: provider)
        try await PolicyEditing.apply(json: json) { editor in
            try editor.setProviderEnabled(enabled, for: id)
        }
    }
}

struct ProviderEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Let MacUp check a provider again and propose its updates."
    )

    @Argument(help: "homebrew, npm, mise, or macos.")
    var provider: String

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        try ProviderSwitch.validate(provider)
    }

    func run() async throws {
        try await ProviderSwitch(enabled: true, provider: provider, json: json).run()
    }
}

struct ProviderDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop MacUp checking a provider or proposing its updates.",
        discussion: """
            MacUp leaves the tool itself completely alone: disabling a provider only \
            stops MacUp looking at it. Nothing is uninstalled and no package changes.
            """
    )

    @Argument(help: "homebrew, npm, mise, or macos.")
    var provider: String

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        try ProviderSwitch.validate(provider)
    }

    func run() async throws {
        try await ProviderSwitch(enabled: false, provider: provider, json: json).run()
    }
}

struct ProviderListDocument: Encodable {
    let schemaVersion = 1
    let kind = "providerList"
    let macupVersion = MacUp.version
    let providers: [ProviderReport]
    let commands: [CommandRecord]
}
