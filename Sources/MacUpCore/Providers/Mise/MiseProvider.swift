import Foundation

/// Where the configuration that requests a mise tool lives.
public enum MiseConfigScope: String, Sendable, Hashable, Codable {
    /// mise's global configuration directory (`~/.config/mise/`).
    case global
    /// System-wide configuration (`/etc/mise/`).
    case system
    /// A config file directly in the home directory (for example `~/.tool-versions`).
    case home
    /// A project's configuration. Informational for global maintenance.
    case project
    case unknown
}

/// mise-managed runtimes and tools (CLAUDE.md §9).
///
/// Commands run with the home directory as the working directory, so a check
/// sees global and home-directory configuration rather than whatever project
/// the shell happens to be in. MacUp never passes `--bump` (which would move
/// the requested version) and never prunes.
///
/// Read-only commands: `mise --version`, `mise ls --json`, `mise outdated --json`.
public struct MiseProvider: UpdateProvider {
    public let id = ProviderID.mise
    public let capabilities: Set<ProviderCapability> = [
        .detect, .inventory, .outdated, .planUpdates, .verifyUpdates,
    ]
    /// Absolute paths; `~` is expanded against the user's home directory.
    public var standardLocations: [String]

    public init(standardLocations: [String] = ["~/.local/bin/mise", "/opt/homebrew/bin/mise", "/usr/local/bin/mise"]) {
        self.standardLocations = standardLocations
    }

    static let environmentPolicy = EnvironmentPolicy.base.adding(
        names: ["GITHUB_TOKEN", "GITHUB_API_TOKEN"],
        prefixes: ["MISE_"]
    )

    static let installHint = "Install mise from https://mise.jdx.dev, or set providers.mise.executablePath in MacUp's configuration."

    enum FactKey {
        static let configDirectory = "configDirectory"
        static let globalConfigFile = "globalConfigFile"
        static let dataDirectory = "dataDirectory"
        static let workingDirectory = "workingDirectory"
    }

    // MARK: Detection

