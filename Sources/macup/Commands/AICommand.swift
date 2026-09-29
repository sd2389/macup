import ArgumentParser
import Foundation
import MacUpCore

struct AICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "Optional AI help from TypeSafe: off until you turn it on, and never in the background.",
        discussion: """
            With AI help on, `macup ask` turns a request in plain words into one rule change \
            you confirm, and `macup insight` asks whether an update needs extra care. Both \
            send a few fields to TypeSafe (api.typesafe.ai), only when you run them. \
            `macup ai disclosure` lists exactly which fields; nothing else ever leaves this Mac.

            An answer can only ever add caution or propose a change. It never lowers a risk, \
            never allows what your policy denies, and never changes the configuration without \
            you confirming the exact change.

            You need your own TypeSafe API key. MacUp looks for it in its Keychain item \
            (`macup ai key set`) and then in TYPESAFE_API_KEY, and never prints it or writes \
            it to a file.

            Examples:
              macup ai key set        Save your key in the Keychain
              macup ai disclosure     Exactly what each feature sends
              macup ai enable         Turn AI help on, after reading that
              macup ai test           One tiny request, to check the key works
              macup ai disable        Turn it off again
            """,
        subcommands: [
            AIStatusCommand.self, AIEnableCommand.self, AIDisableCommand.self, AIKeyCommand.self,
            AITestCommand.self, AIDisclosureCommand.self, AIForgetCommand.self,
        ],
        defaultSubcommand: AIStatusCommand.self
    )
}

// MARK: - status

struct AIStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Whether AI help is on, where the key comes from, and the model (read-only; never prints the key)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let status = context.ai.service.status(loaded, environment: context.environment)

        if json {
            context.print(try JSONOutput.encode(AIStatusDocument(status)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            var lines = [style.bold("AI help from TypeSafe") + " · " + (status.enabled && status.configurationReadable ? "on" : "off")]
            lines.append("  Key: " + Self.keyLine(status.key))
            lines.append("  Model: " + style.safe(status.model))
            lines.append("  Requests go to \(status.host), and only when you run `macup ask`, `macup insight`, or `macup ai test`.")
            for problem in status.key.problems {
                lines.append("  warning: " + style.text(problem))
            }
            lines.append("")
            lines.append(status.summary)
            if !status.enabled {
                lines.append(status.key.source == nil
                    ? "Save a key with `macup ai key set`, read `macup ai disclosure`, then `macup ai enable`."
                    : "`macup ai disclosure` lists exactly what each feature sends; `macup ai enable` turns it on.")
            }
            context.print(lines.joined(separator: "\n"))
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }

    static func keyLine(_ key: AIKeyStatus) -> String {
        switch key.source {
        case .keychain?:
            key.environmentHasKey
                ? "in the Keychain (\(KeychainAPIKeyStore.service)); TYPESAFE_API_KEY is also set and is not used"
                : "in the Keychain (\(KeychainAPIKeyStore.service))"
        case .environment?:
            "from TYPESAFE_API_KEY in your environment"
        case nil:
            "none"
        }
    }
}

// MARK: - enable / disable

struct AIEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Turn AI help on, after showing exactly what it sends.",
        discussion: """
            At a terminal MacUp shows the disclosure and asks. Anywhere else it asks \
            nobody, so pass --yes once you have read `macup ai disclosure`. Turning AI \
            help on sends nothing by itself.
            """
    )

    @Flag(name: [.customShort("y"), .long], help: "Turn it on without asking, having read `macup ai disclosure`.")
    var yes = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1). Never asks anything; use --yes.")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        try context.requireReadableConfiguration(loaded)

        let status = context.ai.service.status(loaded, environment: context.environment)
        guard !status.enabled else {
            try AISettingsOutput.report(try AISettingsEditor(paths: paths).setEnabled(true), json: json, context: context)
            return
        }
        guard status.key.source != nil else { throw context.fail(.noKey) }

        if !json {
            context.print(AIDisclosureRenderer.render(.standard))
            context.print("")
        }
        if !yes {
            guard !json else {
                context.printError("error: turning on AI help needs your confirmation, and --json never asks. Read `macup ai disclosure`, then re-run with --yes.")
                throw MacUpExitCode.usage.exitCode
            }
            guard context.standardOutputIsTerminal else {
                context.printError("error: turning on AI help needs your confirmation, and this is not a terminal. Read `macup ai disclosure`, then re-run with --yes.")
                throw MacUpExitCode.usage.exitCode
            }
            guard context.askToProceed("Turn on AI help from TypeSafe?") else {
                context.print("Nothing was changed. AI help stays off.")
                return
            }
        }

        try await context.requireApproval("turn on AI help from TypeSafe", loaded.configuration, paths: paths)
        do {
            try AISettingsOutput.report(try AISettingsEditor(paths: paths).setEnabled(true), json: json, context: context)
        } catch let error as MacUpError {
            throw AISettingsOutput.fail(error, context: context)
        }
    }
}

