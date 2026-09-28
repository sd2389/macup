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
            // A fresh Mac has no `~/.local/state`, so the first thing MacUp
            // writes there would otherwise fail with "no such file or
            // directory". Missing parents are created owner-only too: a
            // directory MacUp makes on the way is as private as the one it
            // was asked for.
            guard errno == ENOENT else {
                throw MacUpError(.configurationInvalid, "Could not create \(path): \(String(cString: strerror(errno))).")
            }
            try Self.createParents(of: path)
            if mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw MacUpError(.configurationInvalid, "Could not create \(path): \(String(cString: strerror(errno))).")
            }
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

    /// Creates the directories above `path`, each owner-only.
    ///
    /// Only missing components are created; anything already there is left
    /// exactly as the user has it, including its permissions. Whether the
    /// result is actually private is decided by the check in ``init``, not
    /// here, so a parent somebody else controls still stops MacUp.
    private static func createParents(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard parent.hasPrefix("/"), parent != "/", parent != path else { return }
        var built = ""
        for component in parent.split(separator: "/") {
            built += "/" + component
            if mkdir(built, 0o700) != 0 && errno != EEXIST {
                throw MacUpError(
                    .configurationInvalid,
                    "Could not create \(built): \(String(cString: strerror(errno)))."
                )
            }
        }
    }

    /// Removes `name` from the directory, following no symlink out of it.
    /// Returns whether a file was removed.
    @discardableResult
    public func remove(named name: String) throws -> Bool {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw MacUpError(.configurationInvalid, "Invalid file name.")
        }
        let directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw MacUpError(.configurationInvalid, "\(path) is no longer a directory MacUp can use.") }
        defer { close(directory) }
        if unlinkat(directory, name, 0) == 0 { return true }
        if errno == ENOENT { return false }
        throw MacUpError(.configurationInvalid, "Could not remove \(name): \(String(cString: strerror(errno))).")
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
