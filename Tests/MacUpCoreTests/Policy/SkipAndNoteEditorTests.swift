import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Editing skipped versions and notes")
struct SkipAndNoteEditorTests {
    private static let mysql = try! PackageID(parsing: "brew:mysql")
    private static let git = try! PackageID(parsing: "brew:git")

    /// A temporary configuration directory. Nothing here touches the real
    /// `~/.config/macup/config.json`.
    private struct Sandbox {
        let directory: TemporaryDirectory
        let editor: PolicyEditor

        init(_ json: String? = nil) throws {
            directory = try TemporaryDirectory(prefix: "macup-skip-note-editor")
            if let json {
                try json.write(to: directory.appending("config.json"), atomically: true, encoding: .utf8)
            }
            editor = PolicyEditor(store: ConfigurationStore(fileURL: directory.appending("config.json")))
        }

        var loaded: LoadedConfiguration { editor.store.load() }
        var bytes: Data? { try? Data(contentsOf: directory.appending("config.json")) }
        var mysql: MacUpConfiguration.ItemSettings? { loaded.configuration.items[SkipAndNoteEditorTests.mysql.rawValue] }
        var contents: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        }
    }

    // MARK: Skipping

    @Test("Skipping a version writes it under the item, which keeps following its provider")
    func skipWritesTheVersion() throws {
        let sandbox = try Sandbox()
        let change = try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)

        #expect(change.changed)
        #expect(change.subject == .item(Self.mysql))
        #expect(change.setting == .skipVersion)
        #expect(change.previousValue == nil)
        #expect(change.newValue == "26.7.0_2")
        #expect(change.path == "items.brew:mysql.skipVersion")
        #expect(change.summary == "brew:mysql now skips 26.7.0_2. MacUp will leave that version alone and offer the next one.")
        #expect(change.warnings.isEmpty)

        let loaded = sandbox.loaded
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(sandbox.mysql == MacUpConfiguration.ItemSettings(policy: .inherit, skipVersion: "26.7.0_2"))
        #expect(PolicyEngine(loaded).effectivePolicy(for: Self.mysql).policy == .ask, "the rule is unchanged")
        #expect(loaded.configuration.schemaVersion == 1, "an additive key needs no new schema")
        #expect(sandbox.contents == ["config.json"])
    }

    @Test("A second skip replaces the first; there is one skipped version per item")
    func skipReplaces() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.skipVersion("26.7.0_1", for: Self.mysql)
        let change = try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        #expect(change.changed)
        #expect(change.previousValue == "26.7.0_1")
        #expect(change.summary == "brew:mysql now skips 26.7.0_2 instead of 26.7.0_1.")
        #expect(sandbox.mysql?.skipVersion == "26.7.0_2")
    }

    @Test("Skipping the version already skipped writes nothing and says so")
    func skipIsIdempotent() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        let before = try #require(sandbox.bytes)

        let change = try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        #expect(!change.changed)
        #expect(change.summary == "brew:mysql already skips 26.7.0_2; nothing was changed.")
        #expect(sandbox.bytes == before)
    }

    @Test("A skip keeps the item's rule and note, and setting the rule keeps the skip and note")
    func skipAndRuleLiveTogether() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.auto, for: Self.mysql)
        try sandbox.editor.setNote("waiting for PHP 8.4 support", for: Self.mysql)
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        #expect(sandbox.mysql == .init(policy: .auto, skipVersion: "26.7.0_2", note: "waiting for PHP 8.4 support"))

        try sandbox.editor.setPolicy(.ask, for: Self.mysql)
        #expect(sandbox.mysql == .init(policy: .ask, skipVersion: "26.7.0_2", note: "waiting for PHP 8.4 support"),
                "changing the rule must not forget the skip or the note")
    }

    @Test("Stopping a skip removes only the skip")
    func unskipKeepsTheRest() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.auto, for: Self.mysql)
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)

        let change = try sandbox.editor.clearSkippedVersion(for: Self.mysql)
        #expect(change.changed)
        #expect(change.previousValue == "26.7.0_2")
        #expect(change.newValue == nil)
        #expect(change.summary == "brew:mysql no longer skips 26.7.0_2, so that version follows the item's rule again.")
        #expect(sandbox.mysql == .init(policy: .auto))
    }

    @Test("Stopping the only thing an entry held removes the entry")
    func unskipRemovesAnEmptyEntry() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        try sandbox.editor.clearSkippedVersion(for: Self.mysql)
        #expect(sandbox.loaded.configuration.items.isEmpty, "an entry saying only inherit is the same as none")
    }

    @Test("Stopping a skip that was never set changes nothing, and creates no file")
    func unskipNothing() throws {
        let empty = try Sandbox()
        let change = try empty.editor.clearSkippedVersion(for: Self.mysql)
        #expect(!change.changed)
        #expect(change.summary == "brew:mysql skips no version, so there was nothing to stop skipping.")
        #expect(empty.contents.isEmpty)

        // An entry that says inherit and nothing else is left as it was:
        // stopping a skip is not a reason to tidy up a rule.
        let explicit = try Sandbox(#"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "inherit"}}}"#)
        let before = try #require(explicit.bytes)
        #expect(!(try explicit.editor.clearSkippedVersion(for: Self.mysql)).changed)
        #expect(explicit.bytes == before)
    }

    @Test("Skipping on an item a rule already holds is stored, with a warning that it does nothing yet")
    func skipOnAHeldItemWarns() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.pin, for: Self.mysql)
        let pinned = try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        #expect(pinned.changed)
        #expect(pinned.warnings.count == 1)
        #expect(pinned.warnings.first?.contains("pinned in MacUp") == true)

        try sandbox.editor.setPolicy(.ignore, for: Self.git)
        let ignored = try sandbox.editor.skipVersion("2.44.0", for: Self.git)
        #expect(ignored.warnings.first?.contains("is ignored") == true)

        // The warning follows the rule in effect, wherever it comes from.
        try sandbox.editor.setPolicy(.ignore, for: ProviderID.npm)
        let inherited = try sandbox.editor.skipVersion("5.0.0", for: try PackageID(parsing: "npm:typescript"))
        #expect(inherited.warnings.first?.contains("is ignored") == true)
    }

    @Test("Clearing an item's rule keeps its skip and note, rather than bringing a skipped version back")
    func clearPolicyKeepsTheSkip() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.pin, for: Self.mysql)
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        try sandbox.editor.setNote("waiting for PHP 8.4 support", for: Self.mysql)

        let change = try sandbox.editor.clearPolicy(for: Self.mysql)
        #expect(change.changed)
        #expect(change.previousValue == "pin")
        #expect(sandbox.mysql == .init(policy: .inherit, skipVersion: "26.7.0_2", note: "waiting for PHP 8.4 support"))

        // Clearing again: the entry has no rule of its own left to clear.
        let again = try sandbox.editor.clearPolicy(for: Self.mysql)
        #expect(!again.changed)
        #expect(sandbox.mysql?.skipVersion == "26.7.0_2")
    }

    // MARK: Notes

    @Test("A note is stored exactly as given")
    func noteIsVerbatim() throws {
        let sandbox = try Sandbox()
        let note = #"  waiting for PHP 8.4 — see "issue #12" ✓ "#
        let change = try sandbox.editor.setNote(note, for: Self.mysql)
        #expect(change.changed)
        #expect(change.setting == .note)
        #expect(change.path == "items.brew:mysql.note")
        #expect(change.newValue == note)
        #expect(change.summary == "brew:mysql now has a note: \"\(note)\".")
        #expect(sandbox.mysql == .init(policy: .inherit, note: note))
    }

    @Test("Replacing and removing a note report what they replaced")
    func noteReplaceAndRemove() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setNote("first", for: Self.mysql)
        let replaced = try sandbox.editor.setNote("second", for: Self.mysql)
        #expect(replaced.previousValue == "first")
        #expect(replaced.summary == "brew:mysql's note is now \"second\".")

        let same = try sandbox.editor.setNote("second", for: Self.mysql)
        #expect(!same.changed)
        #expect(same.summary == "brew:mysql already has this note; nothing was changed.")

        let removed = try sandbox.editor.clearNote(for: Self.mysql)
        #expect(removed.changed)
        #expect(removed.previousValue == "second")
        #expect(removed.summary == "brew:mysql no longer has a note.")
        #expect(sandbox.loaded.configuration.items.isEmpty)

        let nothing = try sandbox.editor.clearNote(for: Self.mysql)
        #expect(!nothing.changed)
        #expect(nothing.summary == "brew:mysql has no note, so there was nothing to remove.")
    }

    @Test(
        "A value the configuration could not hold is refused, and the file is left alone",
        arguments: [
            (Setting.note, String(repeating: "n", count: 201), "at most 200 characters"),
            (Setting.note, "first line\nsecond line", "one line"),
            (Setting.note, "   ", "cannot be empty"),
            (Setting.skip, "", "is empty"),
            (Setting.skip, "26.7.0_2\u{1B}[0m", "control"),
            (Setting.skip, " 26.7.0_2", "whitespace"),
        ]
    )
    func refusesValuesItCouldNotStore(setting: Setting, value: String, phrase: String) throws {
        let sandbox = try Sandbox(#"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "pin"}}}"#)
        let before = try #require(sandbox.bytes)

        let error = #expect(throws: MacUpError.self) {
            switch setting {
            case .note: try sandbox.editor.setNote(value, for: Self.mysql)
            case .skip: try sandbox.editor.skipVersion(value, for: Self.mysql)
            }
        }
        #expect(error?.kind == .configurationInvalid)
        #expect(error?.detail?.contains(phrase) == true, "\(error?.detail ?? "")")
        #expect(sandbox.bytes == before)
    }

    enum Setting: Sendable {
        case note
        case skip
    }

    @Test("A configuration with errors is never edited for a skip or a note either")
    func unreadableConfigurationRefused() throws {
        let sandbox = try Sandbox(#"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "pin", "note": 7}}}"#)
        let before = try #require(sandbox.bytes)

        #expect(throws: MacUpError.self) { try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql) }
        #expect(throws: MacUpError.self) { try sandbox.editor.clearSkippedVersion(for: Self.mysql) }
        #expect(throws: MacUpError.self) { try sandbox.editor.setNote("fixed", for: Self.mysql) }
        #expect(throws: MacUpError.self) { try sandbox.editor.clearNote(for: Self.mysql) }
        #expect(sandbox.bytes == before, "MacUp must not replace a file it misread")
    }

    // MARK: What it means

    @Test("What the editor writes is what the engine then decides")
    func editedSkipTakesEffect() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.setPolicy(.auto, for: Self.mysql)
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        try sandbox.editor.setNote("waiting for PHP 8.4 support", for: Self.mysql)

        let engine = PolicyEngine(sandbox.loaded)
        let skipped = engine.decide(
            item: Self.mysql,
            availableVersion: "26.7.0_2",
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .unattended
        )
        #expect(skipped.action == .deny)
        #expect(skipped.source == .skippedVersion)
        #expect(skipped.note == "waiting for PHP 8.4 support")

        let next = engine.decide(
            item: Self.mysql,
            availableVersion: "26.8.0",
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .unattended
        )
        #expect(next.action == .allow)
    }

    @Test("A change to a skip or a note survives a round trip through JSON, for --json output")
    func changesAreCodable() throws {
        let sandbox = try Sandbox()
        let skip = try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        let note = try sandbox.editor.setNote("waiting", for: Self.mysql)
        for change in [skip, note] {
            let data = try JSONEncoder().encode(change)
            #expect(try JSONDecoder().decode(PolicyChange.self, from: data) == change)
        }
        let text = String(decoding: try JSONEncoder().encode(skip), as: UTF8.self)
        #expect(text.contains(#""setting":"skipVersion""#), "\(text)")
    }

    @Test("The listing reports a skip and a note, and where they live")
    func listingShowsBoth() throws {
        let sandbox = try Sandbox()
        try sandbox.editor.skipVersion("26.7.0_2", for: Self.mysql)
        try sandbox.editor.setNote("waiting for PHP 8.4 support", for: Self.mysql)

        let listing = PolicyListing(sandbox.loaded)
        let rule = try #require(listing.rule(for: Self.mysql))
        #expect(rule.policy == .inherit)
        #expect(rule.effectivePolicy == .ask)
        #expect(rule.skipVersion == "26.7.0_2")
        #expect(rule.note == "waiting for PHP 8.4 support")
        #expect(rule.skips("26.7.0_2"))
        #expect(!rule.skips("26.7.0"))
        #expect(!listing.isDefault)

        let data = try JSONEncoder().encode(listing)
        #expect(try JSONDecoder().decode(PolicyListing.self, from: data) == listing)
    }
}
