import Foundation

/// What a provider needs from the outside world. Everything is injected so
/// providers can be tested against fakes.
public struct ProviderContext: Sendable {
    public var runner: any CommandRunning
    public var fileSystem: any FileSystem
    /// MacUp's own environment. Providers copy allowlisted variables from it;
    /// it is never logged.
    public var environment: [String: String]
    public var homeDirectory: String
    /// The user's executable search path, already sanitized.
    public var searchPath: [String]
    public var settings: MacUpConfiguration.ProviderSettings
    /// True only for `macup check --refresh`.
    public var refreshMetadata: Bool
    public var system: SystemInfo
    /// Set by the check engine after successful detection so every command
    /// in one check uses the same installation.
    public var installation: ProviderInstallation?

    public init(
        runner: any CommandRunning,
        fileSystem: any FileSystem,
        environment: [String: String],
        homeDirectory: String,
        searchPath: [String],
        settings: MacUpConfiguration.ProviderSettings = .init(),
        refreshMetadata: Bool = false,
        system: SystemInfo,
        installation: ProviderInstallation? = nil
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
        self.settings = settings
        self.refreshMetadata = refreshMetadata
        self.system = system
        self.installation = installation
    }

    public var resolver: ExecutableResolver { ExecutableResolver(fileSystem: fileSystem) }
}

/// Items or candidates plus what the provider noticed while producing them.
public struct ProviderListing<Element: Sendable & Hashable>: Sendable, Hashable {
    public var elements: [Element]
    public var findings: [DiagnosticFinding]

    public init(_ elements: [Element] = [], findings: [DiagnosticFinding] = []) {
        self.elements = elements
        self.findings = findings
    }
}

/// An adapter over one package manager (CLAUDE.md §7, docs/PROVIDER_SPEC.md).
///
/// Providers translate provider state into MacUp models and never modify
/// anything while detecting, listing, or checking. `inventory` and `outdated`
/// return findings alongside their results so parse ambiguities are reported
/// rather than dropped.
public protocol UpdateProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: Set<ProviderCapability> { get }

    /// Locates the provider and records exactly which installation will be used.
    func detect(context: ProviderContext) async -> ProviderStatus

    /// Refreshes package metadata. Called only for `macup check --refresh`
    /// and only when ``capabilities`` contains `.refreshMetadata`.
    func refreshMetadata(context: ProviderContext) async throws -> [DiagnosticFinding]

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem>
    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate>

    /// Adds facts only the inventory knows (for example that a cask uses an
    /// installer package) to the candidates.
    func refine(_ candidates: [UpdateCandidate], using inventory: [ManagedItem]) -> [UpdateCandidate]

    /// Builds an exact execution plan. Phase 2.
    func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan

    /// Confirms an update reached its target. Phase 3.
    func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult
}

extension UpdateProvider {
    public var displayName: String { id.displayName }

    public func refreshMetadata(context: ProviderContext) async throws -> [DiagnosticFinding] { [] }

    public func refine(_ candidates: [UpdateCandidate], using inventory: [ManagedItem]) -> [UpdateCandidate] {
        candidates
    }

    // Fail closed until planning and execution exist for this provider.
    public func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        throw MacUpError(.unsupported, "\(displayName) cannot plan updates yet; MacUp is read-only in this version.")
    }

    public func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        throw MacUpError(.unsupported, "\(displayName) cannot verify updates yet; MacUp is read-only in this version.")
    }

    /// The installation chosen at detection, or a fresh detection when a
    /// provider method is called on its own.
    func requireInstallation(_ context: ProviderContext) async throws -> ProviderInstallation {
        if let installation = context.installation { return installation }
        let status = await detect(context: context)
        guard status.availability == .available, let installation = status.installation else {
            throw status.error ?? MacUpError(.providerUnavailable, "\(displayName) is not available.")
        }
        return installation
    }
}

/// Helpers shared by providers.
enum ProviderSupport {
    /// Runs a read-only command with a provider's environment policy.
    static func run(
        _ executable: String,
        _ arguments: [String],
        effect: CommandEffect = .readOnly,
        policy: EnvironmentPolicy,
        searchPath: [String],
        context: ProviderContext,
        workingDirectory: String? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> CommandResult {
        let request = CommandRequest(
            executable: URL(fileURLWithPath: executable),
            arguments: arguments,
            environment: policy.environment(from: context.environment, searchPath: searchPath),
            workingDirectory: URL(fileURLWithPath: workingDirectory ?? context.homeDirectory, isDirectory: true),
            timeout: timeout,
            effect: effect
        )
        return try await context.runner.run(request)
    }

    /// The error for a provider whose executable could not be resolved.
    static func status(
        for resolution: ExecutableResolution,
        provider: ProviderID,
        installHint: String
    ) -> ProviderStatus? {
        switch resolution {
        case .found:
            return nil
        case .notFound(let searched):
            return ProviderStatus(
                provider: provider,
                availability: .unavailable,
                error: MacUpError(
                    .providerUnavailable,
                    "\(provider.displayName) was not found.",
                    detail: searched.isEmpty ? nil : "Searched: " + searched.joined(separator: ", "),
                    recoverySuggestion: installHint
                )
            )
        case .invalidConfiguredPath(let path, let reason):
            return ProviderStatus(
                provider: provider,
                availability: .failed,
                error: MacUpError(
                    .configurationInvalid,
                    "The configured \(provider.displayName) path cannot be used: \(reason)",
                    detail: "Configured path: \(path)",
                    recoverySuggestion: "Fix or remove providers.\(provider.rawValue).executablePath in the MacUp configuration."
                )
            )
        }
    }

    /// First line of a command's output, trimmed.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A finding for an entry skipped because its name cannot be a package ID.
    static func skippedName(_ name: String, reason: PackageID.ValidationError, provider: ProviderID) -> DiagnosticFinding {
        DiagnosticFinding(
            id: "\(provider.rawValue).unusableName",
            severity: .warning,
            provider: provider,
            title: "Skipped an item with a name MacUp will not handle",
            detail: "\(TerminalText.sanitize(name.debugDescription)): \(reason)",
            recommendation: "MacUp ignores this item rather than risk misreading it."
        )
    }

    static func skippedEntry(_ name: String, provider: ProviderID, reason: String) -> DiagnosticFinding {
        DiagnosticFinding(
            id: "\(provider.rawValue).unreadableEntry",
            severity: .warning,
            provider: provider,
            title: "Skipped an entry MacUp could not read",
            detail: "\(TerminalText.sanitize(name)): \(reason)"
        )
    }

    static func newerThanOffered(_ id: PackageID, installed: String, offered: String) -> DiagnosticFinding {
        DiagnosticFinding(
            id: "\(id.provider.rawValue).installedNewerThanAvailable",
            severity: .info,
            provider: id.provider,
            title: "\(id.name) is newer than the version the provider offers",
            detail: "Installed \(installed); offered \(offered). MacUp does not treat this as an update."
        )
    }
}
