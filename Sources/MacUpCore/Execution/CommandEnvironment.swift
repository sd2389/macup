/// Builds the complete environment for a child process from an allowlist.
///
/// MacUp never hands its whole environment to a provider. Each provider gets
/// the base allowlist plus the variables that provider documents, and fixed
/// overrides (for example `HOMEBREW_NO_AUTO_UPDATE=1`). Values are passed to
/// the child but never logged.
public struct EnvironmentPolicy: Sendable, Hashable {
    public var allowedNames: Set<String>
    /// Case-sensitive name prefixes, such as `HOMEBREW_`.
    public var allowedPrefixes: [String]
    /// Prefixes matched case-insensitively. npm reads `npm_config_*` in any case.
    public var caseInsensitivePrefixes: [String]
    /// Always set, replacing any inherited value.
    public var overrides: [String: String]

    public init(
        allowedNames: Set<String> = [],
        allowedPrefixes: [String] = [],
        caseInsensitivePrefixes: [String] = [],
        overrides: [String: String] = [:]
    ) {
        self.allowedNames = allowedNames
        self.allowedPrefixes = allowedPrefixes
        self.caseInsensitivePrefixes = caseInsensitivePrefixes
        self.overrides = overrides
    }

    /// Identity, locale, temporary directory, XDG base directories, and proxy
    /// settings. Terminal variables are excluded so providers produce plain output.
    public static let base = EnvironmentPolicy(
        allowedNames: [
            "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LC_COLLATE",
            "LC_NUMERIC", "LC_TIME", "LC_MONETARY", "__CF_USER_TEXT_ENCODING",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
            "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "no_proxy", "all_proxy",
        ],
        overrides: ["NO_COLOR": "1"]
    )

    public func adding(
        names: Set<String> = [],
        prefixes: [String] = [],
        caseInsensitivePrefixes: [String] = [],
        overrides: [String: String] = [:]
    ) -> EnvironmentPolicy {
        var copy = self
        copy.allowedNames.formUnion(names)
        copy.allowedPrefixes += prefixes
        copy.caseInsensitivePrefixes += caseInsensitivePrefixes
        copy.overrides.merge(overrides) { _, new in new }
        return copy
    }

    public func isAllowed(_ name: String) -> Bool {
        if name == "PATH" { return false }  // PATH is always constructed explicitly.
        if allowedNames.contains(name) { return true }
        if allowedPrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        let lowercased = name.lowercased()
        return caseInsensitivePrefixes.contains { lowercased.hasPrefix($0.lowercased()) }
    }

    /// The environment for a child process: allowed variables from `source`,
    /// `PATH` set to `searchPath`, then `overrides`.
    public func environment(from source: [String: String], searchPath: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in source where isAllowed(name) {
            guard !name.isEmpty, !name.contains("="), !name.contains("\0"), !value.contains("\0") else { continue }
            result[name] = value
        }
        result["PATH"] = searchPath.joined(separator: ":")
        for (name, value) in overrides {
            result[name] = value
        }
        return result
    }
}

/// Parsing and combining executable search paths.
public enum SearchPath {
    public static let system = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Absolute, deduplicated entries from a `PATH`-style string.
    ///
    /// Empty and relative entries (an empty entry or `.` means "the current
    /// directory") are dropped: resolving tools relative to wherever MacUp
    /// happens to run is a PATH-hijacking risk.
    public static func parse(_ value: String?) -> [String] {
        guard let value else { return [] }
        return combine(value.split(separator: ":", omittingEmptySubsequences: true).map(String.init))
    }

    /// Concatenates lists, keeping the first occurrence of each valid entry.
    public static func combine(_ lists: [String]...) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in lists.joined() {
            guard let normalized = normalize(entry), seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    static func normalize(_ entry: String) -> String? {
        guard entry.hasPrefix("/"), !entry.unicodeScalars.contains(where: TerminalText.isUnsafe) else { return nil }
        var entry = entry
        while entry.count > 1 && entry.hasSuffix("/") { entry.removeLast() }
        return entry
    }
}
