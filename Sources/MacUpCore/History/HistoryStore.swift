import Darwin
import Foundation

/// What one read of the history file found, including what it could not read.
public struct HistoryReading: Sendable, Hashable {
    /// Newest first, capped by the limit that was asked for.
    public var entries: [HistoryEntry]
    /// Lines MacUp could not decode. They are reported, never guessed at.
    public var unreadableLines: Int
    /// True when the file was longer than MacUp reads in one go, so the oldest
    /// entries were not looked at.
    public var olderEntriesNotRead: Bool

    public init(entries: [HistoryEntry], unreadableLines: Int = 0, olderEntriesNotRead: Bool = false) {
        self.entries = entries
        self.unreadableLines = unreadableLines
        self.olderEntriesNotRead = olderEntriesNotRead
    }

    /// What to tell the user about the parts of the file MacUp did not use.
    public var findings: [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        if unreadableLines > 0 {
            findings.append(DiagnosticFinding(
                id: "history.unreadableEntries",
                severity: .warning,
                provider: nil,
                title: unreadableLines == 1
                    ? "One history entry could not be read"
                    : "\(unreadableLines) history entries could not be read",
                detail: "MacUp skipped the lines it could not decode rather than guessing what they said.",
                recommendation: "The rest of the history is intact. Remove the file if you want to start a fresh log."
            ))
        }
        if olderEntriesNotRead {
            findings.append(DiagnosticFinding(
                id: "history.truncatedRead",
                severity: .info,
                provider: nil,
                title: "Only the most recent history was read",
                detail: "The history file is larger than MacUp reads at once, so the oldest entries were not included."
            ))
        }
        return findings
    }
}

/// MacUp's update history: one JSON object per line, newest appended last.
///
/// History is a trust feature (CLAUDE.md §16): it records what MacUp
/// attempted and what happened, including attempts that were skipped and
/// attempts that failed. Entries are written already redacted; a line that
/// cannot be decoded is reported, never guessed at.
///
/// The file is MacUp's own audit log, so it is held to the same rules as the
/// configuration file: the directory and the file belong to the user and to
/// nobody else, neither is written through a symlink, and both are created
/// owner-only.
public struct HistoryStore: Sendable {
    public var fileURL: URL
    /// Lines kept in the file. Older entries are dropped when it is trimmed.
    public static let maximumEntries = 5_000
    /// This store's own limit, so a test can prove trimming without writing
    /// five thousand lines.
    public var maximumEntries: Int
    /// How much of the file one read looks at. A full history is a few
    /// megabytes; anything beyond this is read from the end, because the
    /// recent entries are the ones anybody wants.
    public static let maximumReadBytes = 16 << 20
    /// A lower bound on the length of one encoded entry, used to skip counting
    /// lines in a file that is far too small to be over the limit. Every entry
    /// carries a schema version, a UUID, a timestamp, an origin, a package ID,
    /// and an outcome, so it is several times this.
    static let minimumEntryBytes = 32

