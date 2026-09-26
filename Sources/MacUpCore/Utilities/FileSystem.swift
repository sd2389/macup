import Darwin
import Foundation

/// The file-system queries providers and executable resolution need.
/// Abstracted so tests can describe a machine without touching the real one.
public protocol FileSystem: Sendable {
    /// Whether anything exists at `path` (symlinks followed).
    func fileExists(atPath path: String) -> Bool
    /// Whether `path` is a directory (symlinks followed).
    func isDirectory(atPath path: String) -> Bool
    /// Whether `path` is a non-directory the current user may execute (symlinks followed).
    func isExecutableFile(atPath path: String) -> Bool
    /// `path` with every symlink resolved, or `nil` if it does not exist.
    func canonicalPath(ofPath path: String) -> String?
    /// File contents, or `nil` when unreadable, not a regular file, or larger than `maximumBytes`.
    func contents(atPath path: String, maximumBytes: Int) -> Data?
    /// Owner, group, and permission bits of `path` (symlinks followed), or `nil`.
    func ownership(ofPath path: String) -> FileOwnership?
}

/// Who owns a file and who may write it.
public struct FileOwnership: Sendable, Hashable {
    public var uid: uid_t
    public var gid: gid_t
    public var mode: mode_t

    public init(uid: uid_t, gid: gid_t, mode: mode_t) {
        self.uid = uid
        self.gid = gid
        self.mode = mode
    }
}

/// The real file system.
public struct LocalFileSystem: FileSystem {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func canonicalPath(ofPath path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Reads through one descriptor so the size limit bounds what is read;
    /// FIFOs and devices are refused rather than read (or blocked on).
    public func contents(atPath path: String, maximumBytes: Int) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maximumBytes else {
            return nil
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= maximumBytes {
            let count = read(descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data.count <= maximumBytes ? data : nil
    }

    public func ownership(ofPath path: String) -> FileOwnership? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileOwnership(uid: info.st_uid, gid: info.st_gid, mode: info.st_mode)
    }
}
