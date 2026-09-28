import Foundation

/// Globally installed npm packages (CLAUDE.md §9). Global scope only; MacUp
/// never scans projects.
///
/// npm is a Node script (`#!/usr/bin/env node`), so which `node` runs it
/// depends on PATH. MacUp chooses deliberately: a `node` next to npm (or next
/// to npm's symlink target) first, then the user's search path. The chosen
/// node, npm's global prefix, and its global root are recorded, because global
/// packages belong to one Node installation.
///
/// Read-only commands: `npm --version`, `node --version`, `npm prefix -g`,
/// `npm root -g`, `npm ls -g --json --depth=0`, `npm outdated -g --json`.
public struct NpmProvider: UpdateProvider {
    public let id = ProviderID.npm
    public let capabilities: Set<ProviderCapability> = [
        .detect, .inventory, .outdated, .planUpdates, .updateSelectedItems, .verifyUpdates,
    ]
    public var standardLocations: [String]

    public init(standardLocations: [String] = ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"]) {
        self.standardLocations = standardLocations
    }

    static let basePolicy = EnvironmentPolicy.base.adding(
        names: ["NODE_EXTRA_CA_CERTS", "PREFIX"],
        caseInsensitivePrefixes: ["npm_config_"],
        overrides: [
            "npm_config_update_notifier": "false",
            "npm_config_fund": "false",
            "npm_config_audit": "false",
        ]
    )

    static let installHint = "Install Node.js (which includes npm), or set providers.npm.executablePath in MacUp's configuration."

    enum FactKey {
        static let nodePath = "nodePath"
        static let nodeTarget = "nodeTarget"
        static let nodeVersion = "nodeVersion"
        static let nodeManager = "nodeManager"
        static let globalPrefix = "globalPrefix"
        static let globalRoot = "globalRoot"
    }

    // MARK: Detection

