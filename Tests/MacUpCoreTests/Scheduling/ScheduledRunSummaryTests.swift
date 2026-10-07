import Foundation
import Testing

@testable import MacUpCore

@Suite("What a scheduled run did")
struct ScheduledRunSummaryTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        _ item: String,
        _ outcome: ExecutionResult.Outcome,
        origin: ExecutionOrigin = .scheduled,
        at offset: TimeInterval = 0
    ) throws -> HistoryEntry {
        HistoryEntry(
            timestamp: start.addingTimeInterval(offset),
            origin: origin,
            item: try PackageID(parsing: item),
            versionBefore: "1.0",
            versionTarget: "1.1",
            versionAfter: outcome == .succeeded ? "1.1" : nil,
            command: "brew upgrade",
            outcome: outcome,
            verification: outcome == .succeeded ? .verified : nil
        )
    }

    @Test("One run is every scheduled entry written around the newest one")
    func groupsOneRun() throws {
        let history = [
            try entry("brew:git", .succeeded, at: 0),
            try entry("npm:typescript", .succeeded, at: 40),
            try entry("brew:mysql", .failed, at: 80),
            try entry("brew:postgresql", .skipped, at: 90),
            // Yesterday's run, and something the person did themselves.
            try entry("brew:curl", .succeeded, at: -86_400),
            try entry("brew:wget", .succeeded, origin: .gui, at: 20),
        ]

        let summary = try #require(ScheduledRunSummary.latest(in: history))

        #expect(summary.updated.map(\.rawValue) == ["brew:git", "npm:typescript"])
        #expect(summary.failed.map(\.rawValue) == ["brew:mysql"])
        #expect(summary.waiting == 1)
        #expect(summary.finishedAt == start.addingTimeInterval(90))
    }

    @Test("A run the person has already been told about is not reported again")
    func onlyNewRuns() throws {
        let history = [try entry("brew:git", .succeeded)]
        #expect(ScheduledRunSummary.latest(in: history, after: start.addingTimeInterval(1)) == nil)
        #expect(ScheduledRunSummary.latest(in: history, after: start.addingTimeInterval(-1)) != nil)
    }

    @Test("A history with nothing scheduled in it reports nothing")
    func nothingScheduled() throws {
        #expect(ScheduledRunSummary.latest(in: [try entry("brew:git", .succeeded, origin: .cli)]) == nil)
        #expect(ScheduledRunSummary.latest(in: []) == nil)
    }

    @Test("What the notification says, for each shape of run")
    func notificationText() throws {
        let updated = ScheduledRunSummary(
            finishedAt: start,
            updated: [try PackageID(parsing: "brew:git")],
            failed: [],
            waiting: 0
        )
        #expect(updated.notification?.title == "MacUp updated 1 item")
        #expect(updated.notification?.body == "brew:git")

        let mixed = ScheduledRunSummary(
            finishedAt: start,
            updated: [try PackageID(parsing: "brew:git")],
            failed: [try PackageID(parsing: "brew:mysql")],
            waiting: 2
        )
        #expect(mixed.notification?.title == "MacUp updated 1 item, and 1 update failed")
        #expect(mixed.notification?.body.contains("Failed: brew:mysql.") == true)
        #expect(mixed.notification?.body.contains("2 updates need your word") == true)

        let waiting = ScheduledRunSummary(finishedAt: start, updated: [], failed: [], waiting: 3)
        #expect(waiting.notification?.title == "3 updates are waiting for you")

        let quiet = ScheduledRunSummary(finishedAt: start, updated: [], failed: [], waiting: 0)
        #expect(quiet.notification == nil, "a run with nothing to say interrupts nobody")
    }

    @Test("A long list of items is shortened rather than printed in full")
    func shortensLongLists() throws {
        let items = try ["brew:a", "brew:b", "brew:c", "brew:d", "brew:e"].map { try PackageID(parsing: $0) }
        let summary = ScheduledRunSummary(finishedAt: start, updated: items, failed: [], waiting: 0)
        #expect(summary.notification?.body == "brew:a, brew:b, brew:c, and 2 more")
    }
}
