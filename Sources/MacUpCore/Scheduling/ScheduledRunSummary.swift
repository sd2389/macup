import Foundation

/// What a scheduled run did, in one sentence, for a notification and for the
/// app to show when it opens.
///
/// Built from the history MacUp already writes — nothing new is recorded for
/// it — so what a notification says and what History shows cannot disagree.
public struct ScheduledRunSummary: Sendable, Hashable, Codable {
    /// When the newest scheduled entry was written.
    public var finishedAt: Date
    public var updated: [PackageID]
    public var failed: [PackageID]
    /// Items the run was not allowed to touch and left for the person: the
    /// Ask First ones, and anything it refused because it may need a
    /// password or a restart.
    public var waiting: Int

    public init(finishedAt: Date, updated: [PackageID], failed: [PackageID], waiting: Int) {
        self.finishedAt = finishedAt
        self.updated = updated
        self.failed = failed
        self.waiting = waiting
    }

    /// What the notification says, or `nil` when a run did nothing worth
    /// interrupting anyone about.
    public var notification: (title: String, body: String)? {
        if updated.isEmpty, failed.isEmpty, waiting == 0 { return nil }
        let title: String
        if !failed.isEmpty {
            title = updated.isEmpty
                ? "MacUp could not finish \(TextCount.plural(failed.count, "update"))"
                : "MacUp updated \(TextCount.plural(updated.count, "item")), and \(TextCount.plural(failed.count, "update")) failed"
        } else if !updated.isEmpty {
            title = "MacUp updated \(TextCount.plural(updated.count, "item"))"
        } else {
            title = "\(TextCount.plural(waiting, "update")) \(waiting == 1 ? "is" : "are") waiting for you"
        }

        var parts: [String] = []
        if !updated.isEmpty { parts.append(names(updated)) }
        if !failed.isEmpty { parts.append("Failed: " + names(failed) + ".") }
        if waiting > 0 {
            parts.append("\(TextCount.plural(waiting, "update")) \(waiting == 1 ? "needs" : "need") your word, so "
                + "the schedule left " + (waiting == 1 ? "it" : "them") + " alone.")
        }
        return (title, parts.joined(separator: " "))
    }

    private func names(_ items: [PackageID]) -> String {
        let shown = items.prefix(3).map { TerminalText.sanitize($0.rawValue) }.joined(separator: ", ")
        return items.count > 3 ? shown + ", and \(items.count - 3) more" : shown
    }

    /// The newest scheduled run in `history`, or `nil` when nothing was run
    /// on a schedule since `after`.
    ///
    /// History is one entry per item, so the run is everything scheduled
    /// written within `window` of the newest scheduled entry: a run that
    /// takes a few minutes is still one run.
    public static func latest(
        in history: [HistoryEntry],
        after: Date? = nil,
        window: TimeInterval = 30 * 60
    ) -> ScheduledRunSummary? {
        let scheduled = history.filter { $0.origin == .scheduled }
        guard let newest = scheduled.map(\.timestamp).max(), after.map({ newest > $0 }) ?? true else { return nil }
        let run = scheduled.filter { newest.timeIntervalSince($0.timestamp) <= window }
        return ScheduledRunSummary(
            finishedAt: newest,
            updated: run.filter { $0.outcome == .succeeded }.compactMap(\.item),
            failed: run.filter { $0.outcome == .failed }.compactMap(\.item),
            waiting: run.filter { $0.outcome == .skipped }.count
        )
    }
}
