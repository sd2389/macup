import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("HistoryStore")
struct HistoryStoreTests {
    /// A timestamp that survives the file's millisecond precision exactly, so
    /// a round-trip can be compared field by field.
    static let moment = Date(timeIntervalSince1970: 1_700_000_000.25)

    private func entry(
        _ id: String = "brew:git",
        at timestamp: Date = HistoryStoreTests.moment,
        outcome: ExecutionResult.Outcome = .succeeded,
        command: String? = "/opt/homebrew/bin/brew upgrade git",
        verification: VerificationResult.Outcome? = .verified,
        skipReason: String? = nil,
        errorSummary: String? = nil
    ) throws -> HistoryEntry {
        HistoryEntry(
            timestamp: timestamp,
            origin: .cli,
            item: try PackageID(parsing: id),
            versionBefore: "2.50.0",
            versionTarget: "2.50.1",
            versionAfter: outcome == .succeeded ? "2.50.1" : nil,
            command: command,
            outcome: outcome,
            verification: verification,
            errorSummary: errorSummary,
            skipReason: skipReason,
            durationSeconds: 12.5
        )
    }

    private func store(_ directory: TemporaryDirectory, maximumEntries: Int = HistoryStore.maximumEntries) -> HistoryStore {
        HistoryStore(
            fileURL: directory.url.appendingPathComponent("state/macup/history.jsonl"),
            maximumEntries: maximumEntries
        )
    }

    @Test("An entry round-trips through the file")
    func entryRoundTrips() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        let written = try entry()
        try store.append(written)

