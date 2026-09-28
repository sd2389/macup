import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Policy edits")
struct PolicyEditorTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let claude = try! PackageID(parsing: "npm:@anthropic-ai/claude-code")

    /// A temporary configuration directory with an optional starting file.
    /// Nothing here touches the real `~/.config/macup/config.json`.
    private struct Sandbox {
        let directory: TemporaryDirectory
        let editor: PolicyEditor

        init(_ json: String? = nil) throws {
            directory = try TemporaryDirectory(prefix: "macup-policy-editor")
            if let json {
                try json.write(to: directory.appending("config.json"), atomically: true, encoding: .utf8)
            }
            editor = PolicyEditor(store: ConfigurationStore(fileURL: directory.appending("config.json")))
        }

        var file: URL { directory.appending("config.json") }
        var loaded: LoadedConfiguration { editor.store.load() }
        var bytes: Data? { try? Data(contentsOf: file) }

        /// Every name in the directory, so a test can prove no temporary file
        /// was left behind.
        var contents: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }

        func mode(of url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue
        }
    }

    private static let populated = """
        {
          "schemaVersion": 1,
          "global": { "defaultPolicy": "ask", "confirmMajorUpdates": true },
          "providers": {
            "homebrew": { "enabled": true, "policy": "ask", "executablePath": "/opt/homebrew/bin/brew" },
            "npm": { "enabled": false, "policy": "inherit" }
          },
          "items": {
            "brew:postgresql": { "policy": "ignore" }
          },
          "schedule": { "enabled": true, "frequency": "weekly", "time": "07:30", "weekday": "friday" },
          "security": { "requireApproval": true, "faceMatchThreshold": 0.6 }
        }
        """

    // MARK: Round trips

    @Test("Setting an item policy writes it, and says what it changed")
    func setItemPolicy() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.setPolicy(.auto, for: Self.git)

        #expect(change.changed)
        #expect(change.subject == .item(Self.git))
        #expect(change.setting == .policy)
        #expect(change.previousValue == nil)
        #expect(change.newValue == "auto")
        #expect(change.path == "items.brew:git.policy")
        #expect(change.summary.contains("brew:git"))
        #expect(change.summary.contains("Auto Update"))
        #expect(change.warnings.isEmpty)

        let loaded = sandbox.loaded
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.configuration.items["brew:git"]?.policy == .auto)
    }

    @Test("Changing an existing item policy reports the value it replaced")
    func replaceItemPolicy() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.setPolicy(.ask, forItem: "brew:postgresql")
        #expect(change.changed)
        #expect(change.previousValue == "ignore")
        #expect(change.newValue == "ask")
        #expect(change.summary.contains("Ignore"))
        #expect(change.summary.contains("Ask First"))
        #expect(sandbox.loaded.configuration.items["brew:postgresql"]?.policy == .ask)
    }

    @Test("Clearing an item policy removes the rule so the item inherits again")
    func clearItemPolicy() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.clearPolicy(forItem: "brew:postgresql")
        #expect(change.changed)
        #expect(change.previousValue == "ignore")
        #expect(change.newValue == nil)
        #expect(change.summary.contains("inherits again"))
        #expect(sandbox.loaded.configuration.items["brew:postgresql"] == nil)
        #expect(PolicyEngine(sandbox.loaded).effectivePolicy(for: try PackageID(parsing: "brew:postgresql")).policy == .ask)
    }

    @Test("Setting a provider policy keeps everything else about that provider")
    func setProviderPolicy() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.setPolicy(.auto, for: .homebrew)
        #expect(change.changed)
        #expect(change.previousValue == "ask")
        #expect(change.newValue == "auto")
        #expect(change.path == "providers.homebrew.policy")

        let settings = sandbox.loaded.configuration.settings(for: .homebrew)
        #expect(settings.policy == .auto)
        #expect(settings.enabled)
        #expect(settings.executablePath == "/opt/homebrew/bin/brew", "an unrelated setting must survive an edit")
    }

    @Test("Enabling and disabling a provider round-trips through the file")
    func setProviderEnabled() throws {
        let sandbox = try Sandbox(Self.populated)
        let enable = try sandbox.editor.setProviderEnabled(true, for: .npm)
        #expect(enable.changed)
        #expect(enable.setting == .enabled)
        #expect(enable.previousValue == "false")
        #expect(enable.newValue == "true")
        #expect(enable.summary.contains("disabled"))
        #expect(enable.summary.contains("enabled"))
        #expect(sandbox.loaded.configuration.settings(for: .npm).enabled)

        let disable = try sandbox.editor.setProviderEnabled(false, for: .npm)
        #expect(disable.changed)
        #expect(!sandbox.loaded.configuration.settings(for: .npm).enabled)
        #expect(sandbox.loaded.configuration.settings(for: .npm).policy == .inherit, "the policy is untouched")
    }

    @Test("Setting the global default policy round-trips through the file")
    func setDefaultPolicy() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.setDefaultPolicy(.ignore)
        #expect(change.changed)
        #expect(change.subject == .global)
        #expect(change.previousValue == "ask")
        #expect(change.newValue == "ignore")
        #expect(change.path == "global.defaultPolicy")
        #expect(sandbox.loaded.configuration.global.defaultPolicy == .ignore)
        #expect(sandbox.loaded.configuration.global.confirmMajorUpdates, "an unrelated setting must survive an edit")
    }

    @Test("An edit leaves the rest of the configuration alone")
    func unrelatedSectionsSurvive() throws {
        let sandbox = try Sandbox(Self.populated)
        try sandbox.editor.setPolicy(.ignore, for: Self.claude)
        let configuration = sandbox.loaded.configuration

        #expect(configuration.schedule.enabled)
        #expect(configuration.schedule.frequency == .weekly)
        #expect(configuration.schedule.time == "07:30")
        #expect(configuration.schedule.weekday == .friday)
        #expect(configuration.security.requireApproval)
        #expect(configuration.security.faceMatchThreshold == 0.6)
        #expect(configuration.items["brew:postgresql"]?.policy == .ignore)
        #expect(
            try String(contentsOf: sandbox.file, encoding: .utf8).contains("\"faceMatchThreshold\" : 0.6"),
            "a threshold written as 0.6 must still read as 0.6"
        )
    }

    @Test("With no configuration file yet, the first edit creates a valid one")
    func firstEditCreatesTheFile() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.loaded.source == .defaults)

        let change = try sandbox.editor.setPolicy(.ignore, for: Self.git)
        #expect(change.changed)
        #expect(change.previousValue == nil)

        let loaded = sandbox.loaded
        #expect(loaded.source == .file)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.configuration.items["brew:git"]?.policy == .ignore)
        #expect(loaded.configuration.schemaVersion == MacUpConfiguration.currentSchemaVersion)
        #expect(sandbox.contents == ["config.json"], "no temporary file may be left behind")
    }

    // MARK: Honest about doing nothing

    @Test("Setting a policy to the value it already has changes nothing and says so")
    func idempotentSet() throws {
        let sandbox = try Sandbox(Self.populated)
        let before = try #require(sandbox.bytes)

        let change = try sandbox.editor.setPolicy(.ignore, forItem: "brew:postgresql")
        #expect(!change.changed)
        #expect(change.previousValue == "ignore")
        #expect(change.newValue == "ignore")
        #expect(change.summary.contains("already"))
        #expect(sandbox.bytes == before, "an edit that changes nothing must not rewrite the file")
    }

    @Test("Setting a provider to the state it is already in changes nothing")
    func idempotentProviderEdit() throws {
        let sandbox = try Sandbox(Self.populated)
        let before = try #require(sandbox.bytes)
        let change = try sandbox.editor.setProviderEnabled(false, for: .npm)
        #expect(!change.changed)
        #expect(change.summary.contains("already"))
        #expect(sandbox.bytes == before)
    }

    @Test("A provider the file never mentioned is already enabled and inheriting")
    func providerDefaultsAreAlreadySet() throws {
        let sandbox = try Sandbox(#"{"schemaVersion":1}"#)
        let before = try #require(sandbox.bytes)

        let enable = try sandbox.editor.setProviderEnabled(true, for: .mise)
        #expect(!enable.changed, "mise was already enabled by default")
        #expect(enable.previousValue == "true")
        #expect(enable.summary.contains("already enabled"))

        let inherit = try sandbox.editor.setPolicy(.inherit, for: .mise)
        #expect(!inherit.changed)
        #expect(inherit.previousValue == "inherit")

        #expect(sandbox.bytes == before, "a file gains no section for a provider it agrees with")
    }

    @Test("Clearing a rule that was never set is not reported as a change")
    func clearMissingRule() throws {
        let sandbox = try Sandbox(Self.populated)
        let before = try #require(sandbox.bytes)

        let change = try sandbox.editor.clearPolicy(for: Self.git)
        #expect(!change.changed)
        #expect(change.previousValue == nil)
        #expect(change.newValue == nil)
        #expect(change.summary.contains("nothing to clear"))
        #expect(sandbox.bytes == before)
    }

    @Test("Clearing a rule when there is no file at all creates no file")
    func clearWithoutFile() throws {
        let sandbox = try Sandbox()
        let change = try sandbox.editor.clearPolicy(for: Self.git)
        #expect(!change.changed)
        #expect(sandbox.contents.isEmpty)
    }

    // MARK: Refusals

    @Test(
        "Anything that is not a package ID is refused before the file is touched",
        arguments: ["pip:requests", "brew postgresql", "brew:", "git", "brew:-force", "  brew:git"]
    )
    func invalidPackageIDsRefused(name: String) throws {
        let sandbox = try Sandbox(Self.populated)
        let before = try #require(sandbox.bytes)

        #expect(throws: PackageID.ValidationError.self) { try sandbox.editor.setPolicy(.ignore, forItem: name) }
        #expect(throws: PackageID.ValidationError.self) { try sandbox.editor.clearPolicy(forItem: name) }
        #expect(sandbox.bytes == before)
    }

    @Test("A key MacUp does not know is an error, so the edit is refused and the key survives")
    func unknownKeysAreNotDestroyed() throws {
        let sandbox = try Sandbox("""
            {
              "schemaVersion": 1,
              "items": { "brew:postgresql": { "policy": "ignore" } },
              "myOwnNote": "do not lose this"
            }
            """)
        let before = try #require(sandbox.bytes)

        let error = #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.auto, for: Self.git) }
        #expect(error?.kind == .configurationInvalid)
        #expect(error?.detail?.contains("myOwnNote") == true, "\(error?.detail ?? "")")
        #expect(sandbox.bytes == before, "the file must be exactly as the user left it")
        #expect(try String(contentsOf: sandbox.file, encoding: .utf8).contains("do not lose this"))
    }

    @Test("A typo inside a section is refused too, rather than half-understood")
    func unknownNestedKeyRefused() throws {
        let sandbox = try Sandbox(#"{"schemaVersion":1,"providers":{"homebrew":{"enabeld":false}}}"#)
        let before = try #require(sandbox.bytes)
        let error = #expect(throws: MacUpError.self) { try sandbox.editor.setProviderEnabled(false, for: .npm) }
        #expect(error?.detail?.contains("enabeld") == true)
        #expect(sandbox.bytes == before)
    }

    @Test(
        "A configuration with errors is never rewritten, and the refusal names what to fix",
        arguments: [
            (#"{"schemaVersion":1,"schedule":{"time":"25:00"}}"#, "schedule.time"),
            (#"{"schemaVersion":1,"providers":{"homebew":{"enabled":false}}}"#, "providers.homebew"),
            (#"{"schemaVersion":1,"items":{"pip:requests":{"policy":"ignore"}}}"#, "items.pip:requests"),
            (#"{"schemaVersion":1,"global":{"defaultPolicy":"always"}}"#, "global.defaultPolicy"),
            (#"{"schemaVersion":2}"#, "schemaVersion"),
            ("not json at all", ""),
        ]
    )
    func invalidConfigurationRefused(json: String, expectedPath: String) throws {
        let sandbox = try Sandbox(json)
        let before = try #require(sandbox.bytes)

        let error = #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.ignore, for: Self.git) }
        #expect(error?.kind == .configurationInvalid)
        #expect(error?.message.contains("could not read") == true)
        #expect(error?.recoverySuggestion != nil)
        if !expectedPath.isEmpty {
            #expect(error?.detail?.contains(expectedPath) == true, "\(error?.detail ?? "")")
        }
        #expect(sandbox.bytes == before, "MacUp must not replace a file it misread")
    }

    @Test("Every kind of edit refuses an unreadable configuration, not just item rules")
    func everyEditRefusesInvalidConfiguration() throws {
        let sandbox = try Sandbox(#"{"schemaVersion":1,"schedule":{"time":"25:00"}}"#)
        let before = try #require(sandbox.bytes)

        #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.auto, for: Self.git) }
        #expect(throws: MacUpError.self) { try sandbox.editor.clearPolicy(for: Self.git) }
        #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.auto, for: .homebrew) }
        #expect(throws: MacUpError.self) { try sandbox.editor.setProviderEnabled(false, for: .npm) }
        #expect(throws: MacUpError.self) { try sandbox.editor.setDefaultPolicy(.auto) }
        #expect(sandbox.bytes == before)
    }

    @Test("An edit that would leave an unusable configuration is refused")
    func refusesToBreakTheConfiguration() throws {
        let sandbox = try Sandbox(Self.populated)
        let before = try #require(sandbox.bytes)

        let providerPin = #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.pin, for: .homebrew) }
        #expect(providerPin?.detail?.contains("individual items") == true, "\(providerPin?.detail ?? "")")

        for policy in [UpdatePolicy.pin, .inherit] {
            let error = #expect(throws: MacUpError.self) { try sandbox.editor.setDefaultPolicy(policy) }
            #expect(error?.message.contains("global.defaultPolicy") == true)
        }

        let unknownProvider = #expect(throws: MacUpError.self) {
            try sandbox.editor.setPolicy(.auto, for: ProviderID(rawValue: "cargo"))
        }
        #expect(unknownProvider?.detail?.contains("Unknown provider") == true)

        #expect(sandbox.bytes == before)
    }

    @Test("MacUp will not replace a configuration file that is a symlink")
    func symlinkedConfigurationRefused() throws {
        let sandbox = try Sandbox()
        let target = sandbox.directory.appending("real-config.json")
        try #"{"schemaVersion":1}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: sandbox.file, withDestinationURL: target)

        // Reading a symlink is allowed and only warns, so the refusal has to
        // come from the write.
        #expect(sandbox.loaded.hasErrors == false)
        let error = #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.ignore, for: Self.git) }
        #expect(error?.message.contains("symlink") == true)
        #expect(try String(contentsOf: target, encoding: .utf8) == #"{"schemaVersion":1}"#)
    }

    // MARK: How the file is written

    @Test("An edited configuration file, and any directory made for it, stay private")
    func filePermissionsStayPrivate() throws {
        let sandbox = try Sandbox()
        let nested = sandbox.directory.appending("config/macup")
        let editor = PolicyEditor(store: ConfigurationStore(fileURL: nested.appendingPathComponent("config.json")))
        try editor.setPolicy(.ignore, for: Self.git)

        #expect(try sandbox.mode(of: nested.appendingPathComponent("config.json")) == 0o600)
        #expect(try sandbox.mode(of: nested) == 0o700)
    }

    @Test("A configuration MacUp would ignore for being world-writable is not edited either")
    func worldWritableDirectoryRefused() throws {
        let sandbox = try Sandbox(#"{"schemaVersion":1}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: sandbox.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sandbox.directory.path) }

        let error = #expect(throws: MacUpError.self) { try sandbox.editor.setPolicy(.ignore, for: Self.git) }
        #expect(error?.kind == .configurationInvalid)
    }

    @Test("Setting auto for macOS is stored, with a warning that it has no effect")
    func macOSAutoCarriesAWarning() throws {
        let sandbox = try Sandbox(Self.populated)
        let change = try sandbox.editor.setPolicy(.auto, forItem: "macos:26.6.2")
        #expect(change.changed)
        #expect(change.warnings.count == 1)
        #expect(change.warnings.first?.contains("Ask First") == true)
        #expect(sandbox.loaded.configuration.items["macos:26.6.2"]?.policy == .auto)
    }

    @Test("A change survives a round trip through JSON, for --json output")
    func changeIsCodable() throws {
        let sandbox = try Sandbox()
        let change = try sandbox.editor.setPolicy(.ignore, for: Self.git)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(change)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""subject":{"id":"brew:git","kind":"item"}"#), "\(text)")
        #expect(try JSONDecoder().decode(PolicyChange.self, from: data) == change)

        let providerChange = try sandbox.editor.setProviderEnabled(false, for: .npm)
        let globalChange = try sandbox.editor.setDefaultPolicy(.auto)
        for value in [providerChange, globalChange] {
            let encoded = try encoder.encode(value)
            #expect(try JSONDecoder().decode(PolicyChange.self, from: encoded) == value)
        }
        #expect(String(decoding: try encoder.encode(globalChange), as: UTF8.self).contains(#"{"kind":"global"}"#))
    }

    @Test("Edits accumulate instead of replacing each other")
    func editsAccumulate() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.ignore, for: Self.git)
        try sandbox.editor.setPolicy(.auto, for: Self.claude)
        try sandbox.editor.setProviderEnabled(false, for: .mise)
        try sandbox.editor.setDefaultPolicy(.auto)

        let loaded = sandbox.loaded
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.configuration.items.count == 2)
        #expect(loaded.configuration.items["brew:git"]?.policy == .ignore)
        #expect(loaded.configuration.items[Self.claude.rawValue]?.policy == .auto)
        #expect(!loaded.configuration.settings(for: .mise).enabled)
        #expect(loaded.configuration.global.defaultPolicy == .auto)
        #expect(sandbox.contents == ["config.json"])
    }

    @Test("What the editor writes is what the engine then decides")
    func editedRulesTakeEffect() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setDefaultPolicy(.auto)
        try sandbox.editor.setPolicy(.ignore, for: Self.git)
        try sandbox.editor.setProviderEnabled(false, for: .npm)

        let engine = PolicyEngine(sandbox.loaded)
        let ignored = engine.decide(
            item: Self.git,
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .interactive
        )
        #expect(ignored.action == .deny)
        #expect(ignored.source == .item)

        let disabled = engine.decide(
            item: Self.claude,
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .interactive
        )
        #expect(disabled.action == .deny)
        #expect(disabled.source == .providerDisabled)

        let allowed = engine.decide(
            item: try PackageID(parsing: "brew:jq"),
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .unattended
        )
        #expect(allowed.action == .allow)
        #expect(allowed.source == .global)
    }
}
