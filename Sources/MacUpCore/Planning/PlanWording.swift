/// Wording for plans and decisions that more than one surface prints: the
/// plan, the dry run, `macup explain`, and the app's Copy Details. It lives
/// here so the same fact is never described two different ways.
extension ExecutionPlan {
    /// What a change would touch beyond the package itself.
    ///
    /// Only the notable answers by default. With `includingReassuring`, every
    /// field is stated, the "no" answers too, because CLAUDE.md §11 requires a
    /// plan to carry all of them.
    public func effectSummaries(includingReassuring: Bool) -> [String] {
        var effects: [String] = []
        if mayRequirePrivilege { effects.append("may ask for an administrator password") }
        if mayRequireRestart { effects.append("may require a restart") }
        if mayChangeUserConfiguration { effects.append("may change your configuration or lockfile") }
        guard includingReassuring else { return effects }
        if !mayRequirePrivilege { effects.append("no administrator password") }
        if !mayRequireRestart { effects.append("no restart") }
        if !mayChangeUserConfiguration { effects.append("leaves your configuration alone") }
        effects.append(expectsNetwork ? "uses the network" : "no network")
        return effects
    }
}

extension PolicyDecision.Action {
    /// What the decision means for the item: "runs without asking",
    /// "needs your confirmation", or "will not run".
    public var summary: String {
        switch self {
        case .allow: "runs without asking"
        case .confirm: "needs your confirmation"
        case .deny: "will not run"
        }
    }
}

extension PolicyDecision {
    /// The effective policy and what it means for this item, such as
    /// "Ask First · needs your confirmation".
    public var actionSummary: String {
        "\(policy.displayName) · \(action.summary)"
    }
}

extension ProviderOperationError.Operation {
    /// The part of a check that failed, as a reader would name it.
    public var displayName: String {
        switch self {
        case .detect: "detection"
        case .refreshMetadata: "metadata refresh"
        case .inventory: "installed items"
        case .outdated: "update check"
        }
    }
}
