import Foundation
import MacUpCore

/// An in-memory file system describing a pretend Mac.
public final class FakeFileSystem: FileSystem, @unchecked Sendable {
    public enum Entry: Sendable {
        case file(executable: Bool, contents: Data)
        case directory
        case symlink(to: String)
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    @discardableResult
    public func addExecutable(_ path: String) -> Self {
        set(path, .file(executable: true, contents: Data()))
    }

    @discardableResult
    public func addFile(_ path: String, contents: String = "") -> Self {
        set(path, .file(executable: false, contents: Data(contents.utf8)))
    }

    @discardableResult
    public func addDirectory(_ path: String) -> Self {
        set(path, .directory)
    }

    /// Adds a symlink. Relative targets resolve against the link's directory.
    @discardableResult
    public func addSymlink(_ path: String, to target: String) -> Self {
        set(path, .symlink(to: target))
    }

    private func set(_ path: String, _ entry: Entry) -> Self {
        lock.withLock { entries[path] = entry }
        return self
    }

    private func resolvedEntry(_ path: String) -> (path: String, entry: Entry)? {
        lock.withLock {
            var current = path
            for _ in 0..<32 {
                guard let entry = entries[current] else { return nil }
                guard case .symlink(let target) = entry else { return (current, entry) }
                let base = (current as NSString).deletingLastPathComponent
                current = ((target.hasPrefix("/") ? target : base + "/" + target) as NSString).standardizingPath
            }
            return nil
        }
    }

    public func fileExists(atPath path: String) -> Bool {
        resolvedEntry(path) != nil
    }

    public func isDirectory(atPath path: String) -> Bool {
        if case .directory = resolvedEntry(path)?.entry { return true }
        return false
    }

    public func isExecutableFile(atPath path: String) -> Bool {
        if case .file(let executable, _) = resolvedEntry(path)?.entry { return executable }
        return false
    }

    public func canonicalPath(ofPath path: String) -> String? {
        resolvedEntry(path)?.path
    }

    public func contents(atPath path: String, maximumBytes: Int) -> Data? {
        guard case .file(_, let contents) = resolvedEntry(path)?.entry, contents.count <= maximumBytes else {
            return nil
        }
        return contents
    }
}