struct AIDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Turn AI help off. MacUp then sends nothing to TypeSafe.",
        discussion: """
            Turning it off needs no approval: it can only make MacUp do less. The key \
            stays in the Keychain until `macup ai key clear`.
            """
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        if loaded.hasErrors {
            context.printError("While the configuration has errors, AI help is already off and MacUp sends nothing.")
        }
        try context.requireReadableConfiguration(loaded)
        do {
            try AISettingsOutput.report(try AISettingsEditor(paths: paths).setEnabled(false), json: json, context: context)
        } catch let error as MacUpError {
            throw AISettingsOutput.fail(error, context: context)
        }
    }
}

enum AISettingsOutput {
    static func report(_ change: AISettingsChange, json: Bool, context: CLIContext) throws {
        if json {
            context.print(try JSONOutput.encode(AIChangeDocument(change: change)))
        } else {
            context.print(change.summary)
            if change.changed && !change.newValue {
                context.print("Your key stays in the Keychain; remove it with `macup ai key clear`.")
            }
        }
    }

    static func fail(_ error: MacUpError, context: CLIContext) -> ExitCode {
        context.printError("error: \(TerminalText.sanitize(error.message))")
        if let detail = error.detail {
            for line in detail.split(separator: "\n") { context.printError("  " + TerminalText.sanitize(String(line))) }
        }
        if let suggestion = error.recoverySuggestion { context.printError(TerminalText.sanitize(suggestion)) }
        return MacUpExitCode.configurationInvalid.exitCode
    }
}

// MARK: - key

struct AIKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Save or remove your TypeSafe API key in the Keychain.",
        subcommands: [AIKeySetCommand.self, AIKeyClearCommand.self]
    )
}

struct AIKeySetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Save your TypeSafe API key in the Keychain. Paste it when asked, or pipe it in.",
        discussion: """
            At a terminal the key is read with echo off. Otherwise one line is read from \
            standard input, for example `pbpaste | macup ai key set`. The key is never \
            taken as an argument: arguments stay in your shell history and are visible to \
            other programs. Saving a key sends nothing and does not turn AI help on.
            """
    )

    @Argument(parsing: .allUnrecognized, help: ArgumentHelp(visibility: .private))
    var unexpected: [String] = []

    func validate() throws {
        guard unexpected.isEmpty else {
            // Deliberately does not repeat what was typed: it may be the key.
            throw ValidationError(
                "macup ai key set takes no arguments, so nothing was saved. Arguments stay in your shell history and are visible "
                    + "to other programs, so MacUp never accepts a key that way. Run `macup ai key set` and paste the key when asked. "
                    + "If you just typed a real key, consider replacing it in the TypeSafe console."
            )
        }
    }

    func run() async throws {
        let context = CLIContext.current
        guard let raw = context.ai.readSecret("TypeSafe API key (not shown as you type): "),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            context.printError("error: no key was given, so nothing was saved.")
            throw MacUpExitCode.failure.exitCode
        }
        do {
            try context.ai.service.keyStore.saveKey(try TypeSafeAPIKey(validating: raw))
        } catch let error as AIError {
            throw context.fail(error)
        }
        context.print("Saved the key in your login keychain as \(KeychainAPIKeyStore.service). MacUp never prints it or writes it to a file.")

        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        if !context.ai.service.status(loaded, environment: context.environment).isActive {
            context.print("AI help is still off, so nothing is sent. `macup ai disclosure` says what it would send; `macup ai enable` turns it on.")
        }
    }
}

struct AIKeyClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove the TypeSafe API key from the Keychain."
    )

    func run() async throws {
        let context = CLIContext.current
        let removed: Bool
        do {
            removed = try context.ai.service.keyStore.deleteKey()
        } catch let error as AIError {
            throw context.fail(error)
        }
        context.print(removed ? "Removed the TypeSafe key from the Keychain." : "There was no TypeSafe key in the Keychain.")
        if let value = context.environment[AIKeyLookup.environmentVariable], !value.isEmpty {
            context.print("TYPESAFE_API_KEY is still set in this shell, so MacUp can use that key while AI help is on.")
        }
    }
}

// MARK: - test

