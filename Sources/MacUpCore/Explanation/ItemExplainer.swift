import Foundation

/// Gathers everything MacUp knows about one item into an ``ItemExplanation``.
///
/// Nothing here is new knowledge. The versions, risk, notes and ownership are
/// the check's; the decision is ``PolicyEngine``'s; the plan, or the reason
/// there is none, is ``UpdatePlanner``'s; the attempts are ``HistoryStore``'s.
/// Putting them side by side is the whole job, so `macup explain` and the
/// app can never disagree with `macup check`, `macup plan`, or each other.
///
/// It changes nothing. The check runs behind ``ReadOnlyCommandGuard``, the
/// planner's runner refuses anything that is not read-only, and history is
/// only read.
public struct ItemExplainer: Sendable {
    /// How many of an item's history entries an explanation shows.
    public static let historyLimit = 5

    public var checkEngine: CheckEngine
    public var planner: UpdatePlanner
    public var historyLimit: Int

    public init(checkEngine: CheckEngine, planner: UpdatePlanner, historyLimit: Int = ItemExplainer.historyLimit) {
        self.checkEngine = checkEngine
        self.planner = planner
        self.historyLimit = historyLimit
    }

    public static func standard() -> ItemExplainer {
        ItemExplainer(checkEngine: .standard(), planner: .standard())
    }

    /// Checks the item's provider, then explains the item.
    ///
    /// The check is `macup check` for that one provider, keeping its installed
    /// items, so an item with no update can still be explained.
    public func explain(
        _ item: PackageID,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        history: HistoryStore?,
        refreshMetadata: Bool = false
    ) async -> ItemExplanation {
        let report = await checkEngine.run(
            configuration: configuration,
            options: CheckOptions(
                refreshMetadata: refreshMetadata,
                providers: [item.provider],
                includeInventoryItems: true
            ),
            environment: environment
        )
        return await explain(item, from: report, configuration: configuration, environment: environment, history: history)
    }

    /// Explains an item from a check that already ran, as the app does with
    /// the one on screen. Plans without running anything.
    public func explain(
        _ item: PackageID,
        from report: CheckReport,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        history: HistoryStore?
    ) async -> ItemExplanation {
        let providerReport = report.providers.first { $0.provider == item.provider }
        let update = report.updates.first { $0.id == item }
        let installed = providerReport?.items?.first { $0.id == item }
        let engine = PolicyEngine(configuration)

        var decision: PolicyDecision?
        var plan: ExecutionPlan?
        var skipped: SkippedUpdate?
        if let update {
            // The same planner, request and rules as `macup plan <item>`, so
            // the answer here is the answer there.
            let planned = await planner.plan(
                report,
                request: PlanRequest(selection: [item], intent: .interactive),
                configuration: configuration,
                environment: environment
            )
            if let first = planned.planned.first(where: { $0.item == item }) {
                plan = first.plan
                decision = first.decision
            } else if let skip = planned.skipped.first(where: { $0.item == item }) {
                skipped = skip
                decision = skip.decision
            }
            decision = decision ?? engine.decide(update, intent: .interactive)
        }

        let (policy, source) = engine.effectivePolicy(for: item)
        let status = Self.status(
            update: update,
            installed: installed,
            provider: providerReport,
            cancelled: report.cancelled
        )
        return ItemExplanation(
            createdAt: environment.now(),
            item: item,
            status: status,
            summary: Self.summary(
                status,
                item: item,
                update: update,
                installed: installed,
                decision: decision,
                planned: plan != nil,
                provider: providerReport,
                cancelled: report.cancelled
            ),
            update: update,
            installed: installed,
            policy: ItemExplanation.Policy(
                policy: policy,
                source: source,
                rule: Self.rulePath(source, item: item),
                decision: decision
            ),
            plan: plan,
            skipped: skipped,
            history: Self.readHistory(history, item: item, limit: historyLimit),
            providerReport: providerReport,
            configuration: ConfigurationSummary(configuration),
            cancelled: report.cancelled
        )
    }

    // MARK: What MacUp found

