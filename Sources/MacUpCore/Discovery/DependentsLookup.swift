import Foundation

/// The answer to "what on this Mac depends on this item?": the software an
/// update of it could affect.
///
/// Schema version 1. New fields may be added within a version; renaming or
/// removing a field requires a new version (docs/CLI.md).
public struct DependentsReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public enum Outcome: String, Sendable, Hashable, Codable {
        /// The provider answered, and ``DependentsReport/dependents`` is its
        /// whole answer, which may be that nothing depends on the item.
        case listed
        /// MacUp cannot ask about this kind of item.
        case unsupported
        /// The provider does not list the item as installed, so there was
        /// nothing to ask about.
        case notInstalled
        /// The provider could not be used, or its answer could not be read.
        case failed
        /// Stopped before the provider answered.
        case cancelled
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var item: PackageID
    public var outcome: Outcome
    /// Installed items that need ``item``, sorted. `nil` unless the outcome
    /// is `listed`: "MacUp could not find out" is never shown as "nothing".
    public var dependents: [PackageID]?
    /// Whether the provider named things MacUp could not read, so the list
    /// may be missing them. Each one has a finding.
    public var resultsIncomplete: Bool
    public var findings: [DiagnosticFinding]
    /// Why there is no answer, when there is none.
    public var error: MacUpError?
    public var startedAt: Date
    public var finishedAt: Date
    /// Every command MacUp ran (or refused) to answer, redacted.
    public var commands: [CommandRecord]

    public init(
        item: PackageID,
        outcome: Outcome,
        dependents: [PackageID]? = nil,
        resultsIncomplete: Bool = false,
        findings: [DiagnosticFinding] = [],
        error: MacUpError? = nil,
        startedAt: Date,
        finishedAt: Date,
        commands: [CommandRecord] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "dependents"
        self.macupVersion = MacUp.version
        self.item = item
        self.outcome = outcome
        self.dependents = outcome == .listed ? dependents ?? [] : nil
        self.resultsIncomplete = resultsIncomplete
        self.findings = findings
        self.error = error
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.commands = commands
    }
}

/// Asks an item's provider what installed software depends on it.
///
/// Only when someone asks, one item at a time: `macup dependents`, or Show
/// What Depends on It in the app. Every command goes through a
/// ``ReadOnlyCommandGuard`` whose rules are the check's allowlist plus
/// ``CommandAllowlist/dependentsLookup``, so a lookup can find the provider,
/// confirm the item is installed, and ask about it, and nothing else. A
/// check is never given those extra rules, which is what keeps a slow,
/// item-naming command out of every normal check.
public struct DependentsLookup: Sendable {
    public var providers: [any UpdateProvider]

    public init(providers: [any UpdateProvider]) {
        self.providers = providers
    }

    public static func standard() -> DependentsLookup {
        DependentsLookup(providers: CheckEngine.standard().providers)
    }

    /// Whether MacUp can ask about this item at all. Runs nothing.
    public func canList(_ item: PackageID) -> Bool {
        guard let provider = providers.first(where: { $0.id == item.provider }) else { return false }
        return provider.capabilities.contains(.listDependents) && provider.canListDependents(of: item)
    }

    /// Asks what depends on `item`.
    ///
    /// When `report` is the check that found the item, its provider
    /// installation is reused and nothing is detected twice. Otherwise the
    /// provider is located first, and its inventory read, because MacUp only
    /// asks about something the provider says is installed.
    public func run(
        _ item: PackageID,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        after report: CheckReport? = nil
    ) async -> DependentsReport {
        let startedAt = environment.now()
        let log = CommandLog()
        func finish(
            _ outcome: DependentsReport.Outcome,
            _ listing: ProviderListing<PackageID>? = nil,
            error: MacUpError? = nil
        ) async -> DependentsReport {
            let stopped = outcome != .listed && (Task.isCancelled || error?.kind == .cancelled)
            return DependentsReport(
                item: item,
                outcome: stopped ? .cancelled : outcome,
                dependents: listing?.elements,
                resultsIncomplete: listing?.isIncomplete ?? false,
                findings: listing?.findings ?? [],
                error: error,
                startedAt: startedAt,
                finishedAt: environment.now(),
                commands: await log.records.sorted { $0.startedAt < $1.startedAt }
            )
        }

        guard canList(item), let provider = providers.first(where: { $0.id == item.provider }) else {
            return await finish(.unsupported, error: MacUpError(
                .unsupported,
                "MacUp can only ask what depends on a Homebrew formula, so it cannot ask about \(item.rawValue).",
                recoverySuggestion: "Ask about a formula instead, for example brew:openssl@3."
            ))
        }
        let settings = configuration.configuration.settings(for: provider.id)
        guard settings.enabled else {
            return await finish(.failed, error: MacUpError(
                .providerUnavailable,
                "\(provider.displayName) is turned off in MacUp's configuration, so MacUp asked it nothing.",
                recoverySuggestion: "`macup provider enable \(provider.id.rawValue)` turns it back on."
            ))
        }

        var context = ProviderContext(
            runner: RecordingCommandRunner(
                base: ReadOnlyCommandGuard(
                    base: environment.runner,
                    rules: CommandAllowlist.readOnlyCheck + CommandAllowlist.dependentsLookup,
                    allowsMetadataRefresh: false
                ),
                log: log
            ),
            fileSystem: environment.fileSystem,
            environment: environment.processEnvironment,
            homeDirectory: PathDisplay.standardized(environment.homeDirectory),
            searchPath: SearchPath.parse(environment.processEnvironment["PATH"]),
            settings: settings,
            system: environment.system,
            now: environment.now
        )

        let checked = report?.providers.first { $0.provider == provider.id && $0.availability == .available }
        if let checked, let executable = checked.executable {
            context.installation = ProviderInstallation(executable: executable, version: checked.version, facts: checked.facts)
        } else {
            let status = await provider.detect(context: context)
            guard status.availability == .available, let installation = status.installation else {
                return await finish(.failed, error: status.error ?? MacUpError(
                    .providerUnavailable,
                    "\(provider.displayName) is not available, so MacUp could not ask it."
                ))
            }
            context.installation = installation
        }

        let found = report?.updates.contains { $0.id == item } == true
            || checked?.items?.contains { $0.id == item } == true
        if !found {
            do {
                let inventory = try await provider.inventory(context: context)
                guard inventory.elements.contains(where: { $0.id == item }) else {
                    return await finish(.notInstalled, error: MacUpError(
                        .unsupported,
                        "\(provider.displayName) does not list \(item.rawValue) as installed, so nothing on this Mac depends on it through \(provider.displayName).",
                        recoverySuggestion: "`macup check --inventory` lists what is installed."
                    ))
                }
            } catch {
                return await finish(.failed, error: MacUpError.wrapping(
                    error,
                    context: "Reading what \(provider.displayName) has installed"
                ))
            }
        }

        do {
            let listing = try await provider.dependents(of: item, context: context)
            return await finish(.listed, listing)
        } catch {
            return await finish(.failed, error: MacUpError.wrapping(
                error,
                context: "Asking \(provider.displayName) what depends on \(item.name)"
            ))
        }
    }
}
