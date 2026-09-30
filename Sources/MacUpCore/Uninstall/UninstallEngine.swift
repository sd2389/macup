import Foundation

/// One thing MacUp read back after an uninstall, and whether it held.
public struct UninstallCheck: Sendable, Hashable, Codable {
    public var summary: String
    /// `nil` when MacUp could not find out.
    public var passed: Bool?
    public var detail: String?

    public init(summary: String, passed: Bool?, detail: String? = nil) {
        self.summary = summary
        self.passed = passed
        self.detail = detail
    }
}

/// What one of MacUp's own uninstall steps did.
public struct SelfUninstallActionResult: Sendable, Hashable, Codable {
    public var action: SelfUninstallAction
    public var succeeded: Bool
    public var message: String

    public init(action: SelfUninstallAction, succeeded: Bool, message: String) {
        self.action = action
        self.succeeded = succeeded
        self.message = message
    }
}

/// A leftover the reader left unticked, and so was not touched.
public struct KeptItem: Sendable, Hashable, Codable {
    public var path: String
    public var category: LeftoverCategory
    public var sizeBytes: Int64?

    public init(path: String, category: LeftoverCategory, sizeBytes: Int64?) {
        self.path = path
        self.category = category
        self.sizeBytes = sizeBytes
    }
}

/// Who asked for an uninstall.
public struct UninstallOptions: Sendable, Hashable {
    public var origin: ExecutionOrigin
    /// Uninstalling needs someone there: an unattended run is refused.
    public var intent: PolicyIntent

    public init(origin: ExecutionOrigin, intent: PolicyIntent = .interactive) {
        self.origin = origin
        self.intent = intent
    }
}

/// What is happening, for a screen or a terminal someone is watching.
public enum UninstallProgress: Sendable, Hashable {
    case runningCommand(String)
    case running(SelfUninstallAction)
    case removing(path: String, index: Int, total: Int)
    case checking
}

/// What an uninstall did: what ran, what was removed and how, what was left
/// and why, and what MacUp found when it looked afterwards.
///
/// Schema version 1 (`"kind": "uninstall"`).
public struct UninstallReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public enum Outcome: String, Sendable, Hashable, Codable {
        /// Everything ticked is gone, and MacUp confirmed it.
        case uninstalled
        /// It ran, but something was skipped, failed, or could not be
        /// confirmed.
        case incomplete
        /// A package manager's command failed, so MacUp removed nothing
        /// further.
        case failed
        /// MacUp would not start, for the reasons given. Nothing changed.
        case refused
        /// Stopped before it finished.
        case cancelled
    }

    public struct Summary: Sendable, Hashable, Codable {
        public var removed: Int
        public var removedBytes: Int64
        public var skipped: Int
        public var failed: Int
        public var kept: Int
        public var keptData: Int
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var outcome: Outcome
    public var subject: UninstallSubject
    public var mode: RemovalMode
    public var origin: ExecutionOrigin
    public var startedAt: Date
    public var finishedAt: Date
    /// Why MacUp would not start, for ``Outcome/refused``.
    public var refusals: [String]
    public var actions: [SelfUninstallActionResult]
    /// The package manager's commands that ran, redacted.
    public var commands: [ExecutionResult.StepResult]
    public var removals: [RemovalOutcome]
    /// Ticked items MacUp did not get to, because it stopped first.
    public var notAttempted: [String]
    public var kept: [KeptItem]
    public var checks: [UninstallCheck]
    public var error: MacUpError?
    public var summary: Summary

    public init(
        outcome: Outcome,
        subject: UninstallSubject,
        mode: RemovalMode,
        origin: ExecutionOrigin,
        startedAt: Date,
        finishedAt: Date,
        refusals: [String] = [],
        actions: [SelfUninstallActionResult] = [],
        commands: [ExecutionResult.StepResult] = [],
        removals: [RemovalOutcome] = [],
        notAttempted: [String] = [],
        kept: [KeptItem] = [],
        checks: [UninstallCheck] = [],
        error: MacUpError? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "uninstall"
        self.macupVersion = MacUp.version
        self.outcome = outcome
        self.subject = subject
        self.mode = mode
        self.origin = origin
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.refusals = refusals
        self.actions = actions
        self.commands = commands
        self.removals = removals
        self.notAttempted = notAttempted
        self.kept = kept
        self.checks = checks
        self.error = error
        let removed = removals.filter { $0.status == .removed }
        self.summary = Summary(
            removed: removed.count,
            removedBytes: removed.reduce(0) { $0 + ($1.sizeBytes ?? 0) },
            skipped: removals.filter { $0.status == .skipped }.count,
            failed: removals.filter { $0.status == .failed }.count,
            kept: kept.count,
            keptData: kept.filter { $0.category.isData }.count
        )
    }

    /// Whether everything MacUp read back afterwards held.
    public var isConfirmed: Bool { !checks.isEmpty && checks.allSatisfy { $0.passed == true } }
}

