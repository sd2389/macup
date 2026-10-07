import Foundation

/// What applying one of Doctor's fixes did.
public struct DoctorFixResult: Sendable, Hashable, Codable {
    public var findingID: String
    public var summary: String
    /// What changed, one line each. Empty when nothing needed changing.
    public var changes: [String]
    /// Why nothing was changed, when nothing was.
    public var problem: String?
    public var dryRun: Bool

    public init(findingID: String, summary: String, changes: [String] = [], problem: String? = nil, dryRun: Bool = false) {
        self.findingID = findingID
        self.summary = summary
        self.changes = changes
        self.problem = problem
        self.dryRun = dryRun
    }

    public var succeeded: Bool { problem == nil }
}

/// Applies one reviewed Doctor fix.
///
/// Doctor explains; it does not go around repairing things (CLAUDE.md §13).
/// A fix exists only where the thing to change belongs to MacUp — a rule in
/// its own configuration file, or the launchd agent it installed — so no fix
/// here runs a package manager, touches a package, or needs an administrator
/// (ADR-024).
///
/// Every fix is asked for by the person, one at a time, and re-checks what it
/// assumed immediately before it acts: a rule it would drop has to still be
/// there, and the schedule it would install or remove has to still be what
/// the configuration says. Anything else is reported, not forced
/// (CLAUDE.md §2.20, §2.23).
public struct DoctorFixer: Sendable {
    public var store: ConfigurationStore
    /// Built when a fix needs it, so a Mac that never schedules anything
    /// never constructs one.
    public var makeScheduler: @Sendable () throws -> Scheduler

    public init(store: ConfigurationStore, makeScheduler: @escaping @Sendable () throws -> Scheduler) {
        self.store = store
        self.makeScheduler = makeScheduler
    }

    public func apply(_ finding: DiagnosticFinding, dryRun: Bool = false) async -> DoctorFixResult {
        guard let fix = finding.fix else {
            return DoctorFixResult(
                findingID: finding.id,
                summary: finding.title,
                problem: "MacUp has no fix for this. The report says what to do by hand."
            )
        }
        func result(_ changes: [String], problem: String? = nil) -> DoctorFixResult {
            DoctorFixResult(
                findingID: finding.id,
                summary: fix.summary,
                changes: changes,
                problem: problem,
                dryRun: dryRun
            )
        }

        let loaded = store.load()
        guard loaded.allowsAutomaticModification else {
            return result([], problem: "MacUp will not change a configuration it cannot read. `macup config show` lists what is wrong.")
        }

        switch fix.action {
        case .clearItemRules(let keys):
            return await clearItemRules(keys, loaded: loaded, dryRun: dryRun, result: result)
        case .clearProviderPath(let provider):
            return clearProviderPath(provider, loaded: loaded, dryRun: dryRun, result: result)
        case .installScheduleAgent:
            return await installAgent(loaded: loaded, dryRun: dryRun, result: result)
        case .removeScheduleAgent:
            return await removeAgent(loaded: loaded, dryRun: dryRun, result: result)
        }
    }

    // MARK: The fixes

    private func clearItemRules(
        _ keys: [String],
        loaded: LoadedConfiguration,
        dryRun: Bool,
        result: ([String], String?) -> DoctorFixResult
    ) async -> DoctorFixResult {
        // Only the keys the finding named, and only those still in the file:
        // a rule added since the report was made is not this fix's to drop.
        let present = keys.filter { loaded.configuration.items[$0] != nil }
        guard !present.isEmpty else {
            return result([], "Those rules are not in the configuration any more, so there is nothing to drop.")
        }
        if dryRun { return result(present.map { "Would remove the rule for \(TerminalText.sanitize($0))." }, nil) }

        var changes: [String] = []
        do {
            let editor = PolicyEditor(store: store)
            for key in present {
                let change = try editor.clearPolicy(forItem: key)
                changes.append(change.summary)
            }
        } catch {
            return result(changes, MacUpError.wrapping(error, context: "Dropping a rule").message)
        }
        return result(changes, nil)
    }

    private func clearProviderPath(
        _ provider: ProviderID,
        loaded: LoadedConfiguration,
        dryRun: Bool,
        result: ([String], String?) -> DoctorFixResult
    ) -> DoctorFixResult {
        guard let path = loaded.configuration.settings(for: provider).executablePath else {
            return result([], "There is no configured path for \(provider.displayName) any more.")
        }
        if dryRun {
            return result(["Would remove providers.\(provider.rawValue).executablePath (\(TerminalText.sanitize(path)))."], nil)
        }
        do {
            let change = try PolicyEditor(store: store).clearProviderExecutablePath(for: provider)
            return result([change.summary], nil)
        } catch {
            return result([], MacUpError.wrapping(error, context: "Clearing a configured path").message)
        }
    }

    private func installAgent(
        loaded: LoadedConfiguration,
        dryRun: Bool,
        result: ([String], String?) -> DoctorFixResult
    ) async -> DoctorFixResult {
        guard loaded.configuration.schedule.enabled else {
            return result([], "The configuration no longer asks for a scheduled run, so MacUp installed nothing.")
        }
        do {
            let scheduler = try makeScheduler()
            if dryRun {
                let agent = try LaunchAgent.scheduledCheck(
                    settings: loaded.configuration.schedule,
                    executable: scheduler.executable,
                    paths: scheduler.paths
                )
                return result([
                    "Would write \(scheduler.agentPath) and load it.",
                    "It would run: \(agent.invocation.displayString)",
                ], nil)
            }
            let agent = try await scheduler.install(loaded.configuration.schedule)
            return result([
                "Installed \(scheduler.agentPath) and loaded it with launchd.",
                "It runs: \(agent.invocation.displayString)",
            ], nil)
        } catch {
            return result([], MacUpError.wrapping(error, context: "Installing the scheduled run").message)
        }
    }

    private func removeAgent(
        loaded: LoadedConfiguration,
        dryRun: Bool,
        result: ([String], String?) -> DoctorFixResult
    ) async -> DoctorFixResult {
        guard !loaded.configuration.schedule.enabled else {
            return result([], "The configuration asks for a scheduled run again, so MacUp left the agent in place.")
        }
        do {
            let scheduler = try makeScheduler()
            if dryRun {
                return result(["Would unload \(LaunchAgent.label) and delete \(scheduler.agentPath)."], nil)
            }
            let removedSomething = try await scheduler.remove()
            // Said only after looking: "removed" has to mean the file is
            // gone, not that MacUp asked for it to be.
            if scheduler.fileSystem.fileExists(atPath: scheduler.agentPath) {
                return result(
                    [],
                    "MacUp asked launchd to unload \(LaunchAgent.label), but \(scheduler.agentPath) is still there."
                )
            }
            return result([
                removedSomething
                    ? "Unloaded \(LaunchAgent.label) and removed \(scheduler.agentPath)."
                    : "There was nothing left to remove.",
            ], nil)
        } catch {
            return result([], MacUpError.wrapping(error, context: "Removing the scheduled run").message)
        }
    }
}
