/// Decides what MacUp may do with an item, and can always say why.
///
/// Precedence (CLAUDE.md §6): per-item rule, then provider rule, then the
/// global default. Three things override the result of that precedence, and
/// all three fail closed:
///
/// - a configuration MacUp could not read allows nothing, because the rules
///   that say which items are excluded are exactly what it could not read
/// - a provider turned off in the configuration allows nothing
/// - an item the provider itself holds back (`brew pin`) allows nothing, so a
///   MacUp update never silently unpins it
///
/// Risk then raises the bar: an `auto` item whose risk is high or unknown
/// still needs a person to confirm it, and in an unattended run that means it
/// is not updated at all.
public struct PolicyEngine: Sendable {
    public var configuration: MacUpConfiguration
    /// False when the configuration file could not be trusted.
    public var allowsAutomaticModification: Bool

    public init(configuration: MacUpConfiguration, allowsAutomaticModification: Bool = true) {
        self.configuration = configuration
        self.allowsAutomaticModification = allowsAutomaticModification
    }

    public init(_ loaded: LoadedConfiguration) {
        self.init(
            configuration: loaded.configuration,
            allowsAutomaticModification: loaded.allowsAutomaticModification
        )
    }

    /// The policy in effect for an item, and which rule supplied it.
    /// Never returns `.inherit`.
    public func effectivePolicy(for item: PackageID) -> (policy: UpdatePolicy, source: PolicyDecision.Source) {
        if let rule = configuration.items[item.rawValue]?.policy, rule != .inherit {
            return (rule, .item)
        }
        let providerRule = configuration.settings(for: item.provider).policy
        if providerRule != .inherit {
            return (providerRule, .provider)
        }
        let global = configuration.global.defaultPolicy
        return (global == .inherit ? .ask : global, .global)
    }

    public func decide(_ candidate: UpdateCandidate, intent: PolicyIntent) -> PolicyDecision {
        decide(
            item: candidate.id,
            risk: candidate.risk,
            signals: Set(candidate.signals),
            intent: intent
        )
    }

    public func decide(
        item: PackageID,
        risk: RiskAssessment,
        signals: Set<RiskSignal>,
        intent: PolicyIntent
    ) -> PolicyDecision {
        let (policy, source) = effectivePolicy(for: item)

        guard allowsAutomaticModification else {
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: .configuration,
                reason: "MacUp could not read its configuration, so it cannot tell which items you excluded. Nothing is changed until that is fixed."
            )
        }

        guard configuration.settings(for: item.provider).enabled else {
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: .providerDisabled,
                reason: "\(item.provider.displayName) is turned off in MacUp's configuration."
            )
        }

        if signals.contains(.pinnedByProvider) {
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: .providerPin,
                reason: "\(item.name) is pinned in \(item.provider.displayName). MacUp does not unpin it for you."
            )
        }

        switch policy {
        case .ignore:
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: source,
                reason: Self.reason("is ignored", source: source, item: item)
            )
        case .pin:
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: source,
                reason: Self.reason("is held at its current version", source: source, item: item)
            )
        case .ask, .inherit:
            let reason = Self.reason("needs your confirmation first", source: source, item: item)
            return PolicyDecision(
                item: item,
                action: intent == .unattended ? .deny : .confirm,
                policy: .ask,
                source: intent == .unattended ? .unattended : source,
                reason: intent == .unattended
                    ? "A scheduled run only updates items set to Auto Update; \(item.name) is Ask First."
                    : reason
            )
        case .auto:
            guard let escalation = Self.escalation(risk: risk, signals: signals, configuration: configuration) else {
                return PolicyDecision(
                    item: item,
                    action: .allow,
                    policy: .auto,
                    source: source,
                    reason: Self.reason("is set to update automatically", source: source, item: item)
                )
            }
            return PolicyDecision(
                item: item,
                action: intent == .unattended ? .deny : .confirm,
                policy: .auto,
                source: intent == .unattended ? .unattended : .risk,
                reason: intent == .unattended
                    ? "\(escalation) A scheduled run does not make that decision for you."
                    : escalation,
                escalated: true
            )
        }
    }

    /// Why an `auto` item still needs a person, or `nil` when it does not.
    static func escalation(
        risk: RiskAssessment,
        signals: Set<RiskSignal>,
        configuration: MacUpConfiguration
    ) -> String? {
        if signals.contains(.operatingSystemUpdate) {
            return "A macOS update always needs your confirmation."
        }
        if risk.level == .unknown {
            return "MacUp could not judge how risky this change is, so it asks first."
        }
        if risk.level == .high, configuration.global.confirmMajorUpdates {
            return "This is a high-risk change (\(risk.reasons.first?.lowercased() ?? "reason unknown")), so it asks first."
        }
        return nil
    }

    private static func reason(_ predicate: String, source: PolicyDecision.Source, item: PackageID) -> String {
        switch source {
        case .item:
            "\(item.name) \(predicate) (a rule you set for this item)."
        case .provider:
            "\(item.name) \(predicate) (the rule for \(item.provider.displayName))."
        default:
            "\(item.name) \(predicate) (MacUp's default)."
        }
    }
}
