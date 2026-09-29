import Foundation

/// Wording for history entries shared by `macup history`, `macup explain`,
/// and the app's Copy Details, so one attempt reads the same wherever it is
/// shown.
extension HistoryEntry {
    /// What happened, in the words MacUp is entitled to use. An update it
    /// could not confirm afterwards never reads as confirmed (CLAUDE.md §25).
    public var outcomeSummary: String {
        switch outcome {
        case .succeeded:
            switch verification {
            case .verified: "updated, confirmed"
            case .targetNotReached: "updated, other version"
            case .failed, .notPerformed, nil: "updated, not confirmed"
            }
        case .failed: "failed"
        case .timedOut: "timed out"
        case .cancelled: "cancelled"
        case .skipped: "left alone"
        }
    }

    /// "2026-09-29 10:41": to the minute, in the reader's time zone unless a
    /// test pins one. A fixed format, so it is not translated.
    public static func timestampText(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

extension ExecutionOrigin {
    /// Where an attempt came from: "from the command line", "from the app",
    /// or "on a schedule".
    public var historyPhrase: String {
        switch self {
        case .cli: "from the command line"
        case .gui: "from the app"
        case .scheduled: "on a schedule"
        }
    }
}
