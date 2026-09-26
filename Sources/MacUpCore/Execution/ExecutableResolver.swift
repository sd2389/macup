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
}

/// Resolves provider executables intentionally (ARCHITECTURE.md, "Binary resolution"):
///
/// 1. the configured explicit path, if any — and only that path;
/// 2. the user's search path;
/// 3. standard install locations;
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

        if let configured = search.configuredPath?.trimmingCharacters(in: .whitespaces), !configured.isEmpty {
            return resolveConfigured(configured, name: search.name)
        }

        if let found = firstExecutable(in: orderedCandidates(for: search)) {
            return .found(found)
        }
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
        guard path.hasPrefix("/") else {
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

    private func firstExecutable(in candidates: [(path: String, source: ExecutableSource)]) -> ResolvedExecutable? {
        for candidate in candidates {
            if let resolved = executable(at: candidate.path, source: candidate.source) { return resolved }
        }
        return nil
    }

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
