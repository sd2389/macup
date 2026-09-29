import Foundation
import MacUpCore

/// The last few attempts at one item, or why they could not be read.
struct RecentAttempts: Hashable {
    var entries: [HistoryEntry] = []
    var problem: String?
}

/// History narrowed to what someone is looking at: one item, or the entries
/// that match what they typed. The same ``HistoryFilter`` that
/// `macup history <package-id> --search <text>` uses, so the two surfaces
/// cannot disagree about which entries a filter lets through.
extension AppModel {
    /// What the History screen lists: the entries read for its item, narrowed
    /// by the search text as it is typed. A search narrows what was already
    /// read rather than reading the file again on every keystroke.
    var visibleHistory: [HistoryEntry] {
        let search = HistoryFilter(search: historyFilter.search)
        return (history?.entries ?? []).filter(search.includes)
    }

    /// The newest attempts at one item, newest first, for the Updates screen.
    ///
    /// Read from the file for that item alone, so the entries every other
    /// item has written since — a skip for each ignored item, every run —
    /// cannot crowd them out. Reading never creates or changes the file.
    func recentAttempts(for item: PackageID, limit: Int = 3) -> RecentAttempts {
        guard let paths = try? resolvedPaths() else {
            return RecentAttempts(problem: "MacUp could not resolve where its files live, so it did not look for a history.")
        }
        do {
            let reading = try HistoryStore(paths: paths).read(limit: limit, filter: HistoryFilter(items: [item]))
            return RecentAttempts(entries: reading.entries)
        } catch let error as MacUpError {
            return RecentAttempts(problem: [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " "))
        } catch {
            return RecentAttempts(problem: "MacUp could not read its history.")
        }
    }

    /// Opens History showing only `item`, as "Show All in History" on the
    /// Updates screen does. Any search already typed is cleared, so the item
    /// asked for is not hidden behind an earlier one.
    func showHistory(for item: PackageID) {
        historyFilter = HistoryFilter(items: [item])
        section = .history
        loadHistory()
    }

    /// Widens History back to every item, keeping whatever search is typed.
    func showAllHistory() {
        historyFilter.items = []
        loadHistory()
    }
}
