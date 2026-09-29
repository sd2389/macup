/// Recognizes language runtimes and toolchains by name, across providers,
/// along with the package managers and databases whose updates need care.
///
/// Changing a runtime can change what other software sees (for example the
/// global npm packages available under a Node version), so runtime updates
/// carry the `runtimeOrToolchain` risk signal.
enum RuntimeCatalog {
    private static let schemes: [String: VersionScheme] = [
        "node": .standard, "nodejs": .standard, "deno": .standard, "bun": .standard,
        "python": .minorReleasesAreMajor, "pypy": .standard,
        "ruby": .minorReleasesAreMajor,
        "php": .minorReleasesAreMajor,
        "perl": .minorReleasesAreMajor,
        "lua": .minorReleasesAreMajor, "luajit": .standard,
        "go": .standard, "golang": .standard,
        "rust": .standard,
        "java": .standard, "openjdk": .standard, "temurin": .standard, "kotlin": .standard, "scala": .standard,
        "erlang": .standard, "elixir": .standard,
        "dotnet": .standard, "swift": .standard, "zig": .standard, "julia": .standard,
        "crystal": .standard, "dart": .standard, "flutter": .standard, "nim": .standard,
        "ghc": .minorReleasesAreMajor, "ocaml": .standard, "r": .standard,
        "llvm": .standard, "gcc": .standard,
    ]

    /// Package managers whose own updates deserve care.
    private static let packageManagers: Set<String> = ["npm", "corepack", "pnpm", "yarn", "mise"]

    /// Databases, whose data files a new major version may convert the first
    /// time it starts, with how each one numbers a major release.
    ///
    /// Deliberately short and explicit: a name belongs here only when its
    /// data outlives an upgrade and a new release series can change the
    /// format of that data. PostgreSQL has called only its first number the
    /// major version since 10 (16 → 17, not 16.4 → 16.5). The others count
    /// the second number too — MySQL 8.0 → 8.4, MariaDB 11.4 → 11.8, MongoDB
    /// 7.0 → 8.0, Redis 7.2 → 7.4 — because each of those can leave data an
    /// older release will not read.
    private static let databases: [String: VersionScheme] = [
        "mysql": .minorReleasesAreMajor, "mariadb": .minorReleasesAreMajor, "percona-server": .minorReleasesAreMajor,
        "postgresql": .standard,
        "mongodb-community": .minorReleasesAreMajor,
        "redis": .minorReleasesAreMajor, "valkey": .minorReleasesAreMajor,
    ]

    /// `node@20` → `node`, `core:python` → `python`, `aqua:nodejs/node` → `node`.
    static func baseName(_ name: String) -> String {
        var base = Substring(name.lowercased())
        if let colon = base.lastIndex(of: ":") { base = base[base.index(after: colon)...] }
        if let slash = base.lastIndex(of: "/") { base = base[base.index(after: slash)...] }
        if let at = base.firstIndex(of: "@"), at != base.startIndex { base = base[..<at] }
        return String(base)
    }

    static func isRuntime(_ name: String) -> Bool {
        schemes[baseName(name)] != nil
    }

    static func versionScheme(for name: String) -> VersionScheme {
        let base = baseName(name)
        return schemes[base] ?? databases[base] ?? .standard
    }

    static func isPackageManager(_ name: String) -> Bool {
        packageManagers.contains(baseName(name))
    }

    /// `mysql`, `postgresql@16`, `mongodb/brew/mongodb-community`.
    static func isDatabase(_ name: String) -> Bool {
        databases[baseName(name)] != nil
    }
}
