import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("AI help: the key, the setting, and the gate")
struct AISettingsAndKeyTests {
    static let keychainKey = "ts_test_keychain_key_0123456789"
    static let environmentKey = "ts_test_environment_key_0123456789"

    // MARK: Where the key comes from

    @Test("The Keychain wins over TYPESAFE_API_KEY, which is used when the Keychain has none")
    func lookupOrder() throws {
        let both = AIKeyLookup(store: FakeAPIKeyStore(key: Self.keychainKey), environment: ["TYPESAFE_API_KEY": Self.environmentKey])
        let (key, source) = try both.resolve()
        #expect(source == .keychain)
        #expect(key == (try TypeSafeAPIKey(validating: Self.keychainKey)))

        let environmentOnly = AIKeyLookup(store: FakeAPIKeyStore(), environment: ["TYPESAFE_API_KEY": Self.environmentKey])
        #expect(try environmentOnly.resolve().source == .environment)
        #expect(environmentOnly.status().source == .environment)

        let neither = AIKeyLookup(store: FakeAPIKeyStore(), environment: [:])
        #expect(neither.status().source == nil)
        let error = #expect(throws: AIError.self) { _ = try neither.resolve() }
        #expect(error?.kind == .noKey)
    }

    @Test("Status reads no secret, so macOS has nothing to ask about")
    func statusReadsNoSecret() {
        let store = FakeAPIKeyStore(key: Self.keychainKey)
        let status = AIKeyLookup(store: store, environment: [:]).status()
        #expect(status.source == .keychain)
        #expect(status.keychainHasKey)
        #expect(store.reads == 0)
    }

    @Test("A malformed TYPESAFE_API_KEY is reported, never sent")
    func malformedEnvironmentKey() {
        let lookup = AIKeyLookup(store: FakeAPIKeyStore(), environment: ["TYPESAFE_API_KEY": "two words"])
        let status = lookup.status()
        #expect(status.source == nil)
        #expect(status.problems == ["TYPESAFE_API_KEY is set, but not to something that could be a TypeSafe API key."])
        let error = #expect(throws: AIError.self) { _ = try lookup.resolve() }
        #expect(error?.kind == .invalidKey)
    }

    @Test("A Keychain that refuses is an error, not a reason to use a different key")
    func keychainFailureIsNotAFallback() {
        let store = FakeAPIKeyStore(key: Self.keychainKey)
        store.failure = AIError.keychain(-25293, reading: true)
        let lookup = AIKeyLookup(store: store, environment: ["TYPESAFE_API_KEY": Self.environmentKey])
        let error = #expect(throws: AIError.self) { _ = try lookup.resolve() }
        #expect(error?.kind == .keychain)
        #expect(lookup.status().problems.first?.contains("-25293") == true)
    }

    // MARK: The configuration

