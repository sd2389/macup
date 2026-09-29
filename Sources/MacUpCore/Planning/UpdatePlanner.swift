import Foundation

/// Turns update candidates into reviewable execution plans.
///
/// The planner runs the read-only check, asks ``PolicyEngine`` about every
/// candidate, and asks the owning provider for the exact commands behind the
/// ones policy has not refused. It launches nothing: a plan is a description.
///
/// Three rules shape the result, all of them the fail-closed direction
/// (CLAUDE.md §2.23):
///
/// A candidate policy refused becomes a ``SkippedUpdate`` carrying the
/// decision and its reason, and never reaches `planned` — so an ignored or
/// pinned item cannot end up in something a bulk action would run. A
/// candidate whose provider cannot produce a plan becomes a skip carrying
/// the provider's error, never a guess. And a provider MacUp has no plan for
/// at all is refused by capability rather than by hoping its `makePlan`
/// throws.
public struct UpdatePlanner: Sendable {
    public var providers: [any UpdateProvider]

    public init(providers: [any UpdateProvider]) {
        self.providers = providers
    }

    public static func standard() -> UpdatePlanner {
        UpdatePlanner(providers: [HomebrewProvider(), NpmProvider(), MiseProvider(), MacOSProvider()])
    }

    /// Checks for updates and plans the ones policy allows.
    public func plan(
        _ request: PlanRequest,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> PlanReport {
        await checkAndPlan(request, configuration: configuration, environment: environment).plan
    }

    /// The same, handing back the check the plan was built from as well, for
    /// a caller that needs the updates behind the plan's skipped items: a
    /// skip records the item, not the update.
    public func checkAndPlan(
        _ request: PlanRequest,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> (check: CheckReport, plan: PlanReport) {
        let report = await CheckEngine(providers: providers).run(
            configuration: configuration,
            options: CheckOptions(refreshMetadata: request.refreshMetadata),
            environment: environment
        )
        return (report, await plan(report, request: request, configuration: configuration, environment: environment))
    }

    /// Plans from candidates already found by a check, so the app and the CLI
    /// can review updates without checking twice.
    ///
    /// Candidates outside `request.selection` are left out of the report
    /// rather than listed as skipped: they were never part of this run, and
    /// counting them as unplannable would misreport what MacUp could not do.
    /// Items the user named that no provider offered are reported separately
    /// as `unmatchedSelection`.
    public func plan(
        _ report: CheckReport,
        request: PlanRequest,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> PlanReport {
        let policy = PolicyEngine(configuration)
        let contexts = providerContexts(report, configuration: configuration, environment: environment)
        var planned: [PlannedUpdate] = []
        var skipped: [SkippedUpdate] = []
        var matched: Set<PackageID> = []

        // The check engine returns candidates in provider order, each sorted
        // by identity; keeping that order keeps a plan stable across runs.
        for candidate in report.updates {
            if let selection = request.selection {
                guard selection.contains(candidate.id) else { continue }
                matched.insert(candidate.id)
            }

            let decision = policy.decide(candidate, intent: request.intent)
            guard decision.allowsExecution else {
                skipped.append(SkippedUpdate(candidate, decision: decision, reason: decision.reason))
                continue
            }

            guard let provider = providers.first(where: { $0.id == candidate.provider }) else {
                skipped.append(SkippedUpdate(
                    candidate,
                    decision: decision,
                    reason: "MacUp has no provider for \(candidate.provider.displayName).",
                    error: MacUpError(.providerUnavailable, "No \(candidate.provider.displayName) provider is built into this version of MacUp.")
                ))
                continue
            }
            guard provider.capabilities.contains(.planUpdates) else {
                skipped.append(SkippedUpdate(
                    candidate,
                    decision: decision,
                    reason: "MacUp reports \(provider.displayName) updates but does not apply them.",
                    error: MacUpError(
                        .unsupported,
                        "\(provider.displayName) updates are informational in MacUp.",
                        recoverySuggestion: "MacUp reports this one so you can apply it yourself."
                    )
                ))
                continue
            }
            guard let context = contexts[candidate.provider] else {
                skipped.append(SkippedUpdate(
                    candidate,
                    decision: decision,
                    reason: "MacUp did not record which \(provider.displayName) installation this check used, so it cannot name the command.",
                    error: MacUpError(
                        .providerUnavailable,
                        "The \(provider.displayName) check did not report a usable installation.",
                        recoverySuggestion: "Run `macup check` and look at the \(provider.displayName) row."
                    )
                ))
                continue
            }

            do {
                let plan = try await provider.makePlan(for: candidate, context: context)
                planned.append(PlannedUpdate(candidate: candidate, decision: decision, plan: plan))
            } catch {
                let failure = MacUpError.wrapping(error, context: "Planning \(candidate.displayName)")
                skipped.append(SkippedUpdate(
                    candidate,
                    decision: decision,
                    reason: failure.message,
                    error: failure
                ))
            }
        }

        return PlanReport(
            createdAt: environment.now(),
            intent: request.intent,
            planned: planned,
            skipped: skipped,
            configuration: ConfigurationSummary(configuration),
            unmatchedSelection: (request.selection ?? []).subtracting(matched).sorted(),
            providers: report.providers,
            cancelled: report.cancelled
        )
    }

    /// A planning context per available provider, built from what the check
    /// already recorded.
    ///
    /// Planning re-uses the installation the check chose instead of detecting
    /// again, which is why it runs no commands at all. The runner it hands
    /// providers is wrapped in ``ReadOnlyCommandGuard`` so that a provider
    /// which tried to run something while describing a plan would be refused
    /// rather than obeyed.
    private func providerContexts(
        _ report: CheckReport,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) -> [ProviderID: ProviderContext] {
        let runner = ReadOnlyCommandGuard(
            base: environment.runner,
            rules: CommandAllowlist.readOnlyCheck,
            allowsMetadataRefresh: false
        )
        var contexts: [ProviderID: ProviderContext] = [:]
        for provider in report.providers {
            guard provider.availability == .available, let executable = provider.executable else { continue }
            contexts[provider.provider] = ProviderContext(
                runner: runner,
                fileSystem: environment.fileSystem,
                environment: environment.processEnvironment,
                homeDirectory: PathDisplay.standardized(environment.homeDirectory),
                searchPath: SearchPath.parse(environment.processEnvironment["PATH"]),
                settings: configuration.configuration.settings(for: provider.provider),
                system: environment.system,
                installation: ProviderInstallation(
                    executable: executable,
                    version: provider.version,
                    facts: provider.facts
                ),
                now: environment.now
            )
        }
        return contexts
    }
}

extension SkippedUpdate {
    /// A skip that carries the candidate's own versions, so a report can show
    /// what was not changed as fully as what was.
    init(_ candidate: UpdateCandidate, decision: PolicyDecision?, reason: String, error: MacUpError? = nil) {
        self.init(
            item: candidate.id,
            displayName: candidate.displayName,
            currentVersion: candidate.installedVersion?.raw,
            proposedVersion: candidate.availableVersion.raw,
            decision: decision,
            reason: reason,
            error: error
        )
    }
}
