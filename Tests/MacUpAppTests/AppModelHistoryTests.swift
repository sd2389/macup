import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the History screen is given to show")
@MainActor
struct AppModelHistoryTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let wget = try! PackageID(parsing: "brew:wget")

    private func entry(
        _ item: PackageID,
        at seconds: TimeInterval,
        outcome: ExecutionResult.Outcome = .succeeded,
        verification: VerificationResult.Outcome? = .verified,
        skipReason: String? = nil
    ) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: seconds),
            origin: .gui,
            item: item,
            versionBefore: "1.0.0",
            versionTarget: "1.0.1",
            versionAfter: verification == .verified ? "1.0.1" : nil,
            command: "/opt/homebrew/bin/brew …",
            outcome: outcome,
            verification: verification,
            skipReason: skipReason,
            durationSeconds: 1.5
        )
    }

    @Test("With nothing recorded, the screen is given an empty reading rather than an error")
    func emptyHistory() throws {
        let harness = try AppModelHarness()
        harness.model.loadHistory()

        let reading = try #require(harness.model.history)
        #expect(reading.entries.isEmpty)
        #expect(reading.findings.isEmpty)
        #expect(harness.model.historyProblem == nil)
    }

    @Test("Entries come back newest first, with everything the row shows")
    func entriesAreNewestFirst() throws {
        let harness = try AppModelHarness()
        let store = HistoryStore(paths: harness.paths)
        try store.append(entry(Self.git, at: 1_700_000_000))
        try store.append(entry(Self.wget, at: 1_700_000_100))

        harness.model.loadHistory()
        let entries = try #require(harness.model.history?.entries)
        #expect(entries.map(\.item) == [Self.wget, Self.git])

        let newest = try #require(entries.first)
        #expect(newest.origin == .gui)
        #expect(newest.versionBefore == "1.0.0")
        #expect(newest.versionTarget == "1.0.1")
        #expect(newest.versionAfter == "1.0.1")
        #expect(newest.command != nil)
        #expect(newest.durationSeconds == 1.5)
        #expect(newest.verification == .verified)
    }

    @Test("An attempt MacUp decided not to make is kept, with its reason")
    func skipsAreKeptWithTheirReason() throws {
        let harness = try AppModelHarness()
        try HistoryStore(paths: harness.paths).append(entry(
            Self.git,
            at: 1_700_000_000,
            outcome: .skipped,
            verification: nil,
            skipReason: "git is ignored (a rule you set for this item)."
        ))

        harness.model.loadHistory()
        let entry = try #require(harness.model.history?.entries.first)
        #expect(entry.outcome == .skipped)
        #expect(entry.skipReason?.contains("is ignored") == true)
        #expect(OutcomeLabel.wording(entry.outcome, entry.verification).text == "Not changed")
    }

    @Test("A line MacUp could not decode is reported, not quietly dropped")
    func unreadableLinesAreSurfaced() throws {
        let harness = try AppModelHarness()
        let store = HistoryStore(paths: harness.paths)
        try store.append(entry(Self.git, at: 1_700_000_000))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: harness.paths.historyFile))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("this line is not a history entry\n".utf8))
        try handle.close()

        harness.model.loadHistory()
        let reading = try #require(harness.model.history)
        #expect(reading.entries.count == 1)
        #expect(reading.unreadableLines == 1)
        let finding = try #require(reading.findings.first)
        #expect(finding.id == "history.unreadableEntries")
        #expect(finding.severity == .warning)
    }

    @Test("A history file MacUp will not read is reported as a problem, not as an empty log")
    func anUnreadableFileIsAProblem() throws {
        let harness = try AppModelHarness()
        try FileManager.default.createDirectory(
            atPath: harness.paths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // MacUp reads its own history only from a regular file it owns, so a
        // symlink is refused rather than followed.
        try FileManager.default.createSymbolicLink(
            atPath: harness.paths.historyFile,
            withDestinationPath: harness.home.canonicalPath + "/elsewhere.jsonl"
        )

        harness.model.loadHistory()
        #expect(harness.model.history == nil)
        #expect(harness.model.historyProblem?.contains("history") == true)
    }

    @Test("A run through the app leaves history the screen can read straight away")
    func applyingLeavesReadableHistory() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        try harness.rule(.auto, for: Self.git)
        harness.allowUpdate(of: "git")
        await harness.reviewEverything()
        await harness.applyAndWait()

        let entries = try #require(harness.model.history?.entries)
        #expect(entries.count == 1)
        #expect(entries.first?.origin == .gui)
        #expect(entries.first?.item == Self.git)
    }
}
