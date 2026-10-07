import Foundation
import MacUpCore
import Observation
import UserNotifications

/// How the app tells someone what happened while they were away. Behind a
/// protocol so no test asks macOS for permission or posts anything.
@MainActor
protocol ScheduledRunNotifying: Sendable {
    /// Whether notifications may be posted. Asks macOS once; a refusal is
    /// final and is not asked again.
    func authorize() async -> Bool
    func post(title: String, body: String) async
}

/// macOS Notification Center, which only a bundled app can use. The `macup`
/// command posts nothing: a scheduled run writes history, and the app says
/// what happened the next time it is open.
@MainActor
struct SystemNotifier: ScheduledRunNotifying {
    func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
        @unknown default: return false
        }
    }

    func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// What the app knows about the last scheduled run, and whether it has
/// already told the person about it.
@MainActor
@Observable
final class ScheduledRunModel {
    /// The newest scheduled run found in History.
    fileprivate(set) var summary: ScheduledRunSummary?
    /// The run the person has already been told about, so reopening the app
    /// does not notify again. Kept per-Mac in the app's own preferences.
    var lastNotified: Date? {
        get { UserDefaults.standard.object(forKey: Self.key) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    static let key = "dev.macup.lastNotifiedScheduledRun"
}

extension AppModel {
    /// What the last scheduled run did, once ``reportScheduledRun()`` has
    /// looked. `nil` when nothing has run on a schedule.
    var scheduledRun: ScheduledRunSummary? { scheduledRuns.summary }

    /// Reads History for a scheduled run the person has not been told about,
    /// and notifies them once.
    ///
    /// Reading only: the run itself already happened, wrote its history, and
    /// exited. This is the app noticing, which is why a notification can
    /// arrive long after the run — a Mac that was asleep, or an app that was
    /// closed, does not lose the news.
    func reportScheduledRun() async {
        guard let paths = try? resolvedPaths() else { return }
        let entries = (try? HistoryStore(paths: paths).load(limit: 200)) ?? []
        guard let summary = ScheduledRunSummary.latest(in: entries) else { return }
        scheduledRuns.summary = summary

        guard summary.finishedAt > (scheduledRuns.lastNotified ?? .distantPast),
              let (title, body) = summary.notification
        else { return }
        // Asked for only when there is something to say, so someone who never
        // schedules anything is never asked at all.
        guard await environment.notifier.authorize() else {
            scheduledRuns.lastNotified = summary.finishedAt
            return
        }
        await environment.notifier.post(title: title, body: body)
        scheduledRuns.lastNotified = summary.finishedAt
    }
}
