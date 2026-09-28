import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup history")
struct HistoryCommandTests {
    private static let noon = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        _ id: String,
        at offset: TimeInterval,
        outcome: ExecutionResult.Outcome = .succeeded,
        verification: VerificationResult.Outcome? = .verified,
        before: String? = "1.0.0",
        after: String? = "1.1.0",
        origin: ExecutionOrigin = .cli,
        skipReason: String? = nil
    ) throws -> HistoryEntry {
        HistoryEntry(
            timestamp: Self.noon.addingTimeInterval(offset),
            origin: origin,
            item: try PackageID(parsing: id),
            versionBefore: before,
            versionTarget: after,
            versionAfter: outcome == .succeeded ? after : nil,
            command: "/opt/homebrew/bin/brew upgrade --formula --yes \(id)",
            outcome: outcome,
            verification: verification,
            skipReason: skipReason,
            durationSeconds: 3.5
        )
    }

    @Test("With no history, MacUp says so and where it would be written")
    func emptyHistory() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["history"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("No history yet."))
        #expect(run.standardOutput.contains("history.jsonl"))
        #expect(run.standardOutput.contains("MacUp has not changed anything on this Mac."))
    }

    @Test("History is newest first, with versions, outcome, verification and origin")
    func newestFirst() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        try harness.historyStore.append(entry("npm:@scope/name", at: 60, origin: .gui))

        let run = try await harness.run(["history"])
        #expect(run.exitCode == nil)
        let git = try #require(run.standardOutput.range(of: "brew:git"))
        let npm = try #require(run.standardOutput.range(of: "npm:@scope/name"))
        #expect(npm.lowerBound < git.lowerBound)
        #expect(run.standardOutput.contains("1.0.0 → 1.1.0"))
        #expect(run.standardOutput.contains("updated, confirmed"))
        #expect(run.standardOutput.contains("from the command line"))
        #expect(run.standardOutput.contains("from the app"))
        #expect(run.standardOutput.contains("2 entries shown."))
    }

    @Test("An attempt MacUp could not confirm does not read as done")
    func unverifiedAttempt() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0, verification: .targetNotReached))

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("updated, other version"))
    }

    @Test("A skipped attempt shows the reason MacUp left it alone")
    func skipReasonIsShown() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry(
            "brew:postgresql",
            at: 0,
            outcome: .skipped,
            verification: nil,
            skipReason: "postgresql is ignored (a rule you set for this item)."
        ))

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("left alone"))
        #expect(run.standardOutput.contains("Why: postgresql is ignored"))
    }

    @Test("A line MacUp cannot read is reported, not silently dropped")
    func unreadableLinesAreReported() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))
        let file = harness.stateDirectory.appending("history.jsonl")
        try (String(contentsOf: file, encoding: .utf8) + "{ not json at all\n").write(to: file, atomically: true, encoding: .utf8)

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("One history entry could not be read"))
        #expect(run.standardOutput.contains("1 entry shown."))
    }

    @Test("--limit caps what is shown and says there may be more")
    func limitCapsTheList() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        for index in 0..<5 {
            try harness.historyStore.append(entry("brew:git", at: Double(index) * 60))
        }

        let run = try await harness.run(["history", "--limit", "2"])
        #expect(run.standardOutput.contains("2 entries shown."))
        #expect(run.standardOutput.contains("macup history --limit 4"))
    }

    @Test("A limit below one is a usage error")
    func limitMustBePositive() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["history", "--limit", "0"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("--limit must be at least 1."))
    }

    @Test("--verbose shows the command MacUp ran and how long it took")
    func verboseShowsCommands() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "--verbose"])
        #expect(run.standardOutput.contains("Ran: /opt/homebrew/bin/brew upgrade --formula --yes brew:git"))
        #expect(run.standardOutput.contains("Took 3.5s"))
    }

    @Test("history --json decodes back into history entries, with its schema version")
    func jsonDecodes() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "history")
        #expect(object["unreadableLines"] as? Int == 0)

        let entries = try JSONDecoder.plan.decode(
            [HistoryEntry].self,
            from: try JSONSerialization.data(withJSONObject: try #require(object["entries"]))
        )
        #expect(entries.count == 1)
        #expect(entries[0].item.rawValue == "brew:git")
        #expect(entries[0].schemaVersion == HistoryEntry.schemaVersion)
    }

    @Test("An update MacUp just ran shows up in history")
    func recordsAnActualUpdate() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")
        _ = try await harness.run(["update", "brew:git", "--yes"])

        let run = try await harness.run(["history"])
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("2.43.0 → 2.44.0"))
        #expect(run.standardOutput.contains("updated, confirmed"))
    }

    @Test("History output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.historyStore.append(entry("brew:git", at: 0))

        let run = try await harness.run(["history", "--verbose"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }
}
