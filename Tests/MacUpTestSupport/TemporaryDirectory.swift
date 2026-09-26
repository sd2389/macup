import Foundation

/// A uniquely named directory under the system temporary directory,
/// removed when the value is deallocated.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    public init(prefix: String = "macup-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    public var path: String { url.path }

    /// The directory with symlinks resolved (`/var` → `/private/var`).
    /// Uses realpath(3): `URL.resolvingSymlinksInPath()` strips `/private`.
    public var canonicalPath: String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public func appending(_ component: String) -> URL {
        url.appendingPathComponent(component)
    }

    /// Writes an executable `/bin/sh` script. Test-only: MacUp itself never
    /// runs commands through a shell.
    @discardableResult
    public func makeScript(_ name: String, _ body: String) throws -> URL {
        let script = appending(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}
