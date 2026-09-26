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
    /// File contents, or `nil` when unreadable or larger than `maximumBytes`.
    func contents(atPath path: String, maximumBytes: Int) -> Data?
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

    public func contents(atPath path: String, maximumBytes: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes
        else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}