/// Carries out a confirmed uninstall plan, and nothing else.
///
/// Immediately before anything runs, it checks again what may have changed
/// since the plan was made: that someone is there (a scheduled run can never
/// uninstall), that the configuration can still be read, that the package
/// manager is still turned on, that nothing stands in the way, and that the
/// app is not open. Then, in order:
///
/// 1. MacUp's own steps, when MacUp is what is being uninstalled.
/// 2. The package manager's commands, exactly as planned, through an
///    ``ExecutionGuard`` that accepts only those commands and only the
///    uninstall shapes in ``ModifyingCommandRules/uninstall``. A command that
///    fails stops everything after it: nothing is removed from under a
///    package manager that did not finish.
/// 3. The ticked files, one at a time, through the ``FileRemoving`` it is
///    given — ``GuardedFileRemover`` everywhere but tests. An app's bundle
///    goes first, and if it cannot be removed nothing else is; MacUp's own
///    state folder and app go last.
/// 4. A read-back of what should now be gone.
///
/// Every attempt is recorded in history, including a refusal.
public struct UninstallEngine: Sendable {
    public var scanner: UninstallScanner
    public var history: HistoryStore?
    public var configurationStore: ConfigurationStore?
    public var modifyingRules: [ModifyingCommandRule]

    public init(
        scanner: UninstallScanner = UninstallScanner(),
        history: HistoryStore? = nil,
        configurationStore: ConfigurationStore? = nil,
        modifyingRules: [ModifyingCommandRule] = ModifyingCommandRules.uninstall
    ) {
        self.scanner = scanner
        self.history = history
        self.configurationStore = configurationStore
        self.modifyingRules = modifyingRules
    }

    public static func standard(paths: MacUpPaths) -> UninstallEngine {
        UninstallEngine(history: HistoryStore(paths: paths), configurationStore: ConfigurationStore(paths: paths))
    }

