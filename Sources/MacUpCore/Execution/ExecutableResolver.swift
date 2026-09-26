import Darwin
import Foundation

/// Where an executable was found.
public enum ExecutableSource: String, Sendable, Hashable, Codable {
    /// An explicit path from MacUp's configuration.
    case configured
    /// The user's search path (for the CLI, the shell `PATH` it was started with).
    case searchPath
    /// A well-known install location for the tool.
    case standardLocation
}

/// An executable MacUp has decided to use, recorded exactly.
public struct ResolvedExecutable: Sendable, Hashable, Codable {
    /// The path MacUp launches (may be a symlink).
    public var path: String
    /// The same path with every symlink resolved.
    public var canonicalPath: String
    public var source: ExecutableSource

    public init(path: String, canonicalPath: String, source: ExecutableSource) {
        self.path = path
        self.canonicalPath = canonicalPath
        self.source = source
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var directory: String { (path as NSString).deletingLastPathComponent }
    public var canonicalDirectory: String { (canonicalPath as NSString).deletingLastPathComponent }
}

/// Inputs for resolving one tool.
public struct ExecutableSearch: Sendable, Hashable {
    /// The executable's file name, for example `brew`.
    public var name: String
    /// An explicit path from configuration. When set, nothing else is tried.
    public var configuredPath: String?
    /// The user's search path, highest priority first.
    public var searchPath: [String]
    /// Absolute paths where the tool is commonly installed.
    public var standardLocations: [String]
    /// Searched last: the process `PATH` when it differs from the user's
    /// (for example a GUI app launched by Finder).
    public var fallbackSearchPath: [String]

    public init(
        name: String,
        configuredPath: String? = nil,
        searchPath: [String],
        standardLocations: [String] = [],
        fallbackSearchPath: [String] = []
    ) {
        self.name = name
        self.configuredPath = configuredPath
        self.searchPath = searchPath
        self.standardLocations = standardLocations
        self.fallbackSearchPath = fallbackSearchPath
    }
}

public enum ExecutableResolution: Sendable, Hashable {
    case found(ResolvedExecutable)
    case notFound(searched: [String])
    /// A configured path exists in configuration but cannot be used. MacUp does
    /// not fall back to another copy of the tool: that could run a binary the
    /// user did not choose.
    case invalidConfiguredPath(path: String, reason: String)
    /// The tool exists only in a standard location that someone other than the
    /// user or root could modify. MacUp does not run it implicitly.
    case untrustedLocation(path: String, reason: String)
}

/// Resolves provider executables intentionally (ARCHITECTURE.md, "Binary resolution"):
///
/// 1. the configured explicit path, if any — and only that path;
/// 2. the user's search path;
/// 3. standard install locations, but only when the file and every directory
///    above it belong to root or the user and nobody else can write them
///    (group write is tolerated only for wheel and admin);
/// 4. the fallback search path.
///
/// Relative search-path entries were already removed by ``SearchPath``.
public struct ExecutableResolver: Sendable {
    public var fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    public func resolve(_ search: ExecutableSearch) -> ExecutableResolution {
        guard Self.isValidName(search.name) else { return .notFound(searched: []) }

        // Checked exactly as configured (no trimming), with the validator's
        // rules, so a value the validator rejects is never launched.
        if let configured = search.configuredPath {
            return resolveConfigured(configured, name: search.name)
        }

        var untrusted: (path: String, reason: String)?
        for candidate in orderedCandidates(for: search) {
            guard let resolved = executable(at: candidate.path, source: candidate.source) else { continue }
            if candidate.source == .standardLocation, let reason = untrustedReason(resolved) {
                if untrusted == nil { untrusted = (resolved.path, reason) }
                continue
            }
            return .found(resolved)
        }
        if let untrusted { return .untrustedLocation(path: untrusted.path, reason: untrusted.reason) }
        return .notFound(searched: search.searchPath + search.standardLocations.map(Self.parentDirectory)
            + search.fallbackSearchPath)
    }

    /// Every distinct installation of the tool that resolution could find,
    /// in priority order, de-duplicated by canonical path.
    public func installations(_ search: ExecutableSearch) -> [ResolvedExecutable] {
        guard Self.isValidName(search.name) else { return [] }
        var seen = Set<String>()
        var result: [ResolvedExecutable] = []
        for candidate in orderedCandidates(for: search) {
            guard let resolved = executable(at: candidate.path, source: candidate.source),
                  seen.insert(resolved.canonicalPath).inserted
            else { continue }
            result.append(resolved)
        }
        return result
    }

    private func resolveConfigured(_ path: String, name: String) -> ExecutableResolution {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: TerminalText.isUnsafe) else {
            return .invalidConfiguredPath(path: path, reason: "The configured path must be absolute.")
        }
        guard (path as NSString).lastPathComponent == name else {
            return .invalidConfiguredPath(path: path, reason: "The configured path must point to an executable named '\(name)'.")
        }
        guard let resolved = executable(at: path, source: .configured) else {
            return .invalidConfiguredPath(path: path, reason: "No executable file exists at the configured path.")
        }
        return .found(resolved)
    }

    private func orderedCandidates(for search: ExecutableSearch) -> [(path: String, source: ExecutableSource)] {
        var candidates: [(String, ExecutableSource)] = []
        candidates += search.searchPath.map { ("\($0)/\(search.name)", .searchPath) }
        candidates += search.standardLocations
            .filter { $0.hasPrefix("/") && ($0 as NSString).lastPathComponent == search.name }
            .map { ($0, .standardLocation) }
        candidates += search.fallbackSearchPath.map { ("\($0)/\(search.name)", .searchPath) }
        return candidates
    }

    /// Why a standard-location executable may not be run implicitly, or `nil`
    /// when only root or the user can modify it and every directory above it.
    private func untrustedReason(_ executable: ResolvedExecutable) -> String? {
        var path = executable.canonicalPath
        while true {
            guard let ownership = fileSystem.ownership(ofPath: path) else {
                return "MacUp could not inspect \(path)."
            }
            if ownership.uid != 0 && ownership.uid != getuid() {
                return "\(path) belongs to another user."
            }
            let groupMayWrite = ownership.mode & S_IWGRP != 0 && ownership.gid != 0 && ownership.gid != Self.adminGroup
            if ownership.mode & S_IWOTH != 0 || groupMayWrite {
                return "\(path) is writable by other users."
            }
            if path == "/" { return nil }
            path = Self.parentDirectory(path)
            if path.isEmpty { return nil }
        }
    }

    /// macOS's `admin` group; its members can already become root.
    private static let adminGroup: gid_t = 80

    private func executable(at path: String, source: ExecutableSource) -> ResolvedExecutable? {
        guard fileSystem.isExecutableFile(atPath: path) else { return nil }
        let canonical = fileSystem.canonicalPath(ofPath: path) ?? path
        return ResolvedExecutable(path: path, canonicalPath: canonical, source: source)
    }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0") && name != "." && name != ".."
    }

    private static func parentDirectory(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}
