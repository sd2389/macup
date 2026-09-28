import Foundation

/// How one execution run should behave.
public struct ExecutionOptions: Sendable, Hashable {
    public var origin: ExecutionOrigin
    public var intent: PolicyIntent
    /// Items the user confirmed. A plan needing confirmation runs only when
    /// its item is in this set.
    public var confirmed: Set<PackageID>
    /// Describe what would run and launch nothing.
    public var dryRun: Bool
    /// Stop after the first failure instead of moving to the next item.
    public var stopOnFailure: Bool

    public init(
        origin: ExecutionOrigin,
        intent: PolicyIntent = .interactive,
        confirmed: Set<PackageID> = [],
        dryRun: Bool = false,
        stopOnFailure: Bool = false
    ) {
        self.origin = origin
        self.intent = intent
        self.confirmed = confirmed
        self.dryRun = dryRun
        self.stopOnFailure = stopOnFailure
    }
}

/// One item MacUp attempted, with what happened and whether it worked.
public struct ExecutedUpdate: Sendable, Hashable, Codable, Identifiable {
    public var item: PackageID
    public var displayName: String
    public var plan: ExecutionPlan
    public var result: ExecutionResult
    public var verification: VerificationResult?

    public init(
        item: PackageID,
        displayName: String,
        plan: ExecutionPlan,
        result: ExecutionResult,
        verification: VerificationResult? = nil
    ) {
        self.item = item
        self.displayName = displayName
        self.plan = plan
        self.result = result
        self.verification = verification
    }

    public var id: PackageID { item }
    public var provider: ProviderID { item.provider }
    public var succeeded: Bool { result.outcome == .succeeded }
}

/// The result of `macup update`: what MacUp attempted, what it skipped, and
/// what it confirmed afterwards.
///
/// Schema version 1.
public struct ExecutionReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public struct Summary: Sendable, Hashable, Codable {
        public var attempted: Int
        public var succeeded: Int
        public var failed: Int
        public var skipped: Int
        public var verified: Int
        /// Attempts that succeeded but could not be confirmed.
        public var unverified: Int

        public init(attempted: Int, succeeded: Int, failed: Int, skipped: Int, verified: Int, unverified: Int) {
            self.attempted = attempted
            self.succeeded = succeeded
            self.failed = failed
            self.skipped = skipped
            self.verified = verified
            self.unverified = unverified
        }
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var origin: ExecutionOrigin
    public var dryRun: Bool
    public var startedAt: Date
    public var finishedAt: Date
    public var cancelled: Bool
    public var executed: [ExecutedUpdate]
    public var skipped: [SkippedUpdate]
    public var summary: Summary

    public init(
        origin: ExecutionOrigin,
        dryRun: Bool,
        startedAt: Date,
        finishedAt: Date,
        cancelled: Bool = false,
        executed: [ExecutedUpdate],
        skipped: [SkippedUpdate]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "update"
        self.macupVersion = MacUp.version
        self.origin = origin
        self.dryRun = dryRun
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.cancelled = cancelled
        self.executed = executed
        self.skipped = skipped
        self.summary = Summary(
            attempted: executed.count,
            succeeded: executed.filter { $0.result.outcome == .succeeded }.count,
            failed: executed.filter { $0.result.outcome == .failed || $0.result.outcome == .timedOut }.count,
            skipped: skipped.count,
            verified: executed.filter { $0.verification?.outcome == .verified }.count,
            unverified: executed.filter { $0.result.outcome == .succeeded && $0.verification?.outcome != .verified }.count
        )
    }

    public var hasFailures: Bool { summary.failed > 0 }
}

/// Runs approved plans, one item at a time.
///
/// The engine is the only place in MacUp that launches a modifying command.
/// Before each plan it re-reads the configuration and re-asks
/// ``PolicyEngine``, because a policy may have changed since the plan was
/// built (CLAUDE.md §2.20), and it records every attempt in history.
public struct ExecutionEngine: Sendable {
    public var providers: [any UpdateProvider]
    /// Where attempts are recorded. `nil` disables recording (tests only).
    public var history: HistoryStore?
    /// Re-read immediately before each item so a policy change since planning
    /// takes effect. `nil` re-uses the configuration the plan was built with.
    public var configurationStore: ConfigurationStore?

    public init(
        providers: [any UpdateProvider],
        history: HistoryStore? = nil,
        configurationStore: ConfigurationStore? = nil
    ) {
        self.providers = providers
        self.history = history
        self.configurationStore = configurationStore
    }

    public static func standard(paths: MacUpPaths) -> ExecutionEngine {
        ExecutionEngine(
            providers: [HomebrewProvider(), NpmProvider(), MiseProvider(), MacOSProvider()],
            history: HistoryStore(paths: paths),
            configurationStore: ConfigurationStore(paths: paths)
        )
    }

    /// Executes the plans in `report` that `options` permits.
    public func run(
        _ report: PlanReport,
        configuration: LoadedConfiguration,
        options: ExecutionOptions,
        environment: CheckEnvironment
    ) async -> ExecutionReport {
        // Fails closed until Phase 3 execution lands: nothing is launched and
        // every plan is reported as skipped.
        let now = environment.now()
        return ExecutionReport(
            origin: options.origin,
            dryRun: options.dryRun,
            startedAt: now,
            finishedAt: now,
            executed: [],
            skipped: report.planned.map { planned in
                SkippedUpdate(
                    item: planned.item,
                    displayName: planned.candidate.displayName,
                    currentVersion: planned.candidate.installedVersion?.raw,
                    proposedVersion: planned.candidate.availableVersion.raw,
                    decision: planned.decision,
                    reason: "MacUp cannot apply updates in this version.",
                    error: MacUpError(.unsupported, "Update execution is not implemented yet.")
                )
            } + report.skipped
        )
    }
}
