import Foundation

/// Which history entries to show: the ones for some items, and the ones that
/// match some search text.
///
/// `macup history <package-id>… --search <text>` and the History screen
/// narrow the list with this one type, so the two can never disagree about
/// which entries a filter lets through.
public struct HistoryFilter: Sendable, Hashable {
    /// Only entries for these items. Empty means every item.
    public var items: Set<PackageID>
    /// Only entries whose item, provider, or outcome contain every word of
    /// this, ignoring case. Blank means no search.
    public var search: String

    public init(items: Set<PackageID> = [], search: String = "") {
        self.items = items
        self.search = search
    }

    /// True when the filter lets every entry through.
    public var isEmpty: Bool { items.isEmpty && searchWords.isEmpty }

    public func includes(_ entry: HistoryEntry) -> Bool {
        (items.isEmpty || entry.item.map(items.contains) == true) && matchesSearch(entry)
    }

    /// Whether every word of ``search`` appears somewhere in what the entry is
    /// about: its package ID (which holds the name), its provider, and what
    /// happened — in the headline's words and as recorded, so "stopped" and
    /// "cancelled" both find a stopped attempt.
    public func matchesSearch(_ entry: HistoryEntry) -> Bool {
        let words = searchWords
        guard !words.isEmpty else { return true }
        var fields = [entry.subjectID, entry.headline.text, entry.outcome.rawValue]
        if let provider = entry.provider { fields += [provider.displayName, provider.rawValue] }
        if let record = entry.uninstall { fields += [record.name, "uninstall", "uninstalled", record.kind.displayName] }
        let text = fields.joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The search split into words, so "mysql stopped" finds the entries that
    /// mention both rather than the ones containing that exact phrase. Empty
    /// when there is no search.
    public var searchWords: [String] {
        search.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