    private func load(_ json: String) throws -> (LoadedConfiguration, TemporaryDirectory) {
        let directory = try TemporaryDirectory(prefix: "macup-ai-config")
        let file = directory.appending("config.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return (ConfigurationStore(fileURL: file).load(), directory)
    }

    @Test("With no ai section AI help is off, and a file without one is written without one")
    func offByDefault() throws {
        #expect(MacUpConfiguration.defaults.aiSettings == MacUpConfiguration.AISettings(enabled: false, model: "jev-latest"))
        let (loaded, directory) = try load(#"{"schemaVersion": 1}"#)
        #expect(!loaded.hasErrors)
        #expect(loaded.configuration.ai == nil)
        let store = ConfigurationStore(fileURL: directory.appending("config.json"))
        try store.save(loaded.configuration)
        let written = try String(contentsOf: directory.appending("config.json"), encoding: .utf8)
        #expect(!written.contains("\"ai\""))
    }

    @Test("An ai section decodes, and a model is kept as written")
    func decodes() throws {
        let (loaded, _) = try load(#"{"schemaVersion": 1, "ai": {"enabled": true, "model": "jev-1.13.0"}}"#)
        #expect(!loaded.hasErrors)
        #expect(loaded.configuration.aiSettings == MacUpConfiguration.AISettings(enabled: true, model: "jev-1.13.0"))
    }

    @Test(
        "An ai section MacUp cannot read with certainty is an error, and AI help stays off",
        arguments: [
            (#"{"schemaVersion": 1, "ai": {"enabled": true, "modle": "jev-latest"}}"#, "ai.modle"),
            (#"{"schemaVersion": 1, "ai": {"enabled": true, "model": ""}}"#, "ai.model"),
            (#"{"schemaVersion": 1, "ai": {"enabled": true, "model": "jev latest; rm"}}"#, "ai.model"),
            (#"{"schemaVersion": 1, "ai": {"enabled": "yes"}}"#, "ai.enabled"),
        ]
    )
    func invalidSections(json: String, path: String) throws {
        let (loaded, _) = try load(json)
        #expect(loaded.hasErrors)
        #expect(loaded.issues.contains { $0.severity == .error && $0.path == path }, "\(loaded.issues)")

        let service = AIService(transport: FakeTypeSafeTransport(), keyStore: FakeAPIKeyStore(key: Self.keychainKey))
        #expect(!service.status(loaded, environment: [:]).isActive)
        #expect(!service.appliesEstimates(loaded))
        let error = #expect(throws: AIError.self) { _ = try service.client(loaded, environment: [:]) }
        #expect(error?.kind == .configurationUnreadable)
    }

    // MARK: Turning it on and off

    @Test("Turning AI help on writes ai.enabled; turning it off leaves the file as it was before")
    func editor() throws {
        let directory = try TemporaryDirectory(prefix: "macup-ai-editor")
        let file = directory.appending("config.json")
        try #"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "ignore"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let editor = AISettingsEditor(store: ConfigurationStore(fileURL: file))

        let on = try editor.setEnabled(true)
        #expect(on.changed)
        #expect(on.path == "ai.enabled")
        let enabled = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((enabled["ai"] as? [String: Any])?["enabled"] as? Bool == true)
        #expect(((enabled["items"] as? [String: Any])?["brew:mysql"] as? [String: Any])?["policy"] as? String == "ignore")

        let again = try editor.setEnabled(true)
        #expect(!again.changed)

        _ = try editor.setEnabled(false)
        let disabled = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(disabled["ai"] == nil)
        #expect(((disabled["items"] as? [String: Any])?["brew:mysql"] as? [String: Any])?["policy"] as? String == "ignore")
    }

    @Test("MacUp will not turn AI help on in a configuration it could not read")
    func editorRefusesBrokenFile() throws {
        let directory = try TemporaryDirectory(prefix: "macup-ai-editor")
        let file = directory.appending("config.json")
        let broken = #"{"schemaVersion": 1, "providers": {"homebrew": {"enabeld": false}}}"#
        try broken.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: MacUpError.self) { try AISettingsEditor(store: ConfigurationStore(fileURL: file)).setEnabled(true) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
    }

    // MARK: The gate

    @Test("Nothing is sent unless the configuration is readable, AI help is on, and a key exists")
    func gate() async throws {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering())
        let off = LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/nowhere")
        var on = off
        on.configuration.ai = MacUpConfiguration.AISettings(enabled: true)

        let withKey = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.keychainKey))
        let withoutKey = AIService(transport: transport, keyStore: FakeAPIKeyStore())

        #expect(!withKey.status(off, environment: [:]).isActive)
        #expect(withKey.status(off, environment: [:]).summary == "Off. A key is ready; nothing is sent until you turn AI help on.")
        let disabled = await #expect(throws: AIError.self) { _ = try await withKey.testConnection(off, environment: [:]) }
        #expect(disabled?.kind == .disabled)

        #expect(!withoutKey.status(on, environment: [:]).isActive)
        let noKey = await #expect(throws: AIError.self) { _ = try await withoutKey.testConnection(on, environment: [:]) }
        #expect(noKey?.kind == .noKey)
        #expect(transport.requests.isEmpty, "every refusal above happened before anything was sent")

        #expect(withKey.status(on, environment: [:]).isActive)
        let test = try await withKey.testConnection(on, environment: [:])
        #expect(test.model == "jev-1.13.0")
        #expect(test.keySource == .keychain)
        #expect(transport.requests.count == 1)
        let body = try #require(transport.bodies.first)
        #expect(body["state"] as? String == "MacUp connection test.")
    }

    @Test("The disclosure names every feature, links TypeSafe's agreement, and promises nothing in the background")
    func disclosure() {
        let disclosure = AIDisclosure.standard
        #expect(disclosure.features.map(\.id) == ["ask", "estimate", "test"])
        #expect(disclosure.dataProcessingAgreement.absoluteString == "https://typesafe.ai/legal/data-processing")
        #expect(disclosure.neverSent.contains("Environment variables"))
        #expect(disclosure.neverSent.contains { $0.contains("background") })
        #expect(disclosure.features.allSatisfy { $0.when.hasPrefix("Only when you") })
    }
}
