import Foundation

/// What a check should do.
public struct CheckOptions: Sendable, Hashable {
    /// Refresh provider metadata first (`--refresh`).
    public var refreshMetadata: Bool
    /// Limit the check to these providers; `nil` means every enabled provider.
    public var providers: Set<ProviderID>?
    /// Include installed items in the report.
    public var includeInventoryItems: Bool

    public init(refreshMetadata: Bool = false, providers: Set<ProviderID>? = nil, includeInventoryItems: Bool = false) {
        self.refreshMetadata = refreshMetadata
        self.providers = providers
        self.includeInventoryItems = includeInventoryItems
    }
}

/// The outside world a check runs against.
public struct CheckEnvironment: Sendable {
    public var runner: any CommandRunning
    public var fileSystem: any FileSystem
    public var processEnvironment: [String: String]
    public var homeDirectory: String
    public var system: SystemInfo
    public var now: @Sendable () -> Date

    public init(
        runner: any CommandRunning,
        fileSystem: any FileSystem,
        processEnvironment: [String: String],
        homeDirectory: String,
        system: SystemInfo,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.fileSystem = fileSystem
        self.processEnvironment = processEnvironment
        self.homeDirectory = homeDirectory
        self.system = system
        self.now = now
    }

    /// The real machine.
    public static func live(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> CheckEnvironment {
        CheckEnvironment(
            runner: ProcessCommandRunner(),
            fileSystem: LocalFileSystem(),
            processEnvironment: processEnvironment,
            homeDirectory: homeDirectory,
            system: .current()
        )
    }
}

/// Runs the read-only check across providers (ARCHITECTURE.md, "Check").
///
/// detect → (refresh, when asked) → inventory ∥ outdated → normalize → report.
///
/// Every command passes through a ``ReadOnlyCommandGuard`` built from
/// ``CommandAllowlist``, so a check cannot run anything modifying even by
/// mistake. Providers are checked concurrently, one task each (bounded by the
/// number of providers).
public struct CheckEngine: Sendable {
    public var providers: [any UpdateProvider]

    public init(providers: [any UpdateProvider]) {
        self.providers = providers
    }

    public static func standard() -> CheckEngine {
        CheckEngine(providers: [HomebrewProvider(), NpmProvider(), MiseProvider(), MacOSProvider()])
    }