    public init(fileURL: URL, maximumEntries: Int = HistoryStore.maximumEntries) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
    }

    public init(paths: MacUpPaths, maximumEntries: Int = HistoryStore.maximumEntries) {
        self.init(
            fileURL: URL(fileURLWithPath: paths.stateDirectory).appendingPathComponent("history.jsonl"),
            maximumEntries: maximumEntries
        )
    }

    public var path: String { fileURL.path }

    /// Appends one entry. Creates the file and its directory owner-only.
    public func append(_ entry: HistoryEntry) throws {
        let line = try Self.line(for: Self.redacting(entry))
        let directory = try openDirectory()
        try appendLine(line, in: directory)
        try trim(in: directory)
    }

    /// Reads history newest first. `limit` caps how many entries are returned.
    public func load(limit: Int? = nil) throws -> [HistoryEntry] {
        try read(limit: limit).entries
    }

    /// Reads history and says what it could not read, for `macup history` and
    /// for Doctor.
    public func read(limit: Int? = nil) throws -> HistoryReading {
        guard let (data, olderEntriesNotRead) = try contents() else {
            return HistoryReading(entries: [])
        }
        let decoder = Self.decoder()
        var entries: [HistoryEntry] = []
        var unreadable = 0
        // Decoding from the end means a limit stops work early on a long file.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if let limit, entries.count >= limit { break }
            do {
                entries.append(try decoder.decode(HistoryEntry.self, from: Data(line)))
            } catch {
                unreadable += 1
            }
        }
        return HistoryReading(
            entries: entries,
            unreadableLines: unreadable,
            olderEntriesNotRead: olderEntriesNotRead
        )
    }

    /// The newest entries for one item, for `macup explain` and the app's
    /// Copy Details.
    ///
    /// Decoding from the end means it stops as soon as it has `limit` of
    /// them. Lines it could not decode on the way are counted, because any
    /// of them may have been about this item.
    public func read(item: PackageID, limit: Int) throws -> HistoryReading {
        guard let (data, olderEntriesNotRead) = try contents() else {
            return HistoryReading(entries: [])
        }
        let decoder = Self.decoder()
        var entries: [HistoryEntry] = []
        var unreadable = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if entries.count >= limit { break }
            do {
                let entry = try decoder.decode(HistoryEntry.self, from: Data(line))
                if entry.item == item { entries.append(entry) }
            } catch {
                unreadable += 1
            }
        }
        return HistoryReading(
            entries: entries,
            unreadableLines: unreadable,
            olderEntriesNotRead: olderEntriesNotRead
        )
    }

    // MARK: Encoding

    /// One entry with every display string redacted.
    ///
    /// The engine redacts as it builds an entry; doing it again here means a
    /// caller that forgets cannot put a secret in MacUp's audit log.
    static func redacting(_ entry: HistoryEntry) -> HistoryEntry {
        let redactor = Redactor()
        var copy = entry
        copy.command = entry.command.map(redactor.redact)
        copy.errorSummary = entry.errorSummary.map(redactor.redact)
        copy.skipReason = entry.skipReason.map(redactor.redact)
        copy.versionBefore = entry.versionBefore.map(redactor.redact)
        copy.versionTarget = entry.versionTarget.map(redactor.redact)
        copy.versionAfter = entry.versionAfter.map(redactor.redact)
        return copy
    }

    /// The bytes of one line, newline included.
    static func line(for entry: HistoryEntry) throws -> Data {
        var data: Data
        do {
            data = try encoder().encode(entry)
        } catch {
            throw MacUpError(
                .configurationInvalid,
                "MacUp could not encode a history entry, so it recorded nothing for \(entry.item.rawValue)."
            )
        }
        // One entry per line is the whole format, so a newline inside the
        // encoded object would silently split it into two unreadable ones.
        guard !data.contains(0x0A) else {
            throw MacUpError(.configurationInvalid, "MacUp will not write a history entry containing a line break.")
        }
        data.append(0x0A)
        return data
    }

    /// Timestamps are written as ISO-8601 so the file reads as a log rather
    /// than as a column of epoch seconds.
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSecondTimestampStyle = Date.ISO8601FormatStyle()

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestampStyle.format(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = try? Date(text, strategy: timestampStyle) { return date }
            if let date = try? Date(text, strategy: wholeSecondTimestampStyle) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 timestamp.")
        }
        return decoder
    }

    // MARK: Files

    /// Opens the state directory, creating it and its parents owner-only, and
    /// refuses one that is a symlink or that other users could change.
    private func openDirectory() throws -> PrivateDirectory {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MacUpError(
                .configurationInvalid,
                "MacUp could not create \(directory.path), so it cannot record what it did.",
                detail: Redactor().redact(String(describing: error))
            )
        }
        return try PrivateDirectory(directory.path)
    }

    /// Appends to the file relative to the opened directory, following no
    /// symlink out of it, and never to anything but a regular file of ours.
    private func appendLine(_ line: Data, in directory: PrivateDirectory) throws {
        let name = fileURL.lastPathComponent
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.failure("\(directory.path) is no longer a directory MacUp can use.")
        }
        defer { close(descriptor) }
        let file = openat(descriptor, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            throw Self.failure(
                "MacUp could not open its history file: \(String(cString: strerror(errno))).",
                suggestion: "\(fileURL.path) may be a symlink. MacUp writes its history only to a regular file it owns."
            )
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw Self.failure("MacUp's history file is not a regular file it owns.")
        }
        // Keep it owner-only even if something loosened the permissions since.
        fchmod(file, 0o600)
        try Self.write(line, to: file, describing: fileURL.lastPathComponent)
        fsync(file)
    }

    /// The bytes of the history file, and whether older entries were skipped.
    /// `nil` when there is no history yet.
    private func contents() throws -> (data: Data, olderEntriesNotRead: Bool)? {
        let descriptor = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.failure(
                "MacUp could not read its history file: \(String(cString: strerror(errno))).",
                suggestion: "\(fileURL.path) may be a symlink. MacUp reads its history only from a regular file it owns."
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Self.failure("MacUp's history path is not a regular file.")
        }
        guard info.st_uid == getuid() else {
            throw Self.failure("MacUp's history file belongs to another user, so MacUp did not read it.")
        }

        let size = Int(info.st_size)
        var skipped = false
        if size > Self.maximumReadBytes {
            guard lseek(descriptor, off_t(size - Self.maximumReadBytes), SEEK_SET) >= 0 else {
                throw Self.failure("MacUp could not read the end of its history file.")
            }
            skipped = true
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < Self.maximumReadBytes {
            let wanted = min(buffer.count, Self.maximumReadBytes - data.count)
            let count = Darwin.read(descriptor, &buffer, wanted)
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.failure("MacUp could not read its history file: \(String(cString: strerror(errno))).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        // A read that started mid-file almost certainly started mid-line;
        // that line is dropped rather than decoded as if it were whole.
        if skipped, let newline = data.firstIndex(of: 0x0A) {
            data = data.suffix(from: data.index(after: newline))
        }
        return (data, skipped)
    }

    /// Drops the oldest entries once the file holds more than ``maximumEntries``.
    private func trim(in directory: PrivateDirectory) throws {
        guard maximumEntries > 0 else { return }
        // Counting lines means reading the whole file, so do not even open it
        // while it is far too small to be over the limit.
        var info = stat()
        guard stat(fileURL.path, &info) == 0,
              Int(info.st_size) > maximumEntries * Self.minimumEntryBytes,
              let (data, _) = try contents()
        else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > maximumEntries else { return }
        var kept = Data()
        for line in lines.suffix(maximumEntries) {
            kept.append(contentsOf: line)
            kept.append(0x0A)
        }
        try replace(kept, in: directory)
    }

    /// Replaces the file atomically: a crash part-way through a trim must not
    /// be able to lose the history it was keeping.
    private func replace(_ data: Data, in directory: PrivateDirectory) throws {
        let temporary = ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)"
        try directory.write(data, named: temporary)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            try? directory.remove(named: temporary)
            throw Self.failure("\(directory.path) is no longer a directory MacUp can use.")
        }
        defer { close(descriptor) }
        guard renameat(descriptor, temporary, descriptor, fileURL.lastPathComponent) == 0 else {
            let reason = String(cString: strerror(errno))
            try? directory.remove(named: temporary)
            throw Self.failure("MacUp could not trim its history file: \(reason).")
        }
        fsync(descriptor)
    }

    private static func write(_ data: Data, to descriptor: Int32, describing name: String) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw failure("MacUp could not write \(name): \(String(cString: strerror(errno))).")
                }
                offset += written
            }
        }
    }

    private static func failure(_ message: String, suggestion: String? = nil) -> MacUpError {
        MacUpError(.configurationInvalid, message, recoverySuggestion: suggestion)
    }
}
