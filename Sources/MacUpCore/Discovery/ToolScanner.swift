import Foundation

/// One tool the scan found, and exactly which copy of it.
public struct FoundTool: Sendable, Hashable, Identifiable {
    public var tool: KnownTool
    /// The copy MacUp would use, or `nil` for a tool that is only a shell
    /// function and has no executable.
    public var path: String?
    public var canonicalPath: String?
    public var source: ExecutableSource?
    /// What the tool printed when asked for its version, in one line.
    public var version: String?
    /// Other copies on this Mac, canonical paths, when there is more than one.
    public var otherPaths: [String]
    /// Why there is no version, or why MacUp would not run this copy.
    public var note: String?

    public init(
        tool: KnownTool,
        path: String? = nil,
        canonicalPath: String? = nil,
        source: ExecutableSource? = nil,
        version: String? = nil,
        otherPaths: [String] = [],
        note: String? = nil
    ) {
        self.tool = tool
        self.path = path
        self.canonicalPath = canonicalPath
        self.source = source
        self.version = version
        self.otherPaths = otherPaths
        self.note = note
    }

    public var id: String { tool.id }
    /// Whether a MacUp provider keeps this one up to date.
    public var isManaged: Bool { tool.managedBy != nil }
}

/// What the scan found: every package manager and version manager on this
/// Mac that MacUp can recognise, whether or not MacUp manages it.
public struct ToolScan: Sendable, Hashable {
    public var scannedAt: Date
    public var found: [FoundTool]
    /// Catalog entries this Mac does not have. Listed so the scan can say
    /// what it looked for, rather than only what it saw.
    public var absent: [KnownTool]

    public init(scannedAt: Date, found: [FoundTool], absent: [KnownTool]) {
        self.scannedAt = scannedAt
        self.found = found
        self.absent = absent
    }

    /// The ones a MacUp provider manages.
    public var managed: [FoundTool] { found.filter(\.isManaged) }
    /// The ones MacUp found and does not manage. MacUp proposes no update
    /// for these and runs nothing of theirs.
    public var unmanaged: [FoundTool] { found.filter { !$0.isManaged } }
}

/// Looks for every tool in ``KnownTool/catalog`` on this Mac (CLAUDE.md §0:
/// one place to understand your environment).
///
/// Strictly read-only, in two ways. Each tool is found by resolving its
/// executable through ``ExecutableResolver``, which refuses a standard
/// location somebody other than you or root can write; a copy it refuses is
/// reported, never run. The only command the scan can issue is a tool's fixed
/// version array, because its runner is a ``ReadOnlyCommandGuard`` built from
/// ``CommandAllowlist/toolScan``.
///
/// Finding a tool says nothing about managing it. MacUp proposes updates only
/// for the four providers it implements; everything else is information.
public struct ToolScanner: Sendable {
    public var catalog: [KnownTool]
    /// How long one version command may take before it is given up on.
    public var timeout: Duration

    public init(catalog: [KnownTool] = KnownTool.catalog, timeout: Duration = .seconds(20)) {
        self.catalog = catalog
        self.timeout = timeout
    }

