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
///
/// Items run strictly one after another. Two package managers rewriting the
/// same machine at the same time is not something MacUp can reason about, let
/// alone explain afterwards, so the engine never overlaps them
/// (docs/ARCHITECTURE.md, "Concurrency"). Every command goes through an
/// ``ExecutionGuard`` built from the item's own plan, so nothing outside the
/// plan the user reviewed can reach the operating system.
public struct ExecutionEngine: Sendable {
    public var providers: [any UpdateProvider]
    /// Where attempts are recorded. `nil` disables recording (tests only).
    public var history: HistoryStore?
    /// Re-read immediately before each item so a policy change since planning
    /// takes effect. `nil` re-uses the configuration the plan was built with.
    public var configurationStore: ConfigurationStore?
    /// Shapes a modifying command may take at all, checked on top of requiring
    /// that the command was in the plan. Injected so a test can bound what it
    /// permits without touching the shipping list.
    public var modifyingRules: [ModifyingCommandRule]
    /// Overrides the environment a plan's commands run with. `nil`, and so
    /// the owning provider's, everywhere but tests.
    ///
    /// A plan carries the exact executable and arguments — that is what the
    /// user reviewed — but not the environment they need, and only the
    /// provider knows that. Some of what a plan promises lives there and
    /// nowhere else: `HOMEBREW_NO_INSTALL_CLEANUP` and
    /// `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` have no command-line flag, so
    /// an upgrade run without them would clean up after itself and upgrade
    /// dependents the user never reviewed (CLAUDE.md §2.16, §2.17, §9). The
    /// engine therefore asks the provider rather than assembling one itself.
    public var stepEnvironment: (@Sendable (ExecutionPlan, CheckEnvironment) -> [String: String])?

    public init(
        providers: [any UpdateProvider],
        history: HistoryStore? = nil,
        configurationStore: ConfigurationStore? = nil,
        modifyingRules: [ModifyingCommandRule] = ModifyingCommandRules.all,
        stepEnvironment: (@Sendable (ExecutionPlan, CheckEnvironment) -> [String: String])? = nil
    ) {
        self.providers = providers
        self.history = history
        self.configurationStore = configurationStore
        self.modifyingRules = modifyingRules
        self.stepEnvironment = stepEnvironment
    }

    public static func standard(paths: MacUpPaths) -> ExecutionEngine {
        ExecutionEngine(
            providers: [HomebrewProvider(), NpmProvider(), MiseProvider(), MacOSProvider()],
            history: HistoryStore(paths: paths),
            configurationStore: ConfigurationStore(paths: paths)
        )
    }

    /// The base environment allowlist plus the plan executable's own directory
    /// at the front of `PATH`, so a tool that shells out to its siblings finds
    /// the installation MacUp chose rather than another copy.
    ///
    /// Used only when no provider is loaded for the plan's item, which is
    /// also a reason to refuse to run it; it exists so the fallback is
    /// conservative rather than absent.
    public static let baseStepEnvironment: @Sendable (ExecutionPlan, CheckEnvironment) -> [String: String] = { plan, environment in
        let directories = plan.steps.map { ($0.invocation.executable as NSString).deletingLastPathComponent }
        return EnvironmentPolicy.base.environment(
            from: environment.processEnvironment,
            searchPath: SearchPath.combine(
                directories,
                SearchPath.parse(environment.processEnvironment["PATH"]),
                SearchPath.system
            )
        )
    }

