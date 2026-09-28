import Foundation

/// Homebrew formulae and casks (CLAUDE.md §9).
///
/// Read-only commands:
/// - `brew --version`, `brew --prefix` (detection)
/// - `brew outdated --json=v2` (candidates, from local metadata)
/// - `brew info --json=v2 --installed` (inventory)
/// - `brew update` only for `macup check --refresh`
///
/// Every invocation sets `HOMEBREW_NO_AUTO_UPDATE=1`: `brew outdated` is one
/// of the commands Homebrew auto-updates before, and a normal check must not
/// update Homebrew. MacUp never runs `brew upgrade` blanket-style, never runs
/// `brew cleanup`, and never unpins anything.
public struct HomebrewProvider: UpdateProvider {
    public let id = ProviderID.homebrew
    public let capabilities: Set<ProviderCapability> = [
        .detect, .inventory, .outdated, .refreshMetadata, .planUpdates, .updateSelectedItems, .verifyUpdates,
    ]
    public var standardLocations: [String]

    public init(standardLocations: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
        self.standardLocations = standardLocations
    }

    static let environmentPolicy = EnvironmentPolicy.base.adding(
        names: ["SSH_AUTH_SOCK"],
        prefixes: ["HOMEBREW_"],
        overrides: [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
        ]
    )

    static let installHint = "Install Homebrew from https://brew.sh, or set providers.homebrew.executablePath in MacUp's configuration."

    private func search(_ context: ProviderContext, includeConfigured: Bool = true) -> ExecutableSearch {
        ExecutableSearch(
            name: "brew",
            configuredPath: includeConfigured ? context.settings.executablePath : nil,
            searchPath: context.searchPath,
            standardLocations: standardLocations
        )
    }

    func childSearchPath(_ executable: ResolvedExecutable) -> [String] {
        SearchPath.combine([executable.directory], SearchPath.system)
    }

    func run(
        _ arguments: [String],
        _ installation: ProviderInstallation,
        context: ProviderContext,
        effect: CommandEffect = .readOnly,
        timeout: Duration = .seconds(180)
    ) async throws -> CommandResult {
        try await ProviderSupport.run(
            installation.executable.path,
            arguments,
            effect: effect,
            policy: Self.environmentPolicy,
            searchPath: childSearchPath(installation.executable),
            context: context,
            timeout: timeout
        )
    }

    // MARK: Detection

    public func detect(context: ProviderContext) async -> ProviderStatus {
        let resolution = context.resolver.resolve(search(context))
        if let status = ProviderSupport.status(for: resolution, provider: id, installHint: Self.installHint) {
            return status
        }
        guard case .found(let executable) = resolution else { return ProviderStatus(provider: id, availability: .unavailable) }

        let probe = ProviderInstallation(executable: executable, version: nil)
        async let versionResult = try? run(["--version"], probe, context: context, timeout: .seconds(60))
        async let prefixResult = try? run(["--prefix"], probe, context: context, timeout: .seconds(60))
        let (version, prefix) = await (versionResult, prefixResult)

        guard let version, version.succeeded else {
            return ProviderStatus(
                provider: id,
                availability: .failed,
                error: version.map { MacUpError.commandFailed($0, "Homebrew was found but `brew --version` failed.") }
                    ?? MacUpError(.commandFailed, "Homebrew was found but could not be run.", command: executable.path)
            )
        }

        var facts: [ProviderFact] = []
        if let prefix, prefix.succeeded, let path = ProviderSupport.firstLine(prefix.standardOutputText), path.hasPrefix("/") {
            facts.append(ProviderFact(key: "prefix", label: "Prefix", value: path))
        }
        facts.append(ProviderFact(key: "autoUpdate", label: "Auto-update", value: "disabled for MacUp's commands (HOMEBREW_NO_AUTO_UPDATE=1)"))

        var findings: [DiagnosticFinding] = []
        let installations = context.resolver.installations(search(context, includeConfigured: false))
        if installations.count > 1 {
            findings.append(DiagnosticFinding(
                id: "homebrew.multipleInstallations",
                severity: .warning,
                provider: id,
                title: "More than one Homebrew installation was found",
                detail: "MacUp uses \(executable.path). Also found: "
                    + installations.filter { $0.canonicalPath != executable.canonicalPath }.map(\.path).joined(separator: ", ") + ".",
                recommendation: "On Apple Silicon, /usr/local is usually a leftover Intel (Rosetta) installation. Make sure the one you use comes first in PATH."
            ))
        }

        let versionLine = ProviderSupport.firstLine(version.standardOutputText) ?? ""
        let versionNumber = versionLine.hasPrefix("Homebrew ") ? String(versionLine.dropFirst("Homebrew ".count)) : nil
        return ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(executable: executable, version: versionNumber, facts: facts),
            findings: findings
        )
    }

    // MARK: Refresh

    public func refreshMetadata(context: ProviderContext) async throws -> [DiagnosticFinding] {
        let installation = try await requireInstallation(context)
        let result = try await run(["update"], installation, context: context, effect: .metadataRefresh, timeout: .seconds(600))
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew update` failed; results use the metadata Homebrew already had.")
        }
        return []
    }

    // MARK: Listing

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        let installation = try await requireInstallation(context)
        let result = try await run(["outdated", "--json=v2"], installation, context: context)
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew outdated` failed.")
        }
        return try HomebrewOutdatedParser.parse(
            result.standardOutput,
            ownership: ownership(installation),
            command: result.invocation.displayString
        )
    }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        let installation = try await requireInstallation(context)
        let result = try await run(["info", "--json=v2", "--installed"], installation, context: context)
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew info` failed.")
        }
        return try HomebrewInventoryParser.parse(
            result.standardOutput,
            ownership: ownership(installation),
            command: result.invocation.displayString
        )
    }

    public func refine(_ candidates: [UpdateCandidate], using inventory: [ManagedItem]) -> [UpdateCandidate] {
        let items = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.map { candidate in
            guard let item = items[candidate.id] else { return candidate }
            var signals: Set<RiskSignal> = []
            var notes: [String] = []
            if item.details["usesInstallerPackage"] == "true" {
                signals.insert(.administratorAuthorizationMayBeRequired)
                notes.append("This cask runs a macOS installer package, which usually asks for an administrator password.")
            }
            if item.details["installedOnRequest"] == "false" {
                signals.insert(.mayAffectDependents)
                notes.append("Installed as a dependency of other formulae.")
            }
            if item.details["deprecated"] == "true" {
                notes.append("Deprecated in Homebrew.")
            }
            if item.details["disabled"] == "true" {
                notes.append("Disabled in Homebrew.")
            }
            return candidate.adding(signals: signals, notes: notes)
        }
    }

    private func ownership(_ installation: ProviderInstallation) -> OwnershipChain {
        let location = installation.fact("prefix") ?? installation.executable.directory
        return OwnershipChain([OwnershipLink(label: "Homebrew", path: location)])
    }
}
