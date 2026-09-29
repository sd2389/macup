/// Decides what MacUp may do with an item, and can always say why.
///
/// Precedence (CLAUDE.md §6) is the per-item rule, then the provider rule,
/// then the global default. Three things override whatever that precedence
/// produced, and all three fail closed. A configuration MacUp could not read
/// allows nothing, because the rules saying which items are excluded are
/// exactly the ones it could not read. A provider turned off in the
/// configuration allows nothing. An item the provider itself holds back
/// (`brew pin`) allows nothing, so a MacUp update never silently unpins it.
///
/// A skipped version (`items.<id>.skipVersion`) comes next. When the version
/// on offer is exactly the one the user skipped, an item that would otherwise
/// be offered (Ask First) or run (Auto Update) is left alone instead, and a
/// different version brings it back under its rule with nothing to undo.
/// Ignore and Pin already leave every version alone, so they keep their own
/// reason: telling someone a pinned item will come back with the next version
/// would be untrue.
///
/// Risk then raises the bar, because `auto` means "update this without asking
/// me", not "decide anything on my behalf": see ``escalation(item:risk:signals:configuration:)``
/// for the cases where an `auto` item still waits for a person. In an
/// unattended run there is no person, so those items are not updated at all
/// and come back as review items instead (CLAUDE.md §15).
///
/// An unattended run updates only what resolves to `auto`, from whichever
/// level set it. A global default of `auto` is as deliberate a choice as a
/// per-item rule — the user wrote it into their configuration file, and the
/// decision says which rule it came from — so the engine does not treat it as
/// less explicit than the others.
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

    /// Every rule the configuration sets, for `macup policy list` and the
    /// app's Settings screen. Read-only.
    public func rules() -> PolicyListing {
        PolicyListing(
            configuration: configuration,
            automaticModificationsAllowed: allowsAutomaticModification
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

    /// What policy says about one update candidate, and why.
    public func decide(_ candidate: UpdateCandidate, intent: PolicyIntent) -> PolicyDecision {
        decide(
            item: candidate.id,
            availableVersion: candidate.availableVersion,
            risk: candidate.risk,
            signals: Set(candidate.signals),
            intent: intent
        )
    }

    /// What policy says about one item, and why.
    ///
    /// Callers pass the version on offer and the risk and signals the provider
    /// reported, so the same decision can be re-taken from a stored plan
    /// immediately before execution (CLAUDE.md §2.20). Without the version,
    /// an item with a skipped version is left alone: MacUp cannot tell
    /// whether this is the version the user skipped.
    public func decide(
        item: PackageID,
        availableVersion: AvailableVersion? = nil,
        risk: RiskAssessment,
        signals: Set<RiskSignal>,
        intent: PolicyIntent
    ) -> PolicyDecision {
        var decision = ruling(
            item: item,
            availableVersion: availableVersion,
            risk: risk,
            signals: signals,
            intent: intent
        )
        decision.note = configuration.items[item.rawValue]?.note
        return decision
    }

    private func ruling(
        item: PackageID,
        availableVersion: AvailableVersion?,
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
                reason: "MacUp left \(item.name) alone because it could not read its configuration, "
                    + "so it cannot tell which items you excluded. Nothing is changed until that is fixed."
            )
        }

        guard configuration.settings(for: item.provider).enabled else {
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: .providerDisabled,
                reason: "\(item.name) is not updated because \(item.provider.displayName) is turned off in MacUp's configuration."
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

        if policy != .ignore, policy != .pin, let skipped = Self.skippedVersion(
            item: item,
            policy: policy,
            availableVersion: availableVersion,
            configuration: configuration
        ) {
            return skipped
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
            guard let escalation = Self.escalation(
                item: item,
                risk: risk,
                signals: signals,
                configuration: configuration
            ) else {
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
    ///
    /// Every rule but the last comes straight from the spec and cannot be
    /// switched off: macOS updates, runtime major changes, and unknown risk
    /// are always Ask First (CLAUDE.md §6, §10), MacUp never walks into an
    /// administrator prompt or a restart on its own (CLAUDE.md §2.10, §2.19),
    /// it does not rewrite a config file or lockfile unasked
    /// (CLAUDE.md §2.1, §9), and it does not move a database to a version
    /// that may convert its data for good (CLAUDE.md §1).
    ///
    /// `confirmMajorUpdates` governs only the last rule, an ordinary package's
    /// major version bump. It is a preference about version numbers, so
    /// turning it off does not buy past the rules above it.
    static func escalation(
        item: PackageID,
        risk: RiskAssessment,
        signals: Set<RiskSignal>,
        configuration: MacUpConfiguration
    ) -> String? {
        // Checked by provider, not only by signal: `softwareupdate` reports
        // Safari and security updates without marking them as OS updates, and
        // every macOS update is Ask First in v1 regardless.
        if item.provider == .macos {
            return "\(item.name) is a macOS update, and those always need your confirmation."
        }
        if signals.contains(.operatingSystemUpdate) {
            return "Updating \(item.name) changes the operating system, which always needs your confirmation."
        }
        if signals.contains(.administratorAuthorizationMayBeRequired) {
            return "Updating \(item.name) may ask for an administrator password, which MacUp never answers for you."
        }
        if signals.contains(.restartRequired) {
            return "Updating \(item.name) may require a restart, so it needs your confirmation."
        }
        if signals.contains(.mayRewriteConfiguration) {
            return "Updating \(item.name) would mean editing your configuration or lockfile, which MacUp never does on its own."
        }
        // Not a preference about version numbers, so `confirmMajorUpdates`
        // does not reach it: a database's data may be converted for good the
        // first time the new version starts, and only its owner knows whether
        // there is a backup.
        if signals.contains(.mayMigrateData) {
            return "\(item.name) is a database, and its new version may convert your data files for good, so it needs your confirmation."
        }
        // A runtime change alone is only moderate risk, so high risk here
        // means the version change itself is major, a pre-release, or a
        // downgrade — the case CLAUDE.md §2.18 rules out doing automatically.
        if signals.contains(.runtimeOrToolchain), risk.level == .high {
            return "\(item.name) is a language runtime or toolchain, and this is a major change, so it needs your confirmation."
        }
        if risk.level == .unknown {
            return "MacUp could not judge how risky updating \(item.name) is, so it asks first."
        }
        if risk.level == .high, configuration.global.confirmMajorUpdates {
            return "Updating \(item.name) is a high-risk change (\(risk.reasons.first?.lowercased() ?? "reason unknown")), so it asks first."
        }
        return nil
    }

    /// The refusal for a version the user skipped, or `nil` when the version
    /// on offer is a different one.
    ///
    /// The same answer whether someone is at the Mac or not: a skipped
    /// version is neither offered for confirmation nor run on a schedule.
    static func skippedVersion(
        item: PackageID,
        policy: UpdatePolicy,
        availableVersion: AvailableVersion?,
        configuration: MacUpConfiguration
    ) -> PolicyDecision? {
        guard let settings = configuration.items[item.rawValue], let skipped = settings.skipVersion else { return nil }
        let version = TerminalText.sanitize(skipped)
        guard let availableVersion else {
            // Fail closed: this might be the skipped version (CLAUDE.md §2.23).
            return PolicyDecision(
                item: item,
                action: .deny,
                policy: policy,
                source: .skippedVersion,
                reason: "You skipped \(item.name) \(version), and MacUp could not tell which version is on offer, "
                    + "so it left \(item.name) alone."
            )
        }
        guard settings.skips(availableVersion) else { return nil }
        return PolicyDecision(
            item: item,
            action: .deny,
            policy: policy,
            source: .skippedVersion,
            reason: "You skipped \(item.name) \(version). MacUp will offer the next version."
        )
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
