import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// What the app says about a run that happened while it was closed.
@MainActor
final class FakeNotifier: ScheduledRunNotifying, @unchecked Sendable {
    var authorized = true
    private(set) var posted: [(title: String, body: String)] = []
    private(set) var authorizeCalls = 0

    func authorize() async -> Bool {
        authorizeCalls += 1
        return authorized
    }

    func post(title: String, body: String) async {
        posted.append((title, body))
    }
}

@MainActor
@Suite("App: what a scheduled run did")
struct AppModelScheduledRunTests {
    private func harness(notifier: FakeNotifier) throws -> AppModelHarness {
        try AppModelHarness(notifier: notifier)
    }

    private func entry(_ item: String, _ outcome: ExecutionResult.Outcome, at date: Date) throws -> HistoryEntry {
        HistoryEntry(
            timestamp: date,
            origin: .scheduled,
            item: try PackageID(parsing: item),
            versionBefore: "1.0",
            versionTarget: "1.1",
            versionAfter: outcome == .succeeded ? "1.1" : nil,
            command: "brew upgrade",
            outcome: outcome,
            verification: outcome == .succeeded ? .verified : nil
        )
    }

    @Test("A run the app has not seen is read from History and notified once")
    func notifiesOnce() async throws {
        let notifier = FakeNotifier()
        let harness = try harness(notifier: notifier)
        UserDefaults.standard.removeObject(forKey: ScheduledRunModel.key)
        let store = HistoryStore(paths: try harness.model.resolvedPaths())
        let now = Date()
        try store.append(try entry("brew:git", .succeeded, at: now))
        try store.append(try entry("brew:mysql", .skipped, at: now.addingTimeInterval(1)))

        await harness.model.reportScheduledRun()

        let summary = try #require(harness.model.scheduledRun)
        #expect(summary.updated.map(\.rawValue) == ["brew:git"])
        #expect(summary.waiting == 1)
        #expect(notifier.posted.count == 1)
        #expect(notifier.posted[0].title == "MacUp updated 1 item")

        // Opening the app again says nothing new.
        await harness.model.reportScheduledRun()
        #expect(notifier.posted.count == 1)
        UserDefaults.standard.removeObject(forKey: ScheduledRunModel.key)
    }

    @Test("Nothing scheduled means nothing is posted, and macOS is never asked for permission")
    func quietWhenNothingRan() async throws {
        let notifier = FakeNotifier()
        let harness = try harness(notifier: notifier)
        UserDefaults.standard.removeObject(forKey: ScheduledRunModel.key)

        await harness.model.reportScheduledRun()

        #expect(harness.model.scheduledRun == nil)
        #expect(notifier.posted.isEmpty)
        #expect(notifier.authorizeCalls == 0, "someone who never schedules anything is never asked")
    }

    @Test("A refusal to show notifications is taken once and not asked again")
    func refusedNotifications() async throws {
        let notifier = FakeNotifier()
        notifier.authorized = false
        let harness = try harness(notifier: notifier)
        UserDefaults.standard.removeObject(forKey: ScheduledRunModel.key)
        let store = HistoryStore(paths: try harness.model.resolvedPaths())
        try store.append(try entry("brew:git", .succeeded, at: Date()))

        await harness.model.reportScheduledRun()
        await harness.model.reportScheduledRun()

        #expect(notifier.posted.isEmpty)
        #expect(notifier.authorizeCalls == 1)
        #expect(harness.model.scheduledRun != nil, "the app still says what happened on screen")
        UserDefaults.standard.removeObject(forKey: ScheduledRunModel.key)
    }
}