    public func run(
        _ plan: UninstallPlan,
        selection: Set<String>,
        mode: RemovalMode,
        options: UninstallOptions,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        uninstall: UninstallEnvironment,
        scheduler: Scheduler? = nil,
        progress: (@Sendable (UninstallProgress) -> Void)? = nil
    ) async -> UninstallReport {
        let startedAt = environment.now()
        let selected = plan.selectedRemovals(selection)
        let chosen = Set(selected.map(\.path))
        let kept = plan.removals.filter { !chosen.contains($0.path) }
            .map { KeptItem(path: $0.path, category: $0.category, sizeBytes: $0.sizeBytes) }

        func finish(
            _ outcome: UninstallReport.Outcome,
            refusals: [String] = [],
            actions: [SelfUninstallActionResult] = [],
            commands: [ExecutionResult.StepResult] = [],
            removals: [RemovalOutcome] = [],
            notAttempted: [String] = [],
            checks: [UninstallCheck] = [],
            error: MacUpError? = nil
        ) -> UninstallReport {
            UninstallReport(
                outcome: outcome,
                subject: plan.subject,
                mode: mode,
                origin: options.origin,
                startedAt: startedAt,
                finishedAt: environment.now(),
                refusals: refusals,
                actions: actions,
                commands: commands,
                removals: removals,
                notAttempted: notAttempted,
                kept: outcome == .refused ? [] : kept,
                checks: checks,
                error: error
            )
        }

        // MARK: Checked again, now

        let refusals = await refusalsNow(plan, options: options, configuration: configuration, uninstall: uninstall)
        if !refusals.isEmpty {
            let report = finish(.refused, refusals: refusals)
            record(report, plan: plan)
            return report
        }
        if Task.isCancelled {
            let report = finish(.cancelled, notAttempted: selected.map(\.path))
            record(report, plan: plan)
            return report
        }

        // MARK: 1. MacUp's own steps

        var actions: [SelfUninstallActionResult] = []
        for action in plan.actions {
            progress?(.running(action))
            actions.append(await perform(action, scheduler: scheduler, uninstall: uninstall))
        }

        // MARK: 2. The package manager

        var commands: [ExecutionResult.StepResult] = []
        var context: ProviderContext?
        if !plan.steps.isEmpty {
            let outcome = await runSteps(plan, configuration: configuration, environment: environment, progress: progress)
            commands = outcome.commands
            context = outcome.context
            if let failure = outcome.failure {
                let checks = await confirm(plan, removals: [], context: context, uninstall: uninstall, progress: progress)
                let report = finish(
                    failure.kind == .cancelled ? .cancelled : .failed,
                    actions: actions,
                    commands: commands,
                    notAttempted: selected.map(\.path),
                    checks: checks,
                    error: failure
                )
                record(report, plan: plan)
                return report
            }
        }

        // MARK: 3. The files

        let boundary = uninstall.boundary(homebrewPrefix: plan.homebrewPrefix, forMacUp: plan.subject.kind == .macUp)
        var removals: [RemovalOutcome] = []
        var notAttempted: [String] = []
        let last = selected.filter { $0.role == .macUpState || (plan.subject.kind == .macUp && $0.role == .bundle) }
        let first = selected.filter { removal in !last.contains(removal) }
        var stopped = false
        func remove(_ batch: [PlannedRemoval], offset: Int) {
            for (index, removal) in batch.enumerated() {
                if stopped || Task.isCancelled {
                    stopped = true
                    notAttempted.append(removal.path)
                    continue
                }
                progress?(.removing(path: removal.path, index: offset + index + 1, total: selected.count))
                let outcome = uninstall.remover.remove(removal, mode: mode, within: boundary)
                removals.append(outcome)
                // An app that is still there keeps what it left: removing an
                // installed app's settings from under it helps nobody.
                if removal.role == .bundle, plan.subject.kind != .macUp, outcome.status != .removed, outcome.status != .alreadyGone {
                    stopped = true
                }
            }
        }
        remove(first, offset: 0)

        // MARK: 4. Confirming, and recording

        let cancelled = Task.isCancelled
        var checks = await confirm(plan, removals: removals, context: context, uninstall: uninstall, progress: progress)
        checks += actions.map { UninstallCheck(summary: $0.action.summary, passed: $0.succeeded, detail: $0.succeeded ? nil : $0.message) }
        func outcome() -> UninstallReport.Outcome {
            if cancelled || !notAttempted.isEmpty && Task.isCancelled { return .cancelled }
            let clean = removals.allSatisfy { $0.status == .removed || $0.status == .alreadyGone } && notAttempted.isEmpty
            return clean && checks.allSatisfy { $0.passed == true } ? .uninstalled : .incomplete
        }
        // MacUp's own history is in the state folder, which goes after the
        // record is made.
        if !last.isEmpty && !stopped {
            let written = finish(outcome(), actions: actions, commands: commands, removals: removals, notAttempted: notAttempted, checks: checks)
            record(written, plan: plan, removedAfterRecord: last.map(\.path))
            remove(last, offset: first.count)
            checks = await confirm(plan, removals: removals, context: context, uninstall: uninstall, progress: nil)
                + actions.map { UninstallCheck(summary: $0.action.summary, passed: $0.succeeded, detail: $0.succeeded ? nil : $0.message) }
            return finish(outcome(), actions: actions, commands: commands, removals: removals, notAttempted: notAttempted, checks: checks)
        }
        notAttempted += last.filter { removal in !removals.contains { $0.path == removal.path } }.map(\.path)
        let report = finish(outcome(), actions: actions, commands: commands, removals: removals, notAttempted: notAttempted, checks: checks)
        record(report, plan: plan)
        return report
    }

    // MARK: Refusing