    public func detect(context: ProviderContext) async -> ProviderStatus {
        let resolution = context.resolver.resolve(ExecutableSearch(
            name: "npm",
            configuredPath: context.settings.executablePath,
            searchPath: context.searchPath,
            standardLocations: standardLocations
        ))
        if let status = ProviderSupport.status(for: resolution, provider: id, installHint: Self.installHint) {
            return status
        }
        guard case .found(let npm) = resolution else { return ProviderStatus(provider: id, availability: .unavailable) }

        guard let node = resolveNode(for: npm, context: context) else {
            return ProviderStatus(
                provider: id,
                availability: .failed,
                error: MacUpError(
                    .providerUnavailable,
                    "npm was found at \(npm.path), but no node executable was found to run it.",
                    recoverySuggestion: "Make sure node is installed next to npm or on your PATH."
                )
            )
        }

        let probe = ProviderInstallation(
            executable: npm,
            version: nil,
            facts: [ProviderFact(key: FactKey.nodePath, label: "Node", value: node.path)]
        )
        async let npmVersion = try? run(["--version"], probe, context: context, timeout: .seconds(60))
        async let nodeVersion = try? runNode(node, context: context)
        async let prefix = try? run(["prefix", "-g"], probe, context: context, timeout: .seconds(60))
        async let root = try? run(["root", "-g"], probe, context: context, timeout: .seconds(60))
        let results = await (npmVersion, nodeVersion, prefix, root)

        guard let versionResult = results.0, versionResult.succeeded else {
            return ProviderStatus(
                provider: id,
                availability: .failed,
                error: results.0.map { MacUpError.commandFailed($0, "npm was found but `npm --version` failed.") }
                    ?? MacUpError(.commandFailed, "npm was found but could not be run.", command: npm.path)
            )
        }

        var findings: [DiagnosticFinding] = []
        let home = context.homeDirectory
        let manager = NodeManager.classify(
            path: node.path,
            canonicalPath: node.canonicalPath,
            homeDirectory: home,
            miseDataDirectory: NodeManager.miseDataDirectory(environment: context.environment, homeDirectory: home)
        )
        var facts = [ProviderFact(key: FactKey.nodePath, label: "Node", value: node.path)]
        if node.canonicalPath != node.path {
            facts.append(ProviderFact(key: FactKey.nodeTarget, label: "Node resolves to", value: node.canonicalPath))
        }
        if let result = results.1, result.succeeded, let version = ProviderSupport.firstLine(result.standardOutputText) {
            facts.append(ProviderFact(key: FactKey.nodeVersion, label: "Node version", value: version))
        }
        facts.append(ProviderFact(key: FactKey.nodeManager, label: "Node managed by", value: manager.displayName))
        if let result = results.2, result.succeeded, let value = ProviderSupport.firstLine(result.standardOutputText), value.hasPrefix("/") {
            facts.append(ProviderFact(key: FactKey.globalPrefix, label: "Global prefix", value: value))
        }
        if let result = results.3, result.succeeded, let value = ProviderSupport.firstLine(result.standardOutputText), value.hasPrefix("/") {
            facts.append(ProviderFact(key: FactKey.globalRoot, label: "Global packages", value: value))
            if !context.fileSystem.isDirectory(atPath: value) {
                findings.append(DiagnosticFinding(
                    id: "npm.globalRootMissing",
                    severity: .info,
                    provider: id,
                    title: "npm's global package directory does not exist",
                    detail: "\(value) does not exist, so no global packages are installed for this npm.",
                    recommendation: "If you expected global packages here, check which node and npm come first on your PATH."
                ))
            }
        } else {
            findings.append(DiagnosticFinding(
                id: "npm.globalRootUnknown",
                severity: .warning,
                provider: id,
                title: "npm did not report its global package directory",
                detail: "MacUp cannot confirm that listed packages belong to this npm."
            ))
        }

        let nearNpm = [npm.directory, npm.canonicalDirectory]
        if !nearNpm.contains(node.directory) {
            findings.append(DiagnosticFinding(
                id: "npm.nodeNotNextToNpm",
                severity: .warning,
                provider: id,
                title: "npm runs with a node from elsewhere on PATH",
                detail: "npm is at \(npm.path) but the node that runs it is \(node.path).",
                recommendation: "Global packages depend on this pairing; mismatched node and npm installations are a common source of confusion."
            ))
        }

        return ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(
                executable: npm,
                version: ProviderSupport.firstLine(versionResult.standardOutputText),
                facts: facts
            ),
            findings: findings
        )
    }

    // MARK: Listing

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        let installation = try await requireInstallation(context)
        if globalRootIsMissing(installation, context: context) { return ProviderListing() }
        let result = try await run(["outdated", "-g", "--json"], installation, context: context, timeout: .seconds(180))
        return try NpmParsers.parseOutdated(result, context: parserContext(installation, command: result.invocation.displayString))
    }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        let installation = try await requireInstallation(context)
        if globalRootIsMissing(installation, context: context) { return ProviderListing() }
        let result = try await run(["ls", "-g", "--json", "--depth=0"], installation, context: context, timeout: .seconds(120))
        return try NpmParsers.parseInventory(result, context: parserContext(installation, command: result.invocation.displayString))
    }

    // MARK: Helpers

    /// A missing global root means there are no global packages; npm itself
    /// would fail with ENOENT, so MacUp does not ask it.
    private func globalRootIsMissing(_ installation: ProviderInstallation, context: ProviderContext) -> Bool {
        guard let root = installation.fact(FactKey.globalRoot) else { return false }
        return !context.fileSystem.isDirectory(atPath: root)
    }

    private func parserContext(_ installation: ProviderInstallation, command: String) -> NpmParsers.Context {
        let manager = NodeManager.allCases.first { $0.displayName == installation.fact(FactKey.nodeManager) } ?? .unknown
        var links = [OwnershipLink(label: "npm \(installation.version ?? "")".trimmingCharacters(in: .whitespaces), path: installation.executable.path)]
        if let nodePath = installation.fact(FactKey.nodePath) {
            links.append(OwnershipLink(label: "Node \(installation.fact(FactKey.nodeVersion) ?? "")".trimmingCharacters(in: .whitespaces), path: nodePath))
        }
        links.append(OwnershipLink(label: manager == .unknown ? "unrecognized Node installation" : manager.displayName))
        return NpmParsers.Context(
            globalRoot: installation.fact(FactKey.globalRoot),
            ownership: OwnershipChain(links),
            nodeManager: manager,
            command: command
        )
    }

    /// node next to npm, next to npm's symlink target, then on the search path.
    private func resolveNode(for npm: ResolvedExecutable, context: ProviderContext) -> ResolvedExecutable? {
        let resolution = context.resolver.resolve(ExecutableSearch(
            name: "node",
            searchPath: SearchPath.combine([npm.directory, npm.canonicalDirectory], context.searchPath)
        ))
        if case .found(let node) = resolution { return node }
        return nil
    }

    func childSearchPath(_ installation: ProviderInstallation, context: ProviderContext) -> [String] {
        let nodeDirectory = installation.fact(FactKey.nodePath).map { ($0 as NSString).deletingLastPathComponent }
        return SearchPath.combine(
            [nodeDirectory, installation.executable.directory, installation.executable.canonicalDirectory].compactMap { $0 },
            context.searchPath,
            SearchPath.system
        )
    }

    /// The base policy plus any variables the user's npmrc files reference as
    /// `${NAME}` — npm fails to start if such a variable is missing.
    func environmentPolicy(_ installation: ProviderInstallation, context: ProviderContext) -> EnvironmentPolicy {
        var files = [context.environment["npm_config_userconfig"] ?? context.environment["NPM_CONFIG_USERCONFIG"] ?? context.homeDirectory + "/.npmrc"]
        if let nodePath = installation.fact(FactKey.nodePath) {
            let canonicalNode = context.fileSystem.canonicalPath(ofPath: nodePath) ?? nodePath
            let nodePrefix = ((canonicalNode as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            files.append(nodePrefix + "/etc/npmrc")
        }
        let names = files.reduce(into: Set<String>()) { names, file in
            guard let data = context.fileSystem.contents(atPath: file, maximumBytes: 256 * 1024) else { return }
            names.formUnion(Self.referencedVariables(in: String(decoding: data, as: UTF8.self)))
        }
        return Self.basePolicy.adding(names: names.filter { !Self.altersExecution($0) })
    }

    /// Variables an npmrc reference must never pull into npm's environment,
    /// because they change what code runs (docs/COMMAND_EXECUTION.md).
    static func altersExecution(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["NODE_OPTIONS", "NODE_PATH", "BASH_ENV", "ENV", "RUBYOPT", "PERL5OPT", "PYTHONPATH", "PYTHONSTARTUP"].contains(upper)
            || upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_")
    }

    /// Names referenced as `${NAME}` or `${NAME?}` in npmrc text.
    static func referencedVariables(in npmrc: String) -> Set<String> {
        var names = Set<String>()
        var remainder = Substring(npmrc)
        while let start = remainder.range(of: "${") {
            remainder = remainder[start.upperBound...]
            guard let end = remainder.firstIndex(of: "}") else { break }
            var name = remainder[..<end]
            if name.hasSuffix("?") { name = name.dropLast() }
            if let first = name.first, first == "_" || first.isLetter,
               name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) {
                names.insert(String(name))
            }
            remainder = remainder[remainder.index(after: end)...]
        }
        return names
    }

    func run(
        _ arguments: [String],
        _ installation: ProviderInstallation,
        context: ProviderContext,
        timeout: Duration
    ) async throws -> CommandResult {
        try await ProviderSupport.run(
            installation.executable.path,
            arguments,
            policy: environmentPolicy(installation, context: context),
            searchPath: childSearchPath(installation, context: context),
            context: context,
            timeout: timeout
        )
    }

    private func runNode(_ node: ResolvedExecutable, context: ProviderContext) async throws -> CommandResult {
        try await ProviderSupport.run(
            node.path,
            ["--version"],
            policy: EnvironmentPolicy.base,
            searchPath: SearchPath.combine([node.directory], SearchPath.system),
            context: context,
            timeout: .seconds(30)
        )
    }
}
