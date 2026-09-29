import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// History for one item: the Updates screen's Recent Attempts, the way from
/// there into History narrowed to that item, and History's search.
@Suite("History for one item, and searching it")
@MainActor
struct AppModelRecentAttemptsTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let wget = try! PackageID(parsing: "brew:wget")
    private static let mysql = try! PackageID(parsing: "brew:mysql")

    private func entry(
        _ item: PackageID,
        at seconds: TimeInterval,
        outcome: ExecutionResult.Outcome = .succeeded
    ) -> HistoryEntry {
        HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            origin: .gui,
            item: item,
            versionBefore: "1.0.0",
            versionTarget: "1.0.1",
            versionAfter: outcome == .succeeded ? "1.0.1" : nil,
            command: outcome == .skipped ? nil : "/opt/homebrew/bin/brew …",
            outcome: outcome,
            verification: outcome == .succeeded ? .verified : nil,
            skipReason: outcome == .skipped ? "\(item.name) is ignored (a rule you set for this item)." : nil
        )
    }

    private func record(_ entries: [HistoryEntry], in harness: AppModelHarness) throws {
        let store = HistoryStore(paths: harness.paths)
        for entry in entries { try store.append(entry) }
    }

    @Test("Recent attempts are the item's own newest few, however much else was written since")
    func recentAttemptsAreTheItemsOwn() throws {
        let harness = try AppModelHarness()
        try record((0..<4).map { entry(Self.git, at: Double($0)) }, in: harness)
        // A skip for an ignored item on every run adds up quickly.
        try record((4..<60).map { entry(Self.wget, at: Double($0), outcome: .skipped) }, in: harness)

        let attempts = harness.model.recentAttempts(for: Self.git)
        #expect(attempts.problem == nil)
        #expect(attempts.entries.map(\.item) == [Self.git, Self.git, Self.git])
        #expect(attempts.entries.map(\.timestamp) == [3.0, 2, 1].map { Date(timeIntervalSince1970: 1_700_000_000 + $0) })
        #expect(attempts.entries.first?.headline.text == "Upgraded and confirmed")
        #expect(harness.launchedExecutables.isEmpty, "reading history runs nothing")
    }

    @Test("An item MacUp never tried to change has no recent attempts, and that is not a problem")
    func noAttemptsYet() throws {
        let harness = try AppModelHarness()
        try record([entry(Self.wget, at: 0)], in: harness)

        let attempts = harness.model.recentAttempts(for: Self.git)
        #expect(attempts.entries.isEmpty)
        #expect(attempts.problem == nil)
        #expect(harness.model.recentAttempts(for: Self.git) == RecentAttempts(), "and with no file at all")
    }

    @Test("A history file MacUp will not read is a problem for the section, not an empty list")
    func unreadableHistoryIsAProblem() throws {
        let harness = try AppModelHarness()
        try FileManager.default.createDirectory(
            atPath: harness.paths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(
            atPath: harness.paths.historyFile,
            withDestinationPath: harness.home.canonicalPath + "/elsewhere.jsonl"
        )

        let attempts = harness.model.recentAttempts(for: Self.git)
        #expect(attempts.entries.isEmpty)
        #expect(attempts.problem?.contains("history") == true)
    }

    @Test("Show All in History opens History narrowed to the item, clearing an earlier search")
    func showHistoryForOneItem() throws {
        let harness = try AppModelHarness()
        try record([entry(Self.git, at: 0), entry(Self.wget, at: 1), entry(Self.git, at: 2, outcome: .failed)], in: harness)
        harness.model.historyFilter.search = "wget"

        harness.model.showHistory(for: Self.git)

        #expect(harness.model.section == .history)
        #expect(harness.model.historyFilter == HistoryFilter(items: [Self.git]))
        #expect(harness.model.history?.entries.map(\.item) == [Self.git, Self.git])
        #expect(harness.model.visibleHistory.map(\.outcome) == [.failed, .succeeded])
    }

    @Test("Show All History widens back to every item and keeps what was typed")
    func showAllHistoryAgain() throws {
        let harness = try AppModelHarness()
        try record([entry(Self.git, at: 0), entry(Self.wget, at: 1, outcome: .skipped)], in: harness)
        harness.model.showHistory(for: Self.git)
        harness.model.historyFilter.search = "left alone"

        harness.model.showAllHistory()

        #expect(harness.model.historyFilter.items.isEmpty)
        #expect(harness.model.historyFilter.search == "left alone")
        #expect(harness.model.history?.entries.count == 2)
        #expect(harness.model.visibleHistory.map(\.item) == [Self.wget])
    }

    @Test("History's search narrows by item, provider, or outcome, as it is typed")
    func searchNarrowsWhatIsShown() throws {
        let harness = try AppModelHarness()
        try record([
            entry(Self.git, at: 0),
            entry(Self.mysql, at: 1, outcome: .cancelled),
            entry(Self.wget, at: 2, outcome: .skipped),
        ], in: harness)
        harness.model.loadHistory()
        #expect(harness.model.visibleHistory.count == 3)

        harness.model.historyFilter.search = "stopped"
        #expect(harness.model.visibleHistory.map(\.item) == [Self.mysql])
        harness.model.historyFilter.search = "MYSQL"
        #expect(harness.model.visibleHistory.map(\.item) == [Self.mysql])
        harness.model.historyFilter.search = "homebrew"
        #expect(harness.model.visibleHistory.count == 3)
        harness.model.historyFilter.search = "confirmed"
        #expect(harness.model.visibleHistory.map(\.item) == [Self.git])
        harness.model.historyFilter.search = "nothing like this"
        #expect(harness.model.visibleHistory.isEmpty)
        #expect(harness.model.history?.entries.count == 3, "searching hides entries; it never drops what was read")

        harness.model.historyFilter.search = ""
        #expect(harness.model.visibleHistory.count == 3)
    }

    @Test("A failed run through the app shows up in the item's recent attempts, with what it left")
    func aFailedRunIsARecentAttempt() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        try harness.rule(.auto, for: Self.git)
        harness.allowUpdate(of: "git", .exit(1, standardError: "Error: git could not be linked."))
        harness.planning?.verifies(.targetNotReached, observed: "1.0.0")
        await harness.reviewEverything()
        await harness.applyAndWait()

        let attempt = try #require(harness.model.recentAttempts(for: Self.git).entries.first)
        #expect(attempt.outcome == .failed)
        #expect(attempt.versionAfter == "1.0.0")
        #expect(attempt.headline.text == "Failed — git was not upgraded")
        #expect(attempt.versionSummary == "1.0.0 → 1.0.1 · now 1.0.0")
        #expect(attempt.circumstances.prefix(2) == ["via Homebrew", "started from the MacUp app"])
    }

    @Test("An entry an earlier MacUp wrote is shown with one headline, and nothing guessed about afterwards")
    func anEarlierEntryIsShownWithoutGuessing() throws {
        let harness = try AppModelHarness()
        try FileManager.default.createDirectory(
            atPath: harness.paths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A stopped upgrade as MacUp recorded it before it read items back
        // after an unsuccessful attempt, anonymized.
        let line = #"{"command":"/Users/example/.homebrew/bin/brew upgrade --formula --yes mysql","durationSeconds":94.8895890712738,"errorSummary":"The command was cancelled.","id":"8E144797-A201-47E8-A709-B3B4615804FC","item":"brew:mysql","origin":"gui","outcome":"cancelled","schemaVersion":1,"timestamp":"2026-09-29T14:41:43.831Z","versionBefore":"9.7.1","versionTarget":"26.7.0_2"}"#
        try Data((line + "\n").utf8).write(to: URL(fileURLWithPath: harness.paths.historyFile))

        harness.model.showHistory(for: Self.mysql)
        let entry = try #require(harness.model.visibleHistory.first)
        #expect(harness.model.history?.unreadableLines == 0)
        #expect(entry.headline.text == "Stopped before the upgrade finished")
        #expect(entry.headline.symbolName == "stop.circle")
        #expect(entry.versionSummary == "9.7.1 → 26.7.0_2")
        #expect(entry.stateAfter == nil)
        #expect(entry.circumstances == ["via Homebrew", "started from the MacUp app", "ran for 1 minute, 35 seconds"])
        #expect(harness.model.recentAttempts(for: Self.mysql).entries == [entry])
    }
}
