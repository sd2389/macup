import Darwin
import Foundation

/// Why an exported diagnostics file was not written. In every case nothing
/// is left behind: no file, and no partial one.
public struct DiagnosticsFileError: Error, Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        /// Something is already there. MacUp never replaces a file.
        case alreadyExists
        /// A symbolic link is there. MacUp never writes through one.
        case symbolicLink
        /// The folder the file would go in does not exist, or is not a folder.
        case noSuchFolder
        /// macOS would not let MacUp create a file in that folder.
        case notPermitted
        /// The path does not end in a file name.
        case invalidName
        /// Creating or writing the file failed part-way; what was written is removed.
        case failed
    }

    public var reason: Reason
    public var path: String
    /// What macOS said, when it said something worth repeating.
    public var detail: String?

    public init(_ reason: Reason, path: String, detail: String? = nil) {
        self.reason = reason
        self.path = path
        self.detail = detail
    }

    /// One sentence for a person, with the home folder written as `~`.
    public func message(homeDirectory: String) -> String {
        let shown = TerminalText.sanitize(PathDisplay.abbreviatingHome(path, homeDirectory: homeDirectory))
        let folder = TerminalText.sanitize(PathDisplay.abbreviatingHome(
            (path as NSString).deletingLastPathComponent,
            homeDirectory: homeDirectory
        ))
        let because = detail.map { " (\(TerminalText.sanitize($0)))" } ?? ""
        switch reason {
        case .alreadyExists:
            return "\(shown) already exists. MacUp never replaces a file, so nothing was written."
        case .symbolicLink:
            return "\(shown) is a symbolic link. MacUp does not write through links, so nothing was written."
        case .noSuchFolder:
            return "There is no folder at \(folder), so nothing was written."
        case .notPermitted:
            return "MacUp is not allowed to create a file in \(folder)\(because), so nothing was written."
        case .invalidName:
            return "\(shown) does not end in a file name, so nothing was written."
        case .failed:
            return "\(shown) could not be written\(because). Nothing was left behind."
        }
    }
}

/// Where an exported diagnostics file goes, and how it is written.
///
/// The file is new or it is nothing: MacUp creates it exclusively, so an
/// existing file is never replaced and a symbolic link at the destination —
/// even one pointing nowhere — is refused rather than followed. It is
/// created owner-only (`0600`), because until its owner decides otherwise
/// it describes their Mac to nobody else (CLAUDE.md §18, §19). The folders
/// above it are the user's choice and may themselves be links.
public enum DiagnosticsFile {
    /// `macup-diagnostics-2026-09-29-111500.json`: local time, to the second,
    /// so exports made a second apart never want the same name.
    public static func defaultName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "macup-diagnostics-\(formatter.string(from: date)).json"
    }

    /// Why writing to `path` would be refused, found without writing
    /// anything, or `nil` when it looks possible. Lets a caller say so before
    /// a slow gather rather than after it; ``write(_:toPath:)`` still makes
    /// the decision that counts, atomically.
    public static func problem(writingTo path: String) -> DiagnosticsFileError? {
        let path = PathDisplay.standardized(path)
        let name = (path as NSString).lastPathComponent
        guard isFileName(name) else { return DiagnosticsFileError(.invalidName, path: path) }
        var info = stat()
        if lstat(path, &info) == 0 {
            let isLink = (info.st_mode & S_IFMT) == S_IFLNK
            return DiagnosticsFileError(isLink ? .symbolicLink : .alreadyExists, path: path)
        }
        var folder = stat()
        guard stat(folderPath(of: path), &folder) == 0, (folder.st_mode & S_IFMT) == S_IFDIR else {
            return DiagnosticsFileError(.noSuchFolder, path: path)
        }
        return nil
    }

    /// Creates `path` and writes `data` to it, owner-only.
    ///
    /// Throws ``DiagnosticsFileError`` without writing anything when anything
    /// already exists at `path` — a file, a folder, or a link — or when the
    /// folder is missing or not MacUp's to write in.
    public static func write(_ data: Data, toPath path: String) throws {
        let path = PathDisplay.standardized(path)
        let name = (path as NSString).lastPathComponent
        guard isFileName(name) else { throw DiagnosticsFileError(.invalidName, path: path) }

        let folder = open(folderPath(of: path), O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard folder >= 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: throw DiagnosticsFileError(.noSuchFolder, path: path)
            case EACCES, EPERM: throw DiagnosticsFileError(.notPermitted, path: path, detail: reason(code))
            default: throw DiagnosticsFileError(.failed, path: path, detail: reason(code))
            }
        }
        defer { close(folder) }

        // O_EXCL refuses anything already there, a link included, whatever
        // it points at; O_NOFOLLOW says the same thing twice.
        let file = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            let code = errno
            switch code {
            case EEXIST, ELOOP:
                var info = stat()
                let isLink = fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
                throw DiagnosticsFileError(isLink ? .symbolicLink : .alreadyExists, path: path)
            case EACCES, EPERM, EROFS:
                throw DiagnosticsFileError(.notPermitted, path: path, detail: reason(code))
            default:
                throw DiagnosticsFileError(.failed, path: path, detail: reason(code))
            }
        }

        // The file is MacUp's own from here, so a failure removes it rather
        // than leave half a report behind.
        var failure: Int32 = 0
        // The mode passed to openat is narrowed by the umask; this is not.
        if fchmod(file, 0o600) != 0 { failure = errno }
        if failure == 0 {
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        failure = errno
                        return
                    }
                    offset += written
                }
            }
        }
        if failure == 0 && fsync(file) != 0 { failure = errno }
        close(file)
        if failure != 0 {
            unlinkat(folder, name, 0)
            throw DiagnosticsFileError(.failed, path: path, detail: reason(failure))
        }
    }

    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "/" && name != "." && name != ".."
    }

    private static func folderPath(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "." : folder
    }

    private static func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
