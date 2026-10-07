import Foundation

/// A provider operation that failed during a check.
public struct ProviderOperationError: Sendable, Hashable, Codable {
    public enum Operation: String, Sendable, Hashable, Codable {
        case detect
        case refreshMetadata
        case inventory
        case outdated
    }

    public var operation: Operation
    public var error: MacUpError

    public init(operation: Operation, error: MacUpError) {
        self.operation = operation
        self.error = error
    }
}

/// Everything one provider contributed to a check.
public struct ProviderReport: Sendable, Hashable, Codable {
    public var provider: ProviderID
    public var displayName: String
    public var availability: ProviderStatus.Availability
    public var capabilities: [ProviderCapability]
    public var executable: ResolvedExecutable?
    public var version: String?
    public var facts: [ProviderFact]
    /// Number of installed items, or `nil` when the inventory was not
    /// available (unsupported, disabled, or failed).
    public var installedCount: Int?
    /// Number of updates found, or `nil` when the outdated check did not complete.
    public var updateCount: Int?
    /// Updates the provider listed that MacUp could not read or identify; not
    /// counted in ``updateCount``.
    public var unreadableUpdates: Int
    /// Whether the update results are known to be missing something: unreadable
    /// entries, or a provider that reported lookups it could not finish.
    public var resultsIncomplete: Bool
    /// Installed items; included only when requested.
    public var items: [ManagedItem]?
    public var findings: [DiagnosticFinding]
    public var errors: [ProviderOperationError]
    public var durationSeconds: Double

    public init(
        provider: ProviderID,
        displayName: String,
        availability: ProviderStatus.Availability,
        capabilities: [ProviderCapability],
        executable: ResolvedExecutable? = nil,
        version: String? = nil,
        facts: [ProviderFact] = [],
        installedCount: Int? = nil,
        updateCount: Int? = nil,
        unreadableUpdates: Int = 0,
        resultsIncomplete: Bool = false,
        items: [ManagedItem]? = nil,
        findings: [DiagnosticFinding] = [],
        errors: [ProviderOperationError] = [],
        durationSeconds: Double = 0
    ) {
        self.provider = provider
        self.displayName = displayName
        self.availability = availability
        self.capabilities = capabilities
        self.executable = executable
        self.version = version
        self.facts = facts
        self.installedCount = installedCount
        self.updateCount = updateCount
        self.unreadableUpdates = unreadableUpdates
        self.resultsIncomplete = resultsIncomplete
        self.items = items
        self.findings = findings
        self.errors = errors
        self.durationSeconds = durationSeconds
    }

    public var hasErrors: Bool { !errors.isEmpty }
}

/// The configuration a report was produced under.
public struct ConfigurationSummary: Sendable, Hashable, Codable {
    public var path: String
    public var source: LoadedConfiguration.Source
    public var valid: Bool
    public var automaticModificationsAllowed: Bool
    public var issues: [ConfigurationIssue]

    public init(_ loaded: LoadedConfiguration) {
        path = loaded.path
        source = loaded.source
        valid = !loaded.hasErrors
        automaticModificationsAllowed = loaded.allowsAutomaticModification
        issues = loaded.issues
    }
}

/// The result of `macup check`: versioned, machine-readable, and read-only.
///
/// Schema version 1. New fields may be added within a version; renaming or
/// removing a field requires a new version (docs/CLI.md).
public struct CheckReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public enum Mode: String, Sendable, Hashable, Codable {
        /// Nothing was changed.
        case readOnly
        /// Provider metadata was refreshed (`--refresh`); no packages were changed.
        case metadataRefresh
    }

    public struct Summary: Sendable, Hashable, Codable {
        public var updatesAvailable: Int
        public var providersChecked: Int
        public var providersUnavailable: Int
        public var providersDisabled: Int
        public var providersWithErrors: Int
        /// Providers that finished without errors but left some updates out.
        public var providersIncomplete: Int
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var mode: Mode
    public var startedAt: Date
    public var finishedAt: Date
    public var cancelled: Bool
    public var configuration: ConfigurationSummary
    public var providers: [ProviderReport]
    /// Every update found, in provider order. Each names its provider.
    public var updates: [UpdateCandidate]
    public var summary: Summary
    /// Every command MacUp ran (or refused) for this check, redacted.
    public var commands: [CommandRecord]
    /// Set when `updates` was narrowed or reordered (``filtered(_:sortedBy:effectivePolicies:)``),
    /// and absent otherwise, so an unfiltered report encodes as it always has.
    public var filter: ReportFilter?

    public init(
        mode: Mode,
        startedAt: Date,
        finishedAt: Date,
        cancelled: Bool,
        configuration: ConfigurationSummary,
        providers: [ProviderReport],
        updates: [UpdateCandidate],
        commands: [CommandRecord]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "check"
        self.macupVersion = MacUp.version
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cancelled = cancelled
        self.configuration = configuration
        self.providers = providers
        self.updates = updates
        self.commands = commands
        self.summary = Summary(
            updatesAvailable: updates.count,
            providersChecked: providers.filter { $0.availability == .available }.count,
            providersUnavailable: providers.filter { $0.availability == .unavailable }.count,
            providersDisabled: providers.filter { $0.availability == .disabled }.count,
            providersWithErrors: providers.filter { $0.hasErrors }.count,
            providersIncomplete: providers.filter { !$0.hasErrors && $0.resultsIncomplete }.count
        )
    }

    public var hasProviderErrors: Bool { providers.contains(where: \.hasErrors) }

    /// Finished, every checked provider succeeded, and none left updates out.
    /// Only a complete check may be summarized as "up to date".
    public var isComplete: Bool {
        !cancelled && summary.providersWithErrors == 0 && summary.providersIncomplete == 0
    }

    public func updates(for provider: ProviderID) -> [UpdateCandidate] {
        updates.filter { $0.provider == provider }
    }
}