    /// Every reason not to start, checked immediately before anything runs.
    func refusalsNow(
        _ plan: UninstallPlan,
        options: UninstallOptions,
        configuration: LoadedConfiguration,
        uninstall: UninstallEnvironment
    ) async -> [String] {
        guard options.intent == .interactive, options.origin != .scheduled else {
            return ["MacUp never uninstalls anything on a schedule or without someone there to confirm it."]
        }
        let current = configurationStore?.load() ?? configuration
        if current.hasErrors {
            return ["MacUp will not change anything while it cannot read its configuration. `macup config show` lists what is wrong."]
        }
        // Whether the app is open is asked again below rather than taken from
        // the plan, so quitting it after reading the plan is enough.
        var refusals = plan.blockers.filter { $0.kind != .appRunning }.map(\.message)
        if let provider = plan.runner, !plan.steps.isEmpty, !current.configuration.settings(for: provider).enabled {
            refusals.append("\(provider.displayName) is turned off in MacUp's configuration, so MacUp will not run it.")
        }
        // An app can be opened between reviewing the plan and confirming it.
        var bundles: [String] = []
        if let path = plan.subject.bundlePath, plan.subject.kind != .macUp { bundles.append(path) }
        if plan.subject.kind == .macUp {
            bundles += plan.removals.filter { $0.role == .bundle && $0.path != uninstall.currentAppBundle }.map(\.path)
        }
        for path in bundles where FileTree.exists(path) {
            let identifier = plan.subject.kind == .macUp ? nil : plan.subject.bundleIdentifier
            if !(await uninstall.runningApplications.running(bundleIdentifier: identifier, bundlePath: path)).isEmpty {
                let name = plan.subject.kind == .macUp ? "the MacUp app" : plan.subject.name
                let message = "Quit \(name) first."
                if !refusals.contains(message) { refusals.append(message) }
            }
        }
        return refusals
    }

    // MARK: MacUp's own steps

    private func perform(
        _ action: SelfUninstallAction,
        scheduler: Scheduler?,
        uninstall: UninstallEnvironment
    ) async -> SelfUninstallActionResult {
        switch action.kind {
        case .removeScheduledCheck:
            guard let scheduler else {
                return SelfUninstallActionResult(action: action, succeeded: false, message: "MacUp had no way to reach launchd here.")
            }
            do {
                _ = try await scheduler.remove()
                let gone = !FileTree.exists(scheduler.agentPath)
                return SelfUninstallActionResult(
                    action: action,
                    succeeded: gone,
                    message: gone ? "The scheduled check is off and its launch agent is gone." : "The launch agent is still there."
                )
            } catch {
                return SelfUninstallActionResult(
                    action: action,
                    succeeded: false,
                    message: MacUpError.wrapping(error, context: "Removing the scheduled check").message
                )
            }
        case .deleteKeychainItem:
            do {
                _ = try uninstall.keychain.deleteLeftoverItem()
                let gone = !uninstall.keychain.hasLeftoverItem()
                return SelfUninstallActionResult(
                    action: action,
                    succeeded: gone,
                    message: gone ? "The Keychain item is gone." : "The Keychain item is still there."
                )
            } catch {
                return SelfUninstallActionResult(
                    action: action,
                    succeeded: false,
                    message: MacUpError.wrapping(error, context: "Deleting the Keychain item").message
                )
            }
        }
    }

    // MARK: The package manager's commands

    private struct StepsOutcome {
        var commands: [ExecutionResult.StepResult]
        var context: ProviderContext?
        var failure: MacUpError?
    }

