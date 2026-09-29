import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Validating skipped versions and notes")
struct SkippedVersionAndNoteValidationTests {
    private func load(_ json: String) throws -> LoadedConfiguration {
        let directory = try TemporaryDirectory(prefix: "macup-skip-note-validation")
        let file = directory.appending("config.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return withExtendedLifetime(directory) { ConfigurationStore(fileURL: file).load() }
    }

    /// A configuration whose only item is `brew:mysql`, with `settings` as
    /// its body, written as JSON so the test controls every byte.
    private func load(item settings: String) throws -> LoadedConfiguration {
        try load(#"{"schemaVersion": 1, "items": {"brew:mysql": "# + settings + "}}")
    }

    private func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), as: UTF8.self)
    }

    @Test("A skipped version and a note are read as written, with no issues")
    func validValuesLoad() throws {
        let loaded = try load(item: #"{"policy": "pin", "skipVersion": "26.7.0_2", "note": "waiting for PHP 8.4 support"}"#)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.allowsAutomaticModification)
        let settings = try #require(loaded.configuration.items["brew:mysql"])
        #expect(settings.policy == .pin)
        #expect(settings.skipVersion == "26.7.0_2")
        #expect(settings.note == "waiting for PHP 8.4 support")
    }

    @Test("Both are optional, so a file from before they existed reads exactly as it did")
    func olderFilesAreUnchanged() throws {
        let loaded = try load(item: #"{"policy": "ignore"}"#)
        #expect(loaded.issues.isEmpty)
        #expect(loaded.configuration.items["brew:mysql"] == MacUpConfiguration.ItemSettings(policy: .ignore))
        #expect(loaded.configuration.schemaVersion == 1)
    }

    @Test("An entry with a skip still needs a policy, which may be inherit")
    func policyIsStillRequired() throws {
        let missing = try load(item: #"{"skipVersion": "26.7.0_2"}"#)
        #expect(missing.hasErrors)
        #expect(missing.issues.map(\.path).contains("items.brew:mysql.policy"))

        let inherit = try load(item: #"{"policy": "inherit", "skipVersion": "26.7.0_2"}"#)
        #expect(inherit.issues.isEmpty)
    }

    @Test(
        "A skipped version MacUp cannot hold is an error, and nothing automatic may run",
        arguments: [
            (#""""#, "empty"),
            (#""   ""#, "empty"),
            (#"" 26.7.0_2""#, "whitespace"),
            (#""26.7.0_2 ""#, "whitespace"),
            (#""26.7\u001B[2J""#, "control"),
            (#""26.7‮0""#, "control"),
            (#""26.7\n0""#, "control"),
            ("\"" + String(repeating: "9", count: 129) + "\"", "longer than 128"),
        ]
    )
    func invalidSkippedVersions(value: String, phrase: String) throws {
        let loaded = try load(item: #"{"policy": "auto", "skipVersion": "# + value + "}")
        #expect(loaded.hasErrors)
        #expect(!loaded.allowsAutomaticModification)
        let issue = try #require(loaded.issues.first { $0.path == "items.brew:mysql.skipVersion" }, "\(loaded.issues)")
        #expect(issue.severity == .error)
        #expect(issue.message.contains(phrase), "\(issue.message)")
        // Fail closed: the item is set to Auto Update, but nothing runs.
        let decision = PolicyEngine(loaded).decide(
            item: try PackageID(parsing: "brew:mysql"),
            availableVersion: "27.0.0",
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .unattended
        )
        #expect(decision.action == .deny)
        #expect(decision.source == .configuration)
    }

    @Test(
        "A note MacUp cannot hold is an error, and nothing automatic may run",
        arguments: [
            (#""""#, "cannot be empty"),
            (#""  \t ""#, "cannot be empty"),
            (#""line one\nline two""#, "one line"),
            (#""tab\there""#, "one line"),
            (#""\u001B[31mred""#, "one line"),
            (#""looks ‮right""#, "one line"),
            (#""next line""#, "one line"),
        ]
    )
    func invalidNotes(value: String, phrase: String) throws {
        let loaded = try load(item: #"{"policy": "auto", "note": "# + value + "}")
        #expect(loaded.hasErrors)
        #expect(!loaded.allowsAutomaticModification)
        let issue = try #require(loaded.issues.first { $0.path == "items.brew:mysql.note" }, "\(loaded.issues)")
        #expect(issue.message.contains(phrase), "\(issue.message)")
    }

    @Test("A note is bounded at 200 characters as a person counts them")
    func noteLengthIsCountedInCharacters() throws {
        let limit = MacUpConfiguration.ItemSettings.maximumNoteLength
        #expect(limit == 200)

        let atLimit = try load(item: #"{"policy": "pin", "note": "# + (try jsonString(String(repeating: "a", count: limit))) + "}")
        #expect(atLimit.issues.isEmpty, "\(atLimit.issues)")

        // Each of these is one character on screen and several bytes.
        let emoji = try load(item: #"{"policy": "pin", "note": "# + (try jsonString(String(repeating: "👩‍👩‍👧", count: limit))) + "}")
        #expect(emoji.issues.isEmpty, "\(emoji.issues)")

        let over = try load(item: #"{"policy": "pin", "note": "# + (try jsonString(String(repeating: "a", count: limit + 1))) + "}")
        let issue = try #require(over.issues.first { $0.path == "items.brew:mysql.note" })
        #expect(issue.message == "A note can be at most 200 characters; this one has 201.")
    }

    @Test(
        "A value of the wrong type is an error, and the file is not used",
        arguments: [
            (#""skipVersion": 26.7"#, "items.brew:mysql.skipVersion"),
            (#""skipVersion": true"#, "items.brew:mysql.skipVersion"),
            (#""skipVersion": ["26.7.0_2"]"#, "items.brew:mysql.skipVersion"),
            (#""note": 42"#, "items.brew:mysql.note"),
            (#""note": false"#, "items.brew:mysql.note"),
            (#""note": {"text": "x"}"#, "items.brew:mysql.note"),
        ]
    )
    func wrongTypes(field: String, path: String) throws {
        let loaded = try load(item: #"{"policy": "ignore", "# + field + "}")
        #expect(loaded.hasErrors)
        #expect(!loaded.allowsAutomaticModification)
        #expect(loaded.issues.contains { $0.path == path && $0.message == "Expected a string." }, "\(loaded.issues)")
        // Undecodable, so none of the file is used; in particular not its
        // Ignore rule, and nothing may change while that is so.
        #expect(loaded.configuration == .defaults)
    }

    @Test("null means no skipped version and no note, as it does for every other optional key")
    func nullIsAbsent() throws {
        let loaded = try load(item: #"{"policy": "ask", "skipVersion": null, "note": null}"#)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.configuration.items["brew:mysql"] == MacUpConfiguration.ItemSettings(policy: .ask))
    }

    @Test("Other keys under an item are still refused")
    func otherKeysStillRefused() throws {
        let loaded = try load(item: #"{"policy": "ask", "skipVersions": ["26.7.0_2"]}"#)
        #expect(loaded.hasErrors)
        #expect(loaded.issues.contains { $0.path == "items.brew:mysql.skipVersions" })
    }

    @Test("What the file holds is written back byte for byte in meaning")
    func roundTrip() throws {
        let directory = try TemporaryDirectory(prefix: "macup-skip-note-round-trip")
        let store = ConfigurationStore(fileURL: directory.appending("config.json"))
        var configuration = MacUpConfiguration.defaults
        configuration.items["brew:mysql"] = .init(policy: .inherit, skipVersion: "26.7.0_2", note: "  \"quoted\" and ünïcödé ✓ ")
        try store.save(configuration)

        let loaded = store.load()
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.configuration == configuration)
        // Nothing was trimmed or normalized on the way.
        #expect(loaded.configuration.items["brew:mysql"]?.note == "  \"quoted\" and ünïcödé ✓ ")
    }

    @Test("An entry without either writes neither key, so older files keep their shape")
    func absentKeysAreNotWritten() throws {
        let directory = try TemporaryDirectory(prefix: "macup-skip-note-shape")
        let store = ConfigurationStore(fileURL: directory.appending("config.json"))
        var configuration = MacUpConfiguration.defaults
        configuration.items["brew:git"] = .init(policy: .ignore)
        try store.save(configuration)

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("skipVersion"))
        #expect(!text.contains("note"))
    }
}
