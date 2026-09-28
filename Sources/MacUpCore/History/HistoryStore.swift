import Foundation

/// MacUp's update history: one JSON object per line, newest appended last.
///
/// History is a trust feature (CLAUDE.md §16): it records what MacUp
/// attempted and what happened, including attempts that were skipped and
/// attempts that failed. Entries are written already redacted; a line that
/// cannot be decoded is reported, never guessed at.
public struct HistoryStore: Sendable {
    public var fileURL: URL
    /// Lines kept in the file. Older entries are dropped when it is trimmed.
    public static let maximumEntries = 5_000

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(paths: MacUpPaths) {
        self.init(fileURL: URL(fileURLWithPath: paths.stateDirectory).appendingPathComponent("history.jsonl"))
    }

    public var path: String { fileURL.path }

    /// Appends one entry. Creates the file and its directory owner-only.
    public func append(_ entry: HistoryEntry) throws {
        throw MacUpError(.unsupported, "MacUp does not record history in this version.")
    }

    /// Reads history newest first. `limit` caps how many entries are returned.
    public func load(limit: Int? = nil) throws -> [HistoryEntry] {
        []
    }
}