    private func runSteps(
        _ plan: UninstallPlan,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        progress: (@Sendable (UninstallProgress) -> Void)?
    ) async -> StepsOutcome {
        guard let providerID = plan.runner, let provider = scanner.providers.first(where: { $0.id == providerID }) else {
            return StepsOutcome(commands: [], failure: MacUpError(.providerUnavailable, "MacUp has no provider to run these commands with, so it changed nothing."))
        }
        // Found again, read-only, for the environment its commands need.
        let (found, _) = await scanner.detect(provider, configuration: configuration, environment: environment, log: CommandLog())
        guard var context = found, let installation = context.installation,
              plan.steps.allSatisfy({ $0.invocation.executable == installation.executable.path })
        else {
            return StepsOutcome(commands: [], failure: MacUpError(
                .providerUnavailable,
                "MacUp could not find the \(provider.displayName) installation this plan was built against, so it changed nothing."
            ))
        }
        let commandEnvironment: [String: String]
        switch provider {
        case let homebrew as HomebrewProvider: commandEnvironment = homebrew.uninstallEnvironment(context: context)
        case let npm as NpmProvider: commandEnvironment = npm.uninstallEnvironment(context: context)
        case let mise as MiseProvider: commandEnvironment = mise.uninstallEnvironment(context: context)
        default: commandEnvironment = provider.executionEnvironment(context: context)
        }
        let runner = ExecutionGuard(
            base: environment.runner,
            steps: plan.steps,
            verification: plan.verification,
            modifyingRules: modifyingRules
        )
        let redactor = Redactor()
        var commands: [ExecutionResult.StepResult] = []
        for step in plan.steps {
            if Task.isCancelled {
                return StepsOutcome(commands: commands, context: context, failure: MacUpError(.cancelled, "MacUp stopped before running the rest of this uninstall."))
            }
            let display = redactor.redact(step.invocation.displayString)
            progress?(.runningCommand(display))
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let result = try await runner.run(CommandRequest(
                    executable: URL(fileURLWithPath: step.invocation.executable),
                    arguments: step.invocation.arguments,
                    environment: commandEnvironment,
                    workingDirectory: URL(fileURLWithPath: environment.homeDirectory, isDirectory: true),
                    timeout: .seconds(step.timeoutSeconds),
                    effect: step.effect
                ))
                let excerpt = TextExcerpt.tail(of: result.standardErrorText, redactor: redactor)
                    ?? TextExcerpt.tail(of: result.standardOutputText, maxLines: 6, redactor: redactor)
                commands.append(ExecutionResult.StepResult(
                    command: display,
                    exitStatus: result.exitStatus,
                    durationSeconds: result.duration,
                    errorExcerpt: result.succeeded ? nil : excerpt
                ))
                guard result.succeeded else {
                    return StepsOutcome(commands: commands, context: context, failure: MacUpError.commandFailed(
                        result,
                        "\(step.summary) did not succeed, so MacUp removed nothing else.",
                        recoverySuggestion: "Run the command yourself to see \(provider.displayName)'s own output.",
                        redactor: redactor
                    ))
                }
            } catch {
                let failure = MacUpError.wrapping(error, context: step.summary)
                let elapsed = clock.now - started
                commands.append(ExecutionResult.StepResult(
                    command: display,
                    exitStatus: failure.exitStatus,
                    durationSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                    errorExcerpt: failure.detail ?? failure.message
                ))
                return StepsOutcome(commands: commands, context: context, failure: failure)
            }
        }
        // Reading back only: the check's allowlist, nothing that changes.
        context.runner = ReadOnlyCommandGuard(base: environment.runner, rules: UninstallScanner.readOnlyRules)
        return StepsOutcome(commands: commands, context: context)
    }

    // MARK: Confirming

    private func confirm(
        _ plan: UninstallPlan,
        removals: [RemovalOutcome],
        context: ProviderContext?,
        uninstall: UninstallEnvironment,
        progress: (@Sendable (UninstallProgress) -> Void)?
    ) async -> [UninstallCheck] {
        progress?(.checking)
        var checks: [UninstallCheck] = []
        if let context, let item = plan.subject.packageID, plan.subject.kind != .macUp {
            switch plan.subject.kind {
            case .formula, .cask:
                checks.append(await scanner.homebrew.confirmUninstalled(item, context: context))
            case .npmPackage:
                checks.append(await scanner.npm.confirmUninstalled(item, context: context))
            case .miseRuntime:
                if let version = plan.subject.version {
                    checks.append(await scanner.mise.confirmUninstalled(tool: item, version: version, context: context))
                }
            case .app, .macUp:
                break
            }
        }
        if let bundle = plan.subject.bundlePath, plan.subject.kind == .app || plan.subject.kind == .cask {
            let gone = !FileTree.exists(bundle)
            checks.append(UninstallCheck(
                summary: "\(plan.subject.name) is gone from \(PathDisplay.abbreviatingHome((bundle as NSString).deletingLastPathComponent, homeDirectory: uninstall.homeDirectory))",
                passed: gone,
                detail: gone ? nil : "It is still at \(PathDisplay.abbreviatingHome(bundle, homeDirectory: uninstall.homeDirectory))."
            ))
        }
        if !removals.isEmpty {
            let left = removals.filter { $0.status != .removed && $0.status != .alreadyGone }
            checks.append(UninstallCheck(
                summary: "Every item MacUp removed is gone",
                passed: left.isEmpty,
                detail: left.isEmpty ? nil : "\(left.count) of \(removals.count) were not removed."
            ))
        }
        return checks
    }

    // MARK: History

    /// - Parameter removedAfterRecord: what MacUp removes once this is
    ///   written — its own history among it — which the record says rather
    ///   than claims.
    private func record(_ report: UninstallReport, plan: UninstallPlan, removedAfterRecord: [String] = []) {
        guard let history else { return }
        do {
            try history.append(HistoryEntry(uninstall: report, plan: plan, removedAfterRecord: removedAfterRecord))
        } catch {
            let failure = MacUpError.wrapping(error, context: "Recording an uninstall in MacUp's history")
            Log.execution.error("Could not record an uninstall in history: \(failure.message, privacy: .public)")
        }
    }
}
