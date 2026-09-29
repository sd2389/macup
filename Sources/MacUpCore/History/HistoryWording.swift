import Foundation

/// Formatting for history entries shared by `macup history`, `macup explain`,
/// and the app's Copy Details. What an entry says happened is
/// ``HistoryHeadline``.
extension HistoryEntry {
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
