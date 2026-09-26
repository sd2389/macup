/// Recognizes language runtimes and toolchains by name, across providers.
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
        schemes[baseName(name)] ?? .standard
    }

    static func isPackageManager(_ name: String) -> Bool {
        packageManagers.contains(baseName(name))
    }
}