    public func scan(environment: CheckEnvironment) async -> ToolScan {
        let home = PathDisplay.standardized(environment.homeDirectory)
        let searchPath = SearchPath.parse(environment.processEnvironment["PATH"])
        let runner = ReadOnlyCommandGuard(base: environment.runner, rules: CommandAllowlist.toolScan)
        let resolver = ExecutableResolver(fileSystem: environment.fileSystem)

        let results = await withTaskGroup(of: (Int, FoundTool?).self) { group in
            for (index, tool) in catalog.enumerated() {
                group.addTask {
                    (index, await look(
                        for: tool,
                        resolver: resolver,
                        runner: runner,
                        fileSystem: environment.fileSystem,
                        processEnvironment: environment.processEnvironment,
                        searchPath: searchPath,
                        homeDirectory: home
                    ))
                }
            }
            var results: [(Int, FoundTool?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }

        return ToolScan(
            scannedAt: environment.now(),
            found: results.compactMap(\.1),
            absent: results.filter { $0.1 == nil }.map { catalog[$0.0] }
        )
    }

    // MARK: One tool

    private func look(
        for tool: KnownTool,
        resolver: ExecutableResolver,
        runner: any CommandRunning,
        fileSystem: any FileSystem,
        processEnvironment: [String: String],
        searchPath: [String],
        homeDirectory: String
    ) async -> FoundTool? {
        let locations = tool.paths(tool.standardLocations, homeDirectory: homeDirectory)
        let search = ExecutableSearch(name: tool.executable, searchPath: searchPath, standardLocations: locations)
        switch resolver.resolve(search) {
        case .found(let executable):
            let others = resolver.installations(search)
                .map(\.canonicalPath)
                .filter { $0 != executable.canonicalPath }
            var found = FoundTool(
                tool: tool,
                path: executable.path,
                canonicalPath: executable.canonicalPath,
                source: executable.source,
                otherPaths: others
            )
            if tool.versionArguments.isEmpty {
                found.note = "MacUp does not ask \(tool.displayName) for its version."
            } else {
                let read = await version(
                    of: tool,
                    at: executable,
                    runner: runner,
                    processEnvironment: processEnvironment,
                    searchPath: searchPath,
                    homeDirectory: homeDirectory
                )
                found.version = read.version
                found.note = read.note
            }
            return found
        case .untrustedLocation(let path, let reason):
            // Reported, not run: the same rule a provider follows.
            return FoundTool(
                tool: tool,
                path: path,
                note: "MacUp will not run this copy, so it has no version. " + reason
            )
        case .invalidConfiguredPath(let path, let reason):
            return FoundTool(tool: tool, path: path, note: reason)
        case .notFound:
            return marker(for: tool, fileSystem: fileSystem, homeDirectory: homeDirectory)
        }
    }

    /// A tool that is only a shell function, found by the file its installer
    /// leaves behind. There is nothing to run, so there is no version.
    private func marker(for tool: KnownTool, fileSystem: any FileSystem, homeDirectory: String) -> FoundTool? {
        let markers = tool.paths(tool.markers, homeDirectory: homeDirectory)
        guard let marker = markers.first(where: { fileSystem.fileExists(atPath: $0) }) else { return nil }
        return FoundTool(
            tool: tool,
            path: marker,
            note: "Installed as a shell function, so there is no command for MacUp to read a version from."
        )
    }

    /// What one version command printed, or why there is nothing to show.
    private func version(
        of tool: KnownTool,
        at executable: ResolvedExecutable,
        runner: any CommandRunning,
        processEnvironment: [String: String],
        searchPath: [String],
        homeDirectory: String
    ) async -> (version: String?, note: String?) {
        let request = CommandRequest(
            executable: executable.url,
            arguments: tool.versionArguments,
            environment: EnvironmentPolicy.base.environment(
                from: processEnvironment,
                searchPath: SearchPath.combine([executable.directory], searchPath, SearchPath.system)
            ),
            workingDirectory: URL(fileURLWithPath: homeDirectory, isDirectory: true),
            timeout: timeout,
            effect: .readOnly
        )
        let result: CommandResult
        do {
            result = try await runner.run(request)
        } catch {
            let message = MacUpError.wrapping(error, context: "Reading the \(tool.displayName) version").message
            return (nil, "MacUp could not read the version: \(TerminalText.sanitize(message))")
        }
        guard result.succeeded else {
            return (nil, "`\(tool.executable) \(tool.versionArguments.joined(separator: " "))` failed, so MacUp has no version for it.")
        }
        let home = homeDirectory
        guard let line = Self.versionLine(result.standardOutputText, homeDirectory: home)
            ?? Self.versionLine(result.standardErrorText, homeDirectory: home)
        else {
            return (nil, "\(tool.displayName) printed no version MacUp could read.")
        }
        return (line, nil)
    }

    /// The first non-empty line of what a tool printed, made safe to show and
    /// kept short: version output is untrusted input like any other
    /// (CLAUDE.md §26.7). Several tools print their install path along with
    /// the version, so the home directory is abbreviated to `~` here rather
    /// than carried into the output, the JSON, or an exported diagnostic
    /// (CLAUDE.md §18).
    static func versionLine(_ output: String, homeDirectory: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        let safe = PathDisplay.abbreviatingHome(in: TerminalText.sanitize(line), homeDirectory: homeDirectory)
        return safe.count <= 100 ? safe : String(safe.prefix(99)) + "…"
    }
}