    public func run(
        configuration: LoadedConfiguration,
        options: CheckOptions = CheckOptions(),
        environment: CheckEnvironment
    ) async -> CheckReport {
        let startedAt = environment.now()
        let log = CommandLog()
        let runner = guardedRunner(environment, log: log, allowsMetadataRefresh: options.refreshMetadata)

        let outcomes = await withTaskGroup(of: (Int, ProviderOutcome).self) { group in
            var outcomes: [(Int, ProviderOutcome)] = []
            for (index, provider) in providers.enumerated() {
                guard options.providers?.contains(provider.id) ?? true else { continue }
                let settings = configuration.configuration.settings(for: provider.id)
                guard settings.enabled else {
                    outcomes.append((index, disabledReport(provider)))
                    continue
                }
                let context = makeContext(environment, runner: runner, settings: settings, refresh: options.refreshMetadata)
                group.addTask {
                    (index, await Self.check(provider, context: context, options: options))
                }
            }
            for await outcome in group { outcomes.append(outcome) }
            return outcomes.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return CheckReport(
            mode: options.refreshMetadata ? .metadataRefresh : .readOnly,
            startedAt: startedAt,
            finishedAt: environment.now(),
            cancelled: Task.isCancelled,
            configuration: ConfigurationSummary(configuration),
            providers: outcomes.map(\.report),
            updates: outcomes.flatMap(\.candidates),
            commands: await log.records.sorted { $0.startedAt < $1.startedAt }
        )
    }

    /// Detection only, for `macup provider list`.
    public func detect(configuration: LoadedConfiguration, environment: CheckEnvironment) async -> (providers: [ProviderReport], commands: [CommandRecord]) {
        let log = CommandLog()
        let runner = guardedRunner(environment, log: log, allowsMetadataRefresh: false)
        let reports = await withTaskGroup(of: (Int, ProviderReport).self) { group in
            var reports: [(Int, ProviderReport)] = []
            for (index, provider) in providers.enumerated() {
                let settings = configuration.configuration.settings(for: provider.id)
                guard settings.enabled else {
                    reports.append((index, disabledReport(provider).report))
                    continue
                }
                let context = makeContext(environment, runner: runner, settings: settings, refresh: false)
                group.addTask {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let status = await provider.detect(context: context)
                    var report = Self.report(for: provider, status: status)
                    report.durationSeconds = Self.seconds(clock.now - start)
                    return (index, report)
                }
            }
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (reports, await log.records.sorted { $0.startedAt < $1.startedAt })
    }

    // MARK: Internals

    private struct ProviderOutcome: Sendable {
        var report: ProviderReport
        var candidates: [UpdateCandidate]
    }

    private func guardedRunner(_ environment: CheckEnvironment, log: CommandLog, allowsMetadataRefresh: Bool) -> any CommandRunning {
        RecordingCommandRunner(
            base: ReadOnlyCommandGuard(
                base: environment.runner,
                rules: CommandAllowlist.readOnlyCheck,
                allowsMetadataRefresh: allowsMetadataRefresh
            ),
            log: log
        )
    }

    private func makeContext(
        _ environment: CheckEnvironment,
        runner: any CommandRunning,
        settings: MacUpConfiguration.ProviderSettings,
        refresh: Bool
    ) -> ProviderContext {
        ProviderContext(
            runner: runner,
            fileSystem: environment.fileSystem,
            environment: environment.processEnvironment,
            homeDirectory: PathDisplay.standardized(environment.homeDirectory),
            searchPath: SearchPath.parse(environment.processEnvironment["PATH"]),
            settings: settings,
            refreshMetadata: refresh,
            system: environment.system
        )
    }

    private func disabledReport(_ provider: any UpdateProvider) -> ProviderOutcome {
        ProviderOutcome(report: Self.report(for: provider, status: .disabled(provider.id)), candidates: [])
    }

    private static func report(for provider: any UpdateProvider, status: ProviderStatus) -> ProviderReport {
        ProviderReport(
            provider: provider.id,
            displayName: provider.displayName,
            availability: status.availability,
            capabilities: provider.capabilities.sorted(),
            executable: status.installation?.executable,
            version: status.installation?.version,
            facts: status.installation?.facts ?? [],
            findings: status.findings,
            errors: status.error.map { [ProviderOperationError(operation: .detect, error: $0)] } ?? []
        )
    }

    private static func check(
        _ provider: any UpdateProvider,
        context: ProviderContext,
        options: CheckOptions
    ) async -> ProviderOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let status = await provider.detect(context: context)
        var report = report(for: provider, status: status)
        // An unavailable provider is not an error: it is simply not installed.
        if status.availability == .unavailable { report.errors = [] }
        guard status.availability == .available, let installation = status.installation else {
            report.durationSeconds = seconds(clock.now - start)
            return ProviderOutcome(report: report, candidates: [])
        }

        var scopedContext = context
        scopedContext.installation = installation
        let scoped = scopedContext

        if options.refreshMetadata && provider.capabilities.contains(.refreshMetadata) {
            do {
                report.findings += try await provider.refreshMetadata(context: scoped)
            } catch {
                report.errors.append(ProviderOperationError(
                    operation: .refreshMetadata,
                    error: MacUpError.wrapping(error, context: "Refreshing \(provider.displayName) metadata")
                ))
            }
        }

        let wantsInventory = provider.capabilities.contains(.inventory)
        async let inventoryResult = capture(wantsInventory) { try await provider.inventory(context: scoped) }
        async let outdatedResult = capture(true) { try await provider.outdated(context: scoped) }
        let (inventory, outdated) = await (inventoryResult, outdatedResult)

        var items: [ManagedItem]?
        switch inventory {
        case .success(let listing?):
            items = listing.elements
            report.installedCount = listing.elements.count
            report.findings += listing.findings
        case .success(nil):
            break
        case .failure(let error):
            report.errors.append(ProviderOperationError(operation: .inventory, error: error))
        }
        if options.includeInventoryItems { report.items = items }

        var candidates: [UpdateCandidate] = []
        switch outdated {
        case .success(let listing?):
            candidates = provider.refine(listing.elements, using: items ?? [])
            report.updateCount = candidates.count
            report.findings += listing.findings
        case .success(nil):
            break
        case .failure(let error):
            report.errors.append(ProviderOperationError(operation: .outdated, error: error))
        }

        report.durationSeconds = seconds(clock.now - start)
        return ProviderOutcome(report: report, candidates: candidates.sorted { $0.id < $1.id })
    }

    private static func capture<Element>(
        _ enabled: Bool,
        _ operation: @Sendable () async throws -> ProviderListing<Element>
    ) async -> Result<ProviderListing<Element>?, MacUpError> {
        guard enabled else { return .success(nil) }
        do {
            return .success(try await operation())
        } catch {
            return .failure(MacUpError.wrapping(error, context: "The provider operation"))
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