    public func detect(context: ProviderContext) async -> ProviderStatus {
        let locations = standardLocations.map { $0.hasPrefix("~/") ? context.homeDirectory + $0.dropFirst() : $0 }
        let resolution = context.resolver.resolve(ExecutableSearch(
            name: "mise",
            configuredPath: context.settings.executablePath,
            searchPath: context.searchPath,
            standardLocations: locations
        ))
        if let status = ProviderSupport.status(for: resolution, provider: id, installHint: Self.installHint) {
            return status
        }
        guard case .found(let executable) = resolution else { return ProviderStatus(provider: id, availability: .unavailable) }

        let directories = Self.directories(environment: context.environment, homeDirectory: context.homeDirectory)
        let probe = ProviderInstallation(executable: executable, version: nil)
        let result: CommandResult
        do {
            result = try await run(["--version"], probe, context: context, timeout: .seconds(60))
        } catch {
            return ProviderStatus(provider: id, availability: .failed, error: MacUpError.wrapping(error, context: "Running `mise --version`"))
        }
        guard result.succeeded else {
            return ProviderStatus(
                provider: id,
                availability: .failed,
                error: MacUpError.commandFailed(result, "mise was found but `mise --version` failed.")
            )
        }
        // "2026.7.3 macos-arm64 (2026-07-08)"
        let version = ProviderSupport.firstLine(result.standardOutputText)?
            .split(separator: " ").first.map(String.init)

        return ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(
                executable: executable,
                version: version,
                facts: [
                    ProviderFact(key: FactKey.globalConfigFile, label: "Global config", value: directories.globalConfigFile),
                    ProviderFact(key: FactKey.dataDirectory, label: "Installs", value: directories.data + "/installs"),
                    ProviderFact(key: FactKey.workingDirectory, label: "Checked from", value: context.homeDirectory),
                ]
            )
        )
    }

    // MARK: Listing

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        let installation = try await requireInstallation(context)
        let result = try await run(["outdated", "--json"], installation, context: context, timeout: .seconds(180))
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`mise outdated` failed.")
        }
        var listing = try MiseParsers.parseOutdated(
            result.standardOutput,
            context: parserContext(installation, context: context, command: result.invocation.displayString)
        )
        // mise can exit 0 after a version lookup failed, omitting that tool and
        // saying so only on stderr; results are then incomplete, not up to date.
        if let problems = Self.lookupProblems(in: result.standardErrorText) {
            listing.partial = true
            listing.findings.append(problems)
        }
        return listing
    }

    /// What `mise outdated` printed on stderr while still succeeding, minus the
    /// self-update notice, or `nil` when there is nothing else.
    static func lookupProblems(in standardError: String) -> DiagnosticFinding? {
        let lines = standardError.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let lower = line.lowercased()
            let isUpdateNotice = lower.contains("mise version") && lower.contains("available")
            return !line.trimmingCharacters(in: .whitespaces).isEmpty && !isUpdateNotice
        }
        guard !lines.isEmpty else { return nil }
        return DiagnosticFinding(
            id: "mise.outdatedWarnings",
            severity: .warning,
            provider: .mise,
            title: "mise reported problems while checking for updates",
            detail: TextExcerpt.tail(of: lines.joined(separator: "\n"), maxLines: 6),
            recommendation: "Some tools may be missing from these results. Run `mise outdated` to see what mise could not check."
        )
    }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        let installation = try await requireInstallation(context)
        let result = try await run(["ls", "--json"], installation, context: context, timeout: .seconds(120))
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`mise ls` failed.")
        }
        return try MiseParsers.parseInventory(
            result.standardOutput,
            context: parserContext(installation, context: context, command: result.invocation.displayString)
        )
    }

    // MARK: Helpers

    struct Directories: Equatable {
        var config: String
        var globalConfigFile: String
        var data: String
    }

    /// mise's directories, following mise's documented environment variables.
    static func directories(environment: [String: String], homeDirectory: String) -> Directories {
        func absolute(_ name: String) -> String? {
            guard let value = environment[name], value.hasPrefix("/") else { return nil }
            return PathDisplay.standardized(value)
        }
        let config = absolute("MISE_CONFIG_DIR") ?? absolute("XDG_CONFIG_HOME").map { $0 + "/mise" } ?? homeDirectory + "/.config/mise"
        return Directories(
            config: config,
            globalConfigFile: absolute("MISE_GLOBAL_CONFIG_FILE") ?? config + "/config.toml",
            data: NodeManager.miseDataDirectory(environment: environment, homeDirectory: homeDirectory)
        )
    }

    /// Classifies the file a tool request came from.
    static func scope(of path: String?, type: String?, homeDirectory: String, directories: Directories) -> MiseConfigScope {
        guard let path, path.hasPrefix("/"), type != "unknown" else { return .unknown }
        let standardized = (path as NSString).standardizingPath
        if standardized == directories.globalConfigFile || standardized.hasPrefix(directories.config + "/") {
            return .global
        }
        if standardized.hasPrefix("/etc/mise/") { return .system }
        // mise looks for config files relative to each directory: `mise.toml`,
        // `.tool-versions`, `.config/mise/config.toml`, `.mise/config.toml`,
        // `mise/config.toml`, … Found directly under home, they apply to
        // everything beneath it.
        if standardized.hasPrefix(homeDirectory + "/") {
            let relative = standardized.dropFirst(homeDirectory.count + 1)
            if !relative.contains("/") || relative.hasPrefix(".config/") || relative.hasPrefix(".mise/")
                || relative.hasPrefix("mise/") {
                return .home
            }
        }
        return .project
    }

    func parserContext(_ installation: ProviderInstallation, context: ProviderContext, command: String) -> MiseParsers.Context {
        MiseParsers.Context(
            homeDirectory: context.homeDirectory,
            directories: Self.directories(environment: context.environment, homeDirectory: context.homeDirectory),
            miseLink: OwnershipLink(
                label: "mise \(installation.version ?? "")".trimmingCharacters(in: .whitespaces),
                path: installation.executable.path
            ),
            fileSystem: context.fileSystem,
            command: command
        )
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
            policy: Self.environmentPolicy,
            searchPath: SearchPath.combine([installation.executable.directory], context.searchPath, SearchPath.system),
            context: context,
            workingDirectory: context.homeDirectory,
            timeout: timeout
        )
    }
}