    /// Executes the plans in `report` that `options` permits.
    public func run(
        _ report: PlanReport,
        configuration: LoadedConfiguration,
        options: ExecutionOptions,
        environment: CheckEnvironment
    ) async -> ExecutionReport {
        let startedAt = environment.now()
        var executed: [ExecutedUpdate] = []
        var skipped: [SkippedUpdate] = []
        var seen = Set<PackageID>()
        var cancelled = false
        var anythingFailed = false
        // Set once the rest of the run is abandoned, and why.
        var halted: String?
        // Detection is what tells a provider which installation it is acting
        // on, and the environment a plan runs with depends on it. It is read
        // once per provider per run: asking again between two items of the
        // same provider would only invite them to disagree.
        var detected: [ProviderID: ProviderContext] = [:]

        for planned in report.planned {
            func skip(_ reason: String, decision: PolicyDecision? = nil, inHistory: Bool = true) {
                skipped.append(SkippedUpdate(
                    item: planned.item,
                    displayName: planned.candidate.displayName,
                    currentVersion: planned.candidate.installedVersion?.raw,
                    proposedVersion: planned.candidate.availableVersion.raw,
                    decision: decision ?? planned.decision,
                    reason: reason
                ))
                if inHistory {
                    record(skip: planned, reason: reason, options: options, at: environment.now())
                }
            }

            if Task.isCancelled && halted == nil {
                cancelled = true
                halted = "MacUp stopped before this item because the run was cancelled."
            }
            if let halted {
                skip(halted)
                continue
            }
            guard seen.insert(planned.item).inserted else {
                skip("MacUp will not run the same item twice in one update, so it changed nothing here.")
                continue
            }

            // The decisive policy read: the file, not the copy planning used,
            // because the user may have changed a rule since (CLAUDE.md §2.20).
            let current = configurationStore?.load() ?? configuration
            let decision = PolicyEngine(current).decide(planned.candidate, intent: options.intent)
            switch decision.action {
            case .deny:
                skip(decision.reason, decision: decision)
                continue
            case .confirm:
                guard options.intent == .interactive, options.confirmed.contains(planned.item) else {
                    skip("\(decision.reason) MacUp left it alone because it was not confirmed.", decision: decision)
                    continue
                }
            case .allow:
                break
            }

            if let problem = Self.unrunnable(planned.plan, intent: options.intent) {
                skip(problem, decision: decision)
                continue
            }
            // A failure means MacUp no longer knows the state of the machine as
            // well as it did when the plan was built, so it stops short of the
            // changes that would be hardest to unpick (CLAUDE.md §24, Phase 3).
            if anythingFailed, planned.plan.risk.level == .high || planned.plan.risk.level == .unknown {
                skip(
                    "An earlier update failed, so MacUp stopped before this \(planned.plan.risk.level.displayName) change.",
                    decision: decision
                )
                continue
            }

            if options.dryRun {
                // A dry run is not an attempt, so it leaves no trace in history.
                skip("MacUp would run: \(Self.commandList(planned.plan))", decision: decision, inHistory: false)
                continue
            }

            guard let provider = providers.first(where: { $0.id == planned.provider }) else {
                skip(
                    "MacUp has no \(planned.provider.displayName) provider loaded, so it did not run this plan.",
                    decision: decision
                )
                continue
            }
            if detected[provider.id] == nil {
                detected[provider.id] = await Self.detect(provider, configuration: current, environment: environment)
            }
            let providerContext = detected[provider.id] ?? Self.baseContext(
                provider.id,
                configuration: current,
                environment: environment
            )

            guard providerContext.installation != nil else {
                skip(
                    "MacUp could not find the \(provider.displayName) installation this plan was built against, so it changed nothing.",
                    decision: decision
                )
                continue
            }

            let result = await perform(
                planned.plan,
                environment: environment,
                commandEnvironment: stepEnvironment?(planned.plan, environment)
                    ?? provider.executionEnvironment(context: providerContext)
            )
            var verification: VerificationResult?
            if result.outcome == .succeeded {
                verification = await verify(
                    planned,
                    result: result,
                    provider: provider,
                    providerContext: providerContext,
                    environment: environment
                )
            }
            executed.append(ExecutedUpdate(
                item: planned.item,
                displayName: planned.candidate.displayName,
                plan: planned.plan,
                result: result,
                verification: verification
            ))
            record(attempt: planned, result: result, verification: verification, options: options)

            switch result.outcome {
            case .cancelled:
                cancelled = true
                halted = "MacUp stopped before this item because the run was cancelled."
            case .failed, .timedOut:
                anythingFailed = true
                if options.stopOnFailure {
                    halted = "MacUp stopped after \(planned.candidate.displayName) failed."
                }
            case .succeeded, .skipped:
                break
            }
        }

        return ExecutionReport(
            origin: options.origin,
            dryRun: options.dryRun,
            startedAt: startedAt,
            finishedAt: environment.now(),
            cancelled: cancelled,
            executed: executed,
            skipped: skipped + report.skipped
        )
    }

    // MARK: Running one plan

