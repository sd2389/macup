import Foundation

/// Homebrew formulae and casks (CLAUDE.md §9).
///
/// Read-only commands:
/// - `brew --version`, `brew --prefix` (detection)
/// - `brew outdated --json=v2` (candidates, from local metadata)
/// - `brew info --json=v2 --installed` (inventory)
/// - `brew services list --json` (which formulae run as services, with the inventory)
/// - `brew update` only for `macup check --refresh`
/// - `brew uses --installed --formula|--cask <formula>` only when someone asks
///   what depends on one formula, never during a check
///
/// Every invocation sets `HOMEBREW_NO_AUTO_UPDATE=1`: `brew outdated` is one
/// of the commands Homebrew auto-updates before, and a normal check must not
/// update Homebrew. MacUp never runs `brew upgrade` blanket-style, never runs
/// `brew cleanup`, and never unpins anything.
public struct HomebrewProvider: UpdateProvider {
    public let id = ProviderID.homebrew
    public let capabilities: Set<ProviderCapability> = [
        .detect, .inventory, .outdated, .refreshMetadata, .planUpdates, .updateSelectedItems, .verifyUpdates,
        .listDependents,
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
        // Asked alongside `brew info`, not after it: the two are independent,
        // and a check should not wait for one to start the other.
        async let services = readServices(installation, context: context)
        let result = try await run(["info", "--json=v2", "--installed"], installation, context: context)
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew info` failed.")
        }
        var listing = try HomebrewInventoryParser.parse(
            result.standardOutput,
            ownership: ownership(installation),
            command: result.invocation.displayString
        )
        if let prefix = installation.fact("prefix") {
            listing.elements = Self.annotate(listing.elements, prefix: prefix, fileSystem: context.fileSystem)
        }
        let serviceState = Self.annotate(listing.elements, services: await services)
        listing.elements = serviceState.items
        listing.findings += serviceState.findings
        return listing
    }

    /// Adds what Homebrew's JSON leaves out, read from the files Homebrew
    /// itself keeps (reading only):
    ///
    /// - `optVersion`: the version `<prefix>/opt/<name>` points at, which is
    ///   what services and other formulae run, linked or not.
    /// - `incompleteVersions`: installed versions whose folder has no
    ///   `INSTALL_RECEIPT.json`. Homebrew writes the receipt when an install
    ///   finishes, so a folder without one is an install that was cut short.
    /// - `buildsFromSource`: the current version has no ready-made build that
    ///   pours into this prefix. A build made for a fixed cellar, such as
    ///   `/opt/homebrew/Cellar`, pours only there; `:any` pours anywhere.
    ///
    /// A formula whose folder MacUp cannot see gets no file-based facts at
    /// all, rather than being judged incomplete for want of a receipt.
    static func annotate(_ items: [ManagedItem], prefix: String, fileSystem: any FileSystem) -> [ManagedItem] {
        let cellar = prefix + "/Cellar"
        let canonicalCellar = fileSystem.canonicalPath(ofPath: cellar) ?? cellar
        return items.map { item in
            guard item.kind == .formula else { return item }
            var item = item
            if let cellars = item.details["bottleCellars"] {
                let pourable = cellars.split(separator: "\n").contains { entry in
                    entry == ":any" || entry == ":any_skip_relocation" || entry == cellar || entry == canonicalCellar
                }
                if !pourable { item.details["buildsFromSource"] = "true" }
            }
            let rackName = item.id.name.split(separator: "/").last.map(String.init) ?? item.id.name
            let rack = cellar + "/" + rackName
            guard fileSystem.isDirectory(atPath: rack) else { return item }
            let canonicalRack = fileSystem.canonicalPath(ofPath: rack) ?? rack
            if let target = fileSystem.canonicalPath(ofPath: prefix + "/opt/" + rackName),
               target.hasPrefix(canonicalRack + "/") {
                let version = String(target.dropFirst(canonicalRack.count + 1))
                if !version.isEmpty, !version.contains("/") { item.details["optVersion"] = version }
            }
            let incomplete = item.installedVersions.map(\.raw).filter {
                !fileSystem.fileExists(atPath: rack + "/" + $0 + "/INSTALL_RECEIPT.json")
            }
            if !incomplete.isEmpty { item.details["incompleteVersions"] = incomplete.joined(separator: ", ") }
            return item
        }
    }

    public func refine(_ candidates: [UpdateCandidate], using inventory: [ManagedItem]) -> [UpdateCandidate] {
        let items = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.map { candidate in
            guard let item = items[candidate.id] else { return Self.addingDataImpact(candidate) }
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
            if item.details["buildsFromSource"] == "true" {
                signals.insert(.buildsFromSource)
                notes.append(
                    "Homebrew has no ready-made build of this version for where your Homebrew is installed, so it will "
                        + "compile \(item.displayName) from source. That can take a long time, an hour or more for a large "
                        + "package, and it should be left to finish."
                )
            }
            let incomplete = item.details["incompleteVersions"]
            if let incomplete {
                signals.insert(.installationIncomplete)
                notes.append(
                    "An earlier install of \(item.displayName) \(incomplete) did not finish: Homebrew writes an install "
                        + "receipt when an install completes, and this one has none."
                )
                if item.activeVersion == nil, item.details["kegOnly"] != "true" {
                    notes.append("No version of \(item.displayName) is linked, so its commands are not on your PATH.")
                }
            }
            let service = Self.serviceImpact(of: item)
            signals.formUnion(service.signals)
            notes += service.notes
            var refined = candidate.adding(signals: signals, notes: notes)
            // Kept verbatim; ``UpdateCandidate/releaseInfoLink`` decides whether it is safe to offer.
            if let homepage = item.details["homepage"] { refined.details["homepage"] = homepage }
            if let incomplete { refined.details["incompleteVersions"] = incomplete }
            if item.details["buildsFromSource"] == "true" { refined.details["buildsFromSource"] = "true" }
            if let status = item.details["serviceStatus"], status != "none" { refined.details["serviceStatus"] = status }
            // The version in use, not merely the newest folder: after an
            // interrupted upgrade the newest folder can be an empty one.
            if let inUse = Self.versionInUse(item), inUse != refined.installedVersion?.raw {
                refined = refined.replacingInstalledVersion(
                    InstalledVersion(inUse),
                    scheme: RuntimeCatalog.versionScheme(for: item.displayName)
                )
            }
            return Self.addingDataImpact(refined)
        }
    }

    /// The version that is actually in use: the linked keg, then what the
    /// `opt` link points at, then the newest version whose install finished.
    /// `nil` when none of those is known, leaving Homebrew's own answer.
    static func versionInUse(_ item: ManagedItem) -> String? {
        if let active = item.activeVersion?.raw { return active }
        if let opt = item.details["optVersion"] { return opt }
        guard let incomplete = item.details["incompleteVersions"] else { return nil }
        let unfinished = Set(incomplete.components(separatedBy: ", "))
        let finished = item.installedVersions.map(\.raw).filter { !unfinished.contains($0) }
        return finished.isEmpty ? nil : HomebrewOutdatedParser.newest(finished)
    }

    private func ownership(_ installation: ProviderInstallation) -> OwnershipChain {
        let location = installation.fact("prefix") ?? installation.executable.directory
        return OwnershipChain([OwnershipLink(label: "Homebrew", path: location)])
    }
}