        let read = try #require(try store.load().first)
        #expect(read == written)
    }

    @Test("A store built from MacUp's paths writes to the documented file")
    func usesTheDocumentedPath() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let paths = MacUpPaths(
            configDirectory: directory.path + "/.config/macup",
            stateDirectory: directory.path + "/.local/state/macup",
            launchAgentsDirectory: directory.path + "/agents"
        )
        let store = HistoryStore(paths: paths)
        #expect(store.path == paths.historyFile)
        #expect(store.path.hasSuffix("/.local/state/macup/history.jsonl"))

        // The parent directories do not exist yet; appending creates them.
        try store.append(try entry())
        #expect(try store.load().count == 1)
    }

    @Test("Reading history with no file yet finds nothing")
    func missingFileIsEmpty() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let reading = try store(directory).read()
        #expect(reading.entries.isEmpty)
        #expect(reading.findings.isEmpty)
    }

    @Test("History is read newest first, and a limit caps it")
    func newestFirst() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        for (offset, name) in ["brew:git", "brew:openssl", "npm:typescript"].enumerated() {
            try store.append(try entry(name, at: Self.moment.addingTimeInterval(Double(offset))))
        }

        #expect(try store.load().map(\.item.rawValue) == ["npm:typescript", "brew:openssl", "brew:git"])
        #expect(try store.load(limit: 2).map(\.item.rawValue) == ["npm:typescript", "brew:openssl"])
        #expect(try store.load(limit: 0).isEmpty)
    }

    @Test("A skip is stored with the reason for it")
    func skipReasonIsStored() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry(
            outcome: .skipped,
            command: nil,
            verification: nil,
            skipReason: "git is ignored (a rule you set for this item)."
        ))

        let read = try #require(try store.load().first)
        #expect(read.outcome == .skipped)
        #expect(read.skipReason == "git is ignored (a rule you set for this item).")
        #expect(read.command == nil)
    }

    @Test("Nothing token-shaped survives into the file")
    func secretsAreRedacted() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry(
            command: "/opt/homebrew/bin/brew upgrade git GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123",
            errorSummary: "npm ERR! https://user:hunter2@registry.example.com refused npm_authToken=npm_0123456789012345678901234567890123"
        ))

        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("npm_0123456789012345678901234567890123"))
        #expect(text.contains(Redactor.placeholder))
        // What is left still tells the user which command was involved.
        #expect(try store.load().first?.command?.hasPrefix("/opt/homebrew/bin/brew") == true)
    }

    @Test("The file and its directory are owner-only")
    func filePermissionsAreOwnerOnly() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry())

        var file = stat()
        #expect(stat(store.path, &file) == 0)
        #expect(file.st_mode & 0o777 == 0o600)
        #expect(file.st_uid == getuid())

        var parent = stat()
        #expect(stat(store.fileURL.deletingLastPathComponent().path, &parent) == 0)
        #expect(parent.st_mode & 0o777 == 0o700)
    }

    @Test("Loosened permissions are tightened again on the next append")
    func permissionsAreRestored() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry())
        #expect(chmod(store.path, 0o644) == 0)

        try store.append(try entry("brew:openssl"))
        var file = stat()
        #expect(stat(store.path, &file) == 0)
        #expect(file.st_mode & 0o777 == 0o600)
    }

    @Test("MacUp will not write its history through a symlink")
    func refusesToWriteThroughASymlink() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        let elsewhere = directory.url.appendingPathComponent("elsewhere.jsonl")
        try Data().write(to: elsewhere)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: elsewhere)

        let written = try entry()
        let failure = #expect(throws: MacUpError.self) { try store.append(written) }
        #expect(failure?.kind == .configurationInvalid)
        #expect(try Data(contentsOf: elsewhere).isEmpty, "the symlink's target must be untouched")
        #expect(throws: MacUpError.self) { try store.load() }
    }

    @Test("MacUp will not write its history into a directory other users can change")
    func refusesAWorldWritableDirectory() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        let parent = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(chmod(parent.path, 0o777) == 0)

        let written = try entry()
        let failure = #expect(throws: MacUpError.self) { try store.append(written) }
        #expect(failure?.kind == .configurationInvalid)
        #expect(!FileManager.default.fileExists(atPath: store.path))
    }

    @Test("A line that cannot be decoded is skipped and reported, never guessed at")
    func malformedLinesAreReported() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry("brew:git"))
        try store.append(try entry("brew:openssl"))

        // Two lines the way a half-written entry and a stray edit would leave them.
        var text = try String(contentsOf: store.fileURL, encoding: .utf8)
        text += #"{"schemaVersion":1,"item":"# + "\n"
        text += "not json at all\n"
        try text.write(to: store.fileURL, atomically: true, encoding: .utf8)

        let reading = try store.read()
        #expect(reading.entries.map(\.item.rawValue) == ["brew:openssl", "brew:git"])
        #expect(reading.unreadableLines == 2)
        let finding = try #require(reading.findings.first)
        #expect(finding.id == "history.unreadableEntries")
        #expect(finding.severity == .warning)
    }

    @Test("History is trimmed to its maximum, keeping the newest entries")
    func trimsToTheMaximum() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory, maximumEntries: 4)
        for offset in 0..<9 {
            try store.append(try entry(
                "brew:item\(offset)",
                at: Self.moment.addingTimeInterval(Double(offset))
            ))
        }

        let entries = try store.load()
        #expect(entries.count == 4)
        #expect(entries.map(\.item.name) == ["item8", "item7", "item6", "item5"])
        // Trimming replaces the file rather than appending to it, so the
        // permissions have to survive.
        var file = stat()
        #expect(stat(store.path, &file) == 0)
        #expect(file.st_mode & 0o777 == 0o600)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8).hasSuffix("\n"))
    }

    @Test("A trim leaves no temporary file behind")
    func trimLeavesNoLitter() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory, maximumEntries: 2)
        for offset in 0..<5 {
            try store.append(try entry("brew:item\(offset)", at: Self.moment.addingTimeInterval(Double(offset))))
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        #expect(contents == ["history.jsonl"])
    }

    @Test("A command with several steps still occupies one line")
    func multiStepCommandsStayOnOneLine() async throws {
        // JSON escapes line breaks, so a two-step command stays one line.
        let line = try HistoryStore.line(for: try entry(command: "/opt/homebrew/bin/brew update\n/opt/homebrew/bin/brew upgrade git"))
        #expect(line.filter { $0 == 0x0A }.count == 1)
        #expect(String(decoding: line, as: UTF8.self).contains("\\n"))
    }

    @Test("Timestamps are written as readable ISO-8601")
    func timestampsAreReadable() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry())
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\"timestamp\":\"2023-11-14T22:13:20.250Z\""))
    }

    @Test("Lines an earlier MacUp wrote still decode, with nothing invented for what they lack")
    func earlierLinesStillDecode() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Fixture.data("history/before-read-back.jsonl").write(to: store.fileURL)

        let reading = try store.read()
        #expect(reading.unreadableLines == 0)
        #expect(reading.entries.count == 5)
        #expect(reading.entries.allSatisfy { $0.stateAfter == nil })

        let mysql = try #require(reading.entries.first)
        #expect(mysql.item.rawValue == "brew:mysql")
        #expect(mysql.outcome == .cancelled)
        #expect(mysql.versionBefore == "9.7.1")
        #expect(mysql.versionTarget == "26.7.0_2")
        #expect(mysql.versionAfter == nil)
        #expect(mysql.verification == nil)
        #expect(mysql.errorSummary == "The command was cancelled.")
        #expect(mysql.durationSeconds == 94.8895890712738)

        // Appending an entry of today's shape beside them leaves them readable.
        try store.append(try entry(outcome: .failed, verification: .targetNotReached))
        #expect(try store.read().entries.count == 6)
        #expect(try store.read().unreadableLines == 0)
    }

    @Test("A filter is applied as the file is read, so a limit counts the entries that match")
    func filterAppliesBeforeTheLimit() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        for offset in 0..<3 {
            try store.append(try entry("brew:git", at: Self.moment.addingTimeInterval(Double(offset))))
        }
        // Everything written since is for other items: a skip for an
        // ignored item on every run adds up.
        for offset in 3..<40 {
            try store.append(try entry("brew:wget", at: Self.moment.addingTimeInterval(Double(offset)), outcome: .skipped))
        }

        let git = try PackageID(parsing: "brew:git")
        let entries = try store.load(limit: 2, filter: HistoryFilter(items: [git]))
        #expect(entries.map(\.item) == [git, git])
        #expect(entries.map(\.timestamp) == [Self.moment.addingTimeInterval(2), Self.moment.addingTimeInterval(1)])
        #expect(try store.load(limit: 2).allSatisfy { $0.item.rawValue == "brew:wget" }, "unfiltered, the newest win")
        #expect(try store.load(filter: HistoryFilter(search: "left alone")).count == 37)
    }

    @Test("What an attempt left is stored with it, and redacted like everything else")
    func stateAfterIsStoredAndRedacted() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        var written = try entry(outcome: .failed, verification: .targetNotReached)
        written.versionAfter = "2.50.0"
        written.stateAfter = "No version of git is linked, so its commands are not on your PATH."
        try store.append(written)
        #expect(try store.load().first == written)

        var secret = written
        secret.stateAfter = "git left https://user:hunter2@example.com in its receipt."
        try store.append(secret)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("hunter2"))
        #expect(try store.load().first?.stateAfter?.contains(Redactor.placeholder) == true)
    }

    @Test("A history path that is not a regular file MacUp owns is refused")
    func refusesAnythingButARegularFile() async throws {
        let directory = try TemporaryDirectory(prefix: "macup-history")
        let store = store(directory)
        try store.append(try entry())
        // The test cannot chown without privileges, so this checks the cheaper
        // half of the same rule: the path has to be a regular file.
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)

        let failure = #expect(throws: MacUpError.self) { try store.load() }
        #expect(failure?.kind == .configurationInvalid)
    }
}