    /// Fail closed: "up to date" and "not found" are only claimed from a
    /// provider check that finished and left nothing out.
    static func status(
        update: UpdateCandidate?,
        installed: ManagedItem?,
        provider: ProviderReport?,
        cancelled: Bool
    ) -> ItemExplanation.Status {
        if update != nil { return .updateAvailable }
        guard let provider else { return .providerNotFound }
        switch provider.availability {
        case .disabled: return .providerDisabled
        case .unavailable: return .providerNotFound
        case .failed: return .checkFailed
        case .available: break
        }
        let updatesUnknown = cancelled || provider.resultsIncomplete
            || provider.errors.contains { $0.operation == .outdated }
        if installed != nil { return updatesUnknown ? .updateUnknown : .upToDate }
        // With no list of installed items, only "no update" is known, and
        // that is what the summary says.
        let installedUnknown = provider.errors.contains { $0.operation == .inventory }
        return updatesUnknown || installedUnknown ? .checkFailed : .notFound
    }

    static func summary(
        _ status: ItemExplanation.Status,
        item: PackageID,
        update: UpdateCandidate?,
        installed: ManagedItem?,
        decision: PolicyDecision?,
        planned: Bool,
        provider: ProviderReport?,
        cancelled: Bool
    ) -> String {
        let name = item.provider.displayName
        switch status {
        case .updateAvailable:
            guard let update else { return "An update is available." }
            let versions = update.installedVersion.map { "\($0.raw) → \(update.availableVersion.raw)" }
                ?? "version \(update.availableVersion.raw)"
            let next: String
            switch (planned, decision?.action) {
            case (true, .allow?): next = "MacUp would apply it without asking."
            case (true, _): next = "MacUp would apply it once you confirm."
            case (false, .deny?): next = "MacUp leaves it alone."
            case (false, _): next = "MacUp cannot plan it."
            }
            return "An update is available: \(versions). \(next)"
        case .upToDate:
            return "Installed: \(installedVersions(installed)). \(name) offers no update for it."
        case .updateUnknown:
            return "Installed: \(installedVersions(installed)). MacUp could not find out whether \(name) has an update for it."
        case .notFound:
            if provider?.capabilities.contains(.inventory) == false {
                return "\(name) offers no update matching \(item.rawValue), and MacUp does not list what \(name) has installed."
            }
            if provider?.items == nil {
                return "\(name) offers no update for \(item.rawValue)."
            }
            return "\(name) does not list \(item.rawValue) as installed, and offers no update for it."
        case .providerDisabled:
            return "\(name) is turned off in MacUp's configuration, so MacUp did not look for \(item.rawValue)."
        case .providerNotFound:
            return "MacUp did not find \(name) on this Mac, so it knows nothing about \(item.rawValue)."
        case .checkFailed:
            if cancelled {
                return "The check was cancelled before it finished, so MacUp cannot say anything about \(item.rawValue)."
            }
            return "MacUp could not finish checking \(name), so it cannot say whether \(item.rawValue) is installed or has an update."
        }
    }

    /// "24.19.0 (in use), 24.18.0", or the one version there is.
    static func installedVersions(_ item: ManagedItem?) -> String {
        guard let item else { return "version not reported" }
        let versions = item.installedVersions.map(\.raw)
        guard let active = item.activeVersion?.raw else {
            return versions.isEmpty ? "version not reported" : versions.joined(separator: ", ")
        }
        let others = versions.filter { $0 != active }
        return others.isEmpty ? active : "\(active) (in use), " + others.joined(separator: ", ")
    }

    /// Where the rule that supplies an item's policy lives in the file: the
    /// same paths `macup policy set` reports it changed.
    static func rulePath(_ source: PolicyDecision.Source, item: PackageID) -> String {
        switch source {
        case .item: "items.\(item.rawValue).policy"
        case .provider: "providers.\(item.provider.rawValue).policy"
        default: "global.defaultPolicy"
        }
    }

    // MARK: History

    static func readHistory(_ store: HistoryStore?, item: PackageID, limit: Int) -> ItemExplanation.History {
        guard let store else {
            return ItemExplanation.History(limit: limit, problem: "MacUp could not tell where its history file is.")
        }
        do {
            // One more than is shown, to know whether there are more.
            let reading = try store.read(item: item, limit: limit + 1)
            return ItemExplanation.History(
                entries: Array(reading.entries.prefix(limit)),
                limit: limit,
                moreAvailable: reading.entries.count > limit,
                unreadableLines: reading.unreadableLines
            )
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading MacUp's history")
            return ItemExplanation.History(
                limit: limit,
                problem: [failure.message, failure.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
            )
        }
    }
}
