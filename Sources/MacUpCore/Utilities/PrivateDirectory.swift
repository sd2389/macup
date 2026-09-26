import Darwin
import Foundation

/// A directory only the current user controls, for files MacUp writes (debug
/// snapshots today; exported diagnostics later).
///
/// The directory is created owner-only when missing and refused when it is a
/// symlink, not a directory, owned by someone else, or writable by group or
/// others. Files are created owner-only relative to the opened directory and
/// never through a symlink, so nobody else can redirect or read them.
public struct PrivateDirectory: Sendable {
    public let path: String

    /// Opens (creating if needed) `path` as a private directory.
    public init(_ path: String) throws {
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            throw MacUpError(.configurationInvalid, "Could not create \(path): \(String(cString: strerror(errno))).")
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MacUpError(.configurationInvalid, "\(path) is not a directory MacUp can use (it may be a symlink).")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw MacUpError(.configurationInvalid, "\(path) belongs to another user or others can write to it; choose a private directory.")
        }
        self.path = path
    }

    /// Writes `data` to `name` inside the directory with owner-only permissions.
    /// Fails, without writing, if `name` is a symlink or the directory changed.
    public func write(_ data: Data, named name: String) throws {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw MacUpError(.configurationInvalid, "Invalid file name.")
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw MacUpError(.configurationInvalid, "\(path) is no longer a directory MacUp can use.") }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw MacUpError(.configurationInvalid, "\(path) is no longer private.")
        }
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else {
            throw MacUpError(.configurationInvalid, "Could not write \(name): \(String(cString: strerror(errno))).")
        }
        defer { close(file) }
        fchmod(file, 0o600)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MacUpError(.configurationInvalid, "Could not write \(name): \(String(cString: strerror(errno))).")
                }
                offset += written
            }
        }
    }
}