    /// Runs a plan's steps in order, stopping at the first one that does not
    /// succeed. Nothing after a failed step runs: the later steps were written
    /// assuming the earlier ones worked.
    ///
    /// Steps run on the caller's task, so a cancelled `macup update` reaches
    /// the running command itself — the runner signals the child rather than
    /// leaving it to finish unwatched — and the loop stops before the next one.
    private func perform(
        _ plan: ExecutionPlan,
        environment: CheckEnvironment,
        commandEnvironment: [String: String]
    ) async -> ExecutionResult {
        let startedAt = environment.now()
        let runner = ExecutionGuard(base: environment.runner, plan: plan, modifyingRules: modifyingRules)
        let redactor = Redactor()
        var steps: [ExecutionResult.StepResult] = []

        func finish(_ outcome: ExecutionResult.Outcome, error: MacUpError? = nil) -> ExecutionResult {
            ExecutionResult(
                planID: plan.id,
                item: plan.item,
                outcome: outcome,
                startedAt: startedAt,
                finishedAt: environment.now(),
                steps: steps,
                error: error
            )
        }

        for step in plan.steps {
            if Task.isCancelled {
                return finish(.cancelled, error: MacUpError(
                    .cancelled,
                    "MacUp stopped before running the rest of this update."
                ))
            }
            let display = redactor.redact(step.invocation.displayString)
            // The home directory, never the directory MacUp happens to have
            // been started in: a tool that reads project-local configuration
            // must not pick up whichever project the user's shell was sitting
            // in (CLAUDE.md §9, mise).
            let request = CommandRequest(
                executable: URL(fileURLWithPath: step.invocation.executable),
                arguments: step.invocation.arguments,
                environment: commandEnvironment,
                workingDirectory: URL(fileURLWithPath: environment.homeDirectory, isDirectory: true),
                timeout: .seconds(step.timeoutSeconds),
                effect: step.effect
            )
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let result = try await runner.run(request)
                let excerpt = TextExcerpt.tail(of: result.standardErrorText, redactor: redactor)
                    ?? TextExcerpt.tail(of: result.standardOutputText, maxLines: 6, redactor: redactor)
                steps.append(ExecutionResult.StepResult(
                    command: display,
                    exitStatus: result.exitStatus,
                    durationSeconds: result.duration,
                    errorExcerpt: result.succeeded ? nil : excerpt
                ))
                guard result.succeeded else {
                    return finish(.failed, error: MacUpError.commandFailed(
                        result,
                        "\(step.summary) did not succeed.",
                        recoverySuggestion: "Run the command yourself to see the provider's own output. MacUp changed nothing further for this item.",
                        redactor: redactor
                    ))
                }
            } catch {
                let failure = MacUpError.wrapping(error, context: step.summary)
                steps.append(ExecutionResult.StepResult(
                    command: display,
                    exitStatus: failure.exitStatus,
                    durationSeconds: Self.seconds(clock.now - started),
                    errorExcerpt: failure.detail
                ))
                switch failure.kind {
                case .timeout: return finish(.timedOut, error: failure)
                case .cancelled: return finish(.cancelled, error: failure)
                default: return finish(.failed, error: failure)
                }
            }
        }
        return finish(.succeeded)
    }

    /// Why MacUp will not run this plan, or `nil` when it will.
    ///
    /// Fails closed on a plan it cannot carry out faithfully rather than
    /// running part of it (CLAUDE.md §2.23), and an unattended run additionally
    /// refuses anything that would need a person at the Mac: nobody is there to
    /// answer an authorization prompt or to agree to a restart.
    static func unrunnable(_ plan: ExecutionPlan, intent: PolicyIntent) -> String? {
        if plan.steps.isEmpty {
            return "MacUp has no command for this item, so it changed nothing."
        }
        if let step = plan.steps.first(where: { !($0.timeoutSeconds.isFinite && $0.timeoutSeconds > 0) }) {
            return "MacUp will not run \"\(TerminalText.sanitize(step.summary))\" because the plan gives it no usable time limit."
        }
        guard intent == .unattended else { return nil }
        if plan.steps.contains(where: \.mayRequirePrivilege) {
            return "This change may ask for an administrator password, and a scheduled run has nobody to ask."
        }
        if plan.mayRequireRestart {
            return "This change may require a restart, which MacUp never does on a schedule."
        }
        return nil
    }

    /// The plan's commands, for saying what a dry run would have done.
    static func commandList(_ plan: ExecutionPlan) -> String {
        let redactor = Redactor()
        return plan.steps.map { redactor.redact($0.invocation.displayString) }.joined(separator: "\n")
    }

    // MARK: Verification

    /// Asks the owning provider to confirm the new version.
    ///
    /// An update MacUp could not confirm is reported as unconfirmed, never as
    /// confirmed: claiming otherwise would make the one field a user checks
    /// afterwards worthless (CLAUDE.md §25).
    /// Locates the provider again before MacUp changes anything with it.
    ///
    /// The environment a plan needs depends on which installation it is
    /// acting on — Homebrew's own variables, the Node that owns a global npm
    /// package — and only the provider can say. Detection reads: its runner
    /// allows nothing but the read-only allowlist, so looking the provider up
    /// cannot change it.
    private static func detect(
        _ provider: any UpdateProvider,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> ProviderContext {
        var context = baseContext(provider.id, configuration: configuration, environment: environment)
        context.runner = ReadOnlyCommandGuard(base: environment.runner, rules: CommandAllowlist.readOnlyCheck)
        context.installation = await provider.detect(context: context).installation
        return context
    }

    private static func baseContext(
        _ provider: ProviderID,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) -> ProviderContext {
        ProviderContext(
            runner: environment.runner,
            fileSystem: environment.fileSystem,
            environment: environment.processEnvironment,
            homeDirectory: PathDisplay.standardized(environment.homeDirectory),
            searchPath: SearchPath.parse(environment.processEnvironment["PATH"]),
            settings: configuration.configuration.settings(for: provider),
            system: environment.system,
            now: environment.now
        )
    }

    private func verify(
        _ planned: PlannedUpdate,
        result: ExecutionResult,
        provider: any UpdateProvider,
        providerContext: ProviderContext,
        environment: CheckEnvironment
    ) async -> VerificationResult {
        let expected = planned.plan.proposedVersion.raw
        // Verification reads; it never changes anything. The guard is given no
        // modifying rules at all, and the read-only allowlist on top of the
        // plan's own verification commands so the provider can locate itself
        // again first. The installation is the one detection already chose, so
        // the version MacUp reads back comes from the copy it just changed.
        var context = providerContext
        context.runner = ExecutionGuard(
            base: environment.runner,
            plan: planned.plan,
            modifyingRules: [],
            readOnlyRules: CommandAllowlist.readOnlyCheck
        )
        do {
            return try await provider.verify(result, for: planned.candidate, context: context)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Confirming \(planned.candidate.displayName)")
            return VerificationResult(
                item: planned.item,
                outcome: failure.kind == .unsupported ? .notPerformed : .failed,
                expectedVersion: expected,
                observedVersion: nil,
                message: failure.message
            )
        }
    }

    // MARK: History

    private func record(
        attempt planned: PlannedUpdate,
        result: ExecutionResult,
        verification: VerificationResult?,
        options: ExecutionOptions
    ) {
        append(HistoryEntry(
            timestamp: result.finishedAt,
            origin: options.origin,
            item: planned.item,
            versionBefore: planned.plan.currentVersion?.raw,
            versionTarget: planned.plan.proposedVersion.raw,
            versionAfter: verification?.observedVersion,
            command: result.steps.isEmpty ? nil : result.steps.map(\.command).joined(separator: "\n"),
            outcome: result.outcome,
            verification: verification?.outcome,
            errorSummary: result.error?.message,
            durationSeconds: result.finishedAt.timeIntervalSince(result.startedAt)
        ))
    }

    /// A skip is recorded too: an item MacUp decided not to change is part of
    /// what it did, and the reason is the useful half (CLAUDE.md §16).
    private func record(skip planned: PlannedUpdate, reason: String, options: ExecutionOptions, at timestamp: Date) {
        append(HistoryEntry(
            timestamp: timestamp,
            origin: options.origin,
            item: planned.item,
            versionBefore: planned.plan.currentVersion?.raw,
            versionTarget: planned.plan.proposedVersion.raw,
            versionAfter: nil,
            command: nil,
            outcome: .skipped,
            verification: nil,
            skipReason: reason
        ))
    }

    /// History that could not be written is reported to the system log and
    /// does not stop the run: refusing to update because a log file is
    /// unwritable would be a worse answer than an incomplete log.
    private func append(_ entry: HistoryEntry) {
        guard let history else { return }
        do {
            try history.append(entry)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Recording an update in MacUp's history")
            Log.execution.error("Could not record an update in history: \(failure.message, privacy: .public)")
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
