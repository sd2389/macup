import Foundation

/// Turns update candidates into reviewable execution plans.
///
/// The planner runs the read-only check, asks ``PolicyEngine`` about every
/// candidate, and asks the owning provider for the exact commands behind the
/// ones policy has not refused. It launches nothing: a plan is a description.
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
        let report = await CheckEngine(providers: providers).run(
            configuration: configuration,
            options: CheckOptions(refreshMetadata: request.refreshMetadata),
            environment: environment
        )
        return await plan(report, request: request, configuration: configuration, environment: environment)
    }

    /// Plans from candidates already found by a check, so the app and the CLI
    /// can review updates without checking twice.
    public func plan(
        _ report: CheckReport,
        request: PlanRequest,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> PlanReport {
        // Fails closed until Phase 2 planning lands: every candidate is
        // reported as unplannable rather than assumed safe.
        PlanReport(
            createdAt: environment.now(),
            intent: request.intent,
            planned: [],
            skipped: report.updates.map { candidate in
                SkippedUpdate(
                    item: candidate.id,
                    displayName: candidate.displayName,
                    currentVersion: candidate.installedVersion?.raw,
                    proposedVersion: candidate.availableVersion.raw,
                    reason: "MacUp cannot plan updates in this version.",
                    error: MacUpError(.unsupported, "Update planning is not implemented yet.")
                )
            },
            configuration: ConfigurationSummary(configuration),
            providers: report.providers,
            cancelled: report.cancelled
        )
    }
}