struct AITestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Send one tiny request that says nothing about this Mac, and show the model and how long it took."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let result: AIConnectionTest
        do {
            result = try await context.ai.service.testConnection(loaded, environment: context.environment)
        } catch let error as AIError {
            throw context.fail(error)
        }
        if json {
            context.print(try JSONOutput.encode(AITestDocument(result)))
        } else {
            context.print("TypeSafe answered: \(TerminalText.sanitize(result.model)), in \(result.milliseconds) ms. The key came from \(result.keySource.displayName).")
        }
    }
}

// MARK: - disclosure

struct AIDisclosureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disclosure",
        abstract: "Exactly what each AI feature sends, and what is never sent (read-only).",
        aliases: ["sends"]
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        if json {
            context.print(try JSONOutput.encode(AIDisclosureDocument(disclosure: .standard)))
        } else {
            context.print(AIDisclosureRenderer.render(.standard))
        }
    }
}

enum AIDisclosureRenderer {
    static func render(_ disclosure: AIDisclosure) -> String {
        var lines = ["What MacUp sends to \(disclosure.recipient)"]
        for feature in disclosure.features {
            lines.append("")
            lines.append("\(feature.title). \(feature.when)")
            lines += feature.sends.map { "  - " + $0 }
        }
        lines.append("")
        lines.append("With every request:")
        lines += disclosure.withEveryRequest.map { "  - " + $0 }
        lines.append("")
        lines.append("Never sent:")
        lines += disclosure.neverSent.map { "  - " + $0 }
        lines.append("")
        lines.append("How TypeSafe handles what it receives, including how long it keeps it, is in its Data Processing Agreement:")
        lines.append("  " + disclosure.dataProcessingAgreement.absoluteString)
        return lines.joined(separator: "\n")
    }
}

// MARK: - forget

struct AIForgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Delete the AI estimates MacUp saved on this Mac. Nothing is sent."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let removed: Int
        do {
            removed = try context.ai.service.forgetEstimates(paths: paths)
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            throw MacUpExitCode.failure.exitCode
        }
        if json {
            context.print(try JSONOutput.encode(AIForgetDocument(removed: removed)))
        } else if removed == 0 {
            context.print("There were no AI estimates to delete.")
        } else {
            context.print("Deleted \(TextStyle.plural(removed, "AI estimate")). MacUp no longer applies them; ask again with `macup insight`.")
        }
    }
}

// MARK: - JSON

struct AIStatusDocument: Encodable {
    let schemaVersion = 1
    let kind = "aiStatus"
    let enabled: Bool
    let active: Bool
    let configurationReadable: Bool
    let model: String
    let host: String
    let keySource: AIKeySource?
    let keychainHasKey: Bool
    let environmentHasKey: Bool
    let problems: [String]
    let summary: String

    init(_ status: AIStatus) {
        enabled = status.enabled
        active = status.isActive
        configurationReadable = status.configurationReadable
        model = status.model
        host = status.host
        keySource = status.key.source
        keychainHasKey = status.key.keychainHasKey
        environmentHasKey = status.key.environmentHasKey
        problems = status.key.problems
        summary = status.summary
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, enabled, active, configurationReadable, model, host, keySource
        case keychainHasKey, environmentHasKey, problems, summary
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(active, forKey: .active)
        try container.encode(configurationReadable, forKey: .configurationReadable)
        try container.encode(model, forKey: .model)
        try container.encode(host, forKey: .host)
        // Explicitly null, so "no key" is a value a script can test for.
        if let keySource { try container.encode(keySource, forKey: .keySource) } else { try container.encodeNil(forKey: .keySource) }
        try container.encode(keychainHasKey, forKey: .keychainHasKey)
        try container.encode(environmentHasKey, forKey: .environmentHasKey)
        try container.encode(problems, forKey: .problems)
        try container.encode(summary, forKey: .summary)
    }
}

struct AIChangeDocument: Encodable {
    let schemaVersion = 1
    let kind = "aiChange"
    let change: AISettingsChange
}

struct AITestDocument: Encodable {
    let schemaVersion = 1
    let kind = "aiTest"
    let model: String
    let milliseconds: Int
    let keySource: AIKeySource
    let inputTokens: Int?

    init(_ result: AIConnectionTest) {
        model = result.model
        milliseconds = result.milliseconds
        keySource = result.keySource
        inputTokens = result.inputTokens
    }
}

struct AIDisclosureDocument: Encodable {
    let schemaVersion = 1
    let kind = "aiDisclosure"
    let disclosure: AIDisclosure

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try disclosure.encode(to: encoder)
    }
}

struct AIForgetDocument: Encodable {
    let schemaVersion = 1
    let kind = "aiForget"
    let removed: Int
}
