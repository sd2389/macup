import Testing

@testable import MacUpCore

@Suite("Policy decisions")
struct PolicyEngineTests {
    // MARK: Helpers

    private static let git = try! PackageID(parsing: "brew:git")
    private static let node = try! PackageID(parsing: "mise:node")
    private static let claude = try! PackageID(parsing: "npm:@anthropic-ai/claude-code")
    private static let macOS = try! PackageID(parsing: "macos:26.6.2")

    private static let allPolicies: [UpdatePolicy] = [.auto, .ask, .ignore, .pin, .inherit]

    private func configuration(
        item: UpdatePolicy? = nil,
        for id: PackageID = PolicyEngineTests.git,
        provider: UpdatePolicy = .inherit,
        providerEnabled: Bool = true,
        global: UpdatePolicy = .ask,
        confirmMajorUpdates: Bool = true
    ) -> MacUpConfiguration {
        var configuration = MacUpConfiguration.defaults
        configuration.global = MacUpConfiguration.GlobalSettings(
            defaultPolicy: global,
            confirmMajorUpdates: confirmMajorUpdates
        )
        configuration.providers[id.provider.rawValue] = MacUpConfiguration.ProviderSettings(
            enabled: providerEnabled,
            policy: provider
        )
        if let item {
            configuration.items[id.rawValue] = MacUpConfiguration.ItemSettings(policy: item)
        }
        return configuration
    }

    private func engine(
        item: UpdatePolicy? = nil,
        for id: PackageID = PolicyEngineTests.git,
        provider: UpdatePolicy = .inherit,
        providerEnabled: Bool = true,
        global: UpdatePolicy = .ask,
        confirmMajorUpdates: Bool = true,
        allowsAutomaticModification: Bool = true
    ) -> PolicyEngine {
        PolicyEngine(
            configuration: configuration(
                item: item,
                for: id,
                provider: provider,
                providerEnabled: providerEnabled,
                global: global,
                confirmMajorUpdates: confirmMajorUpdates
            ),
            allowsAutomaticModification: allowsAutomaticModification
        )
    }

    private func decide(
        _ engine: PolicyEngine,
        _ id: PackageID = PolicyEngineTests.git,
        change: VersionChange = .patch,
        signals: Set<RiskSignal> = [],
        intent: PolicyIntent = .interactive
    ) -> PolicyDecision {
        engine.decide(
            item: id,
            risk: RiskAssessor.assess(change: change, signals: signals),
            signals: signals,
            intent: intent
        )
    }

    // MARK: Precedence

    @Test(
        "A per-item rule wins, then the provider rule, then the global default",
        arguments: [
            (UpdatePolicy?.some(.ignore), UpdatePolicy.auto, UpdatePolicy.auto, UpdatePolicy.ignore, PolicyDecision.Source.item),
            (.some(.auto), .ignore, .ignore, .auto, .item),
            (.some(.pin), .auto, .ask, .pin, .item),
            (nil, .ignore, .auto, .ignore, .provider),
            (nil, .auto, .ignore, .auto, .provider),
            (nil, .inherit, .ignore, .ignore, .global),
            (nil, .inherit, .auto, .auto, .global),
            (nil, .inherit, .ask, .ask, .global),
        ]
    )
    func precedence(
        item: UpdatePolicy?,
        provider: UpdatePolicy,
        global: UpdatePolicy,
        expected: UpdatePolicy,
        source: PolicyDecision.Source
    ) {
        let resolved = engine(item: item, provider: provider, global: global).effectivePolicy(for: Self.git)
        #expect(resolved.policy == expected)
        #expect(resolved.source == source)
    }

    @Test(
        "inherit at any level falls through to the next one",
        arguments: [
            (UpdatePolicy.inherit, UpdatePolicy.ignore, UpdatePolicy.auto, UpdatePolicy.ignore, PolicyDecision.Source.provider),
            (.inherit, .inherit, .ignore, .ignore, .global),
            (.inherit, .inherit, .auto, .auto, .global),
        ]
    )
    func inheritFallsThrough(
        item: UpdatePolicy,
        provider: UpdatePolicy,
        global: UpdatePolicy,
        expected: UpdatePolicy,
        source: PolicyDecision.Source
    ) {
        let resolved = engine(item: item, provider: provider, global: global).effectivePolicy(for: Self.git)
        #expect(resolved.policy == expected)
        #expect(resolved.source == source)
    }

    @Test("Every combination of the three levels resolves to a real policy")
    func everyCombinationResolves() {
        for itemPolicy in [UpdatePolicy?.none] + Self.allPolicies.map(Optional.some) {
            for providerPolicy in [UpdatePolicy.auto, .ask, .ignore, .inherit] {
                for globalPolicy in [UpdatePolicy.auto, .ask, .ignore] {
                    let resolved = engine(item: itemPolicy, provider: providerPolicy, global: globalPolicy)
                        .effectivePolicy(for: Self.git)
                    let expected: (policy: UpdatePolicy, source: PolicyDecision.Source)
                    if let itemPolicy, itemPolicy != .inherit {
                        expected = (itemPolicy, .item)
                    } else if providerPolicy != .inherit {
                        expected = (providerPolicy, .provider)
                    } else {
                        expected = (globalPolicy, .global)
                    }
                    #expect(
                        resolved == expected,
                        "item \(itemPolicy?.rawValue ?? "unset"), provider \(providerPolicy.rawValue), global \(globalPolicy.rawValue)"
                    )
                    #expect(resolved.policy != .inherit)
                }
            }
        }
    }

    @Test("A global default of inherit has nothing to inherit from, so it means ask")
    func globalInheritMeansAsk() {
        // The validator rejects this file, but the engine must not fall over
        // if it is ever handed one.
        let resolved = engine(provider: .inherit, global: .inherit).effectivePolicy(for: Self.git)
        #expect(resolved == (.ask, .global))
        #expect(decide(engine(provider: .inherit, global: .inherit)).action == .confirm)
    }

    @Test("An item's rule applies only to that item")
    func rulesAreNotShared() {
        let engine = engine(item: .ignore, for: Self.claude, global: .auto)
        #expect(engine.effectivePolicy(for: Self.claude).policy == .ignore)
        #expect(engine.effectivePolicy(for: try! PackageID(parsing: "npm:typescript")).policy == .auto)
    }

    // MARK: Refusals

    @Test("ignore and pin never allow a change, at any intent")
    func ignoreAndPinDeny() {
        for policy in [UpdatePolicy.ignore, .pin] {
            for intent in PolicyIntent.allCases {
                let decision = decide(engine(item: policy), intent: intent)
                #expect(decision.action == .deny)
                #expect(decision.policy == policy)
                #expect(decision.source == .item)
                #expect(decision.reason.contains("git"))
            }
        }
    }

    @Test("A provider rule of ignore denies every one of its items")
    func providerIgnoreDenies() {
        let decision = decide(engine(provider: .ignore))
        #expect(decision.action == .deny)
        #expect(decision.source == .provider)
        #expect(decision.reason.contains("Homebrew"))
    }

    @Test("A disabled provider denies even an item the user set to auto")
    func disabledProviderDenies() {
        for intent in PolicyIntent.allCases {
            let decision = decide(engine(item: .auto, providerEnabled: false), intent: intent)
            #expect(decision.action == .deny)
            #expect(decision.source == .providerDisabled)
            #expect(decision.reason.contains("git"))
            #expect(decision.reason.contains("Homebrew"))
        }
    }

    @Test("A configuration MacUp could not read allows nothing, and says why")
    func invalidConfigurationDeniesEverything() {
        let engine = engine(item: .auto, global: .auto, allowsAutomaticModification: false)
        for intent in PolicyIntent.allCases {
            let decision = decide(engine, intent: intent)
            #expect(decision.action == .deny)
            #expect(decision.source == .configuration)
            #expect(decision.reason.contains("git"))
            #expect(decision.reason.contains("configuration"))
        }
    }

    @Test("A configuration with errors denies items it has no rule for either")
    func invalidConfigurationDeniesUnknownItems() {
        let decision = decide(
            engine(allowsAutomaticModification: false),
            Self.claude,
            intent: .unattended
        )
        #expect(decision.action == .deny)
        #expect(decision.source == .configuration)
    }

    @Test("An item the provider itself pins is never updated, whatever the rule says")
    func providerPinDeniesRegardlessOfPolicy() {
        for policy in Self.allPolicies {
            let decision = decide(engine(item: policy), signals: [.pinnedByProvider])
            #expect(decision.action == .deny)
            #expect(decision.source == .providerPin)
            #expect(decision.reason.contains("git"))
            #expect(decision.reason.contains("pinned"))
        }
    }

    // MARK: auto and risk

    @Test("auto runs a low- or moderate-risk change without asking", arguments: [VersionChange.patch, .build, .revision, .minor])
    func autoAllowsOrdinaryChanges(change: VersionChange) {
        for intent in PolicyIntent.allCases {
            let decision = decide(engine(item: .auto), change: change, intent: intent)
            #expect(decision.action == .allow)
            #expect(decision.policy == .auto)
            #expect(decision.source == .item)
            #expect(!decision.escalated)
            #expect(decision.reason.contains("git"))
        }
    }

    @Test("auto from the provider rule or the global default is still auto")
    func autoFromAnyLevelAllows() {
        #expect(decide(engine(provider: .auto)).action == .allow)
        #expect(decide(engine(provider: .inherit, global: .auto)).action == .allow)
        #expect(decide(engine(provider: .auto), intent: .unattended).action == .allow)
    }

    @Test(
        "Some changes always wait for a person, even when the item is auto and confirmMajorUpdates is off",
        arguments: [
            (Set<RiskSignal>([.administratorAuthorizationMayBeRequired]), VersionChange.patch, "administrator"),
            (Set<RiskSignal>([.restartRequired]), VersionChange.patch, "restart"),
            (Set<RiskSignal>([.mayRewriteConfiguration]), VersionChange.patch, "configuration"),
            (Set<RiskSignal>([.runtimeOrToolchain]), VersionChange.major, "runtime"),
            (Set<RiskSignal>([.operatingSystemUpdate]), VersionChange.patch, "operating system"),
            (Set<RiskSignal>(), VersionChange.unknown, "could not judge"),
            (Set<RiskSignal>(), VersionChange.none, "could not judge"),
        ]
    )
    func unconditionalEscalations(signals: Set<RiskSignal>, change: VersionChange, phrase: String) {
        for confirmMajorUpdates in [true, false] {
            let engine = engine(item: .auto, confirmMajorUpdates: confirmMajorUpdates)
            let decision = decide(engine, change: change, signals: signals)
            #expect(decision.action == .confirm, "\(signals) \(change)")
            #expect(decision.escalated)
            #expect(decision.policy == .auto)
            #expect(decision.source == .risk)
            #expect(decision.reason.lowercased().contains(phrase), "\(decision.reason)")
            #expect(decision.reason.contains("git"))
        }
    }

    @Test("A macOS update is Ask First even when Apple does not call it an OS update")
    func macOSIsAlwaysAsk() {
        // `softwareupdate` lists Safari and security updates without marking
        // them as OS updates, so the provider alone has to be enough.
        var configuration = MacUpConfiguration.defaults
        configuration.items[Self.macOS.rawValue] = MacUpConfiguration.ItemSettings(policy: .auto)
        configuration.global = MacUpConfiguration.GlobalSettings(confirmMajorUpdates: false)
        let engine = PolicyEngine(configuration: configuration)

        let decision = engine.decide(
            item: Self.macOS,
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .interactive
        )
        #expect(decision.action == .confirm)
        #expect(decision.escalated)
        #expect(decision.reason.contains("macOS"))
    }

    @Test("A runtime patch update is not a major change, so auto still applies")
    func runtimePatchIsNotEscalated() {
        let decision = decide(
            engine(item: .auto, for: Self.node),
            Self.node,
            change: .patch,
            signals: [.runtimeOrToolchain]
        )
        #expect(decision.action == .allow)
        #expect(!decision.escalated)
    }

    @Test("confirmMajorUpdates decides only an ordinary package's major bump")
    func confirmMajorUpdatesGovernsVersionBumpsOnly() {
        let asking = decide(engine(item: .auto, confirmMajorUpdates: true), change: .major)
        #expect(asking.action == .confirm)
        #expect(asking.escalated)
        #expect(asking.source == .risk)
        #expect(asking.reason.contains("high-risk"))

        let notAsking = decide(engine(item: .auto, confirmMajorUpdates: false), change: .major)
        #expect(notAsking.action == .allow)
        #expect(!notAsking.escalated)
    }

    @Test("Unknown risk asks first however confirmMajorUpdates is set")
    func unknownRiskAlwaysAsks() {
        for confirmMajorUpdates in [true, false] {
            let decision = decide(
                engine(item: .auto, confirmMajorUpdates: confirmMajorUpdates),
                change: .unknown
            )
            #expect(decision.action == .confirm)
            #expect(decision.escalated)
        }
    }

    // MARK: Unattended runs

    @Test("A scheduled run does not update an Ask First item, and explains itself")
    func unattendedSkipsAskItems() {
        for policy in [UpdatePolicy.ask, .inherit] {
            let decision = decide(engine(item: policy, global: .ask), intent: .unattended)
            #expect(decision.action == .deny)
            #expect(decision.policy == .ask)
            #expect(decision.source == .unattended)
            #expect(decision.reason.contains("git"))
            #expect(!decision.escalated)
        }
    }

    @Test("A scheduled run does not make an escalated auto item's decision for you")
    func unattendedSkipsEscalatedAutoItems() {
        let decision = decide(engine(item: .auto), change: .major, intent: .unattended)
        #expect(decision.action == .deny)
        #expect(decision.policy == .auto)
        #expect(decision.source == .unattended)
        #expect(decision.escalated)
        #expect(decision.reason.contains("scheduled run"))
    }

    @Test("Interactively, the same item is offered for confirmation instead")
    func interactiveConfirmsWhatUnattendedRefuses() {
        for policy in [UpdatePolicy.ask, .auto] {
            let decision = decide(engine(item: policy), change: .major, intent: .interactive)
            #expect(decision.action == .confirm)
            #expect(decision.allowsExecution)
        }
    }

    // MARK: Every decision explains itself

    @Test("Every decision carries an action, a resolved policy, and a reason naming the item")
    func everyDecisionExplainsItself() throws {
        let signalSets: [Set<RiskSignal>] = [
            [],
            [.pinnedByProvider],
            [.runtimeOrToolchain],
            [.restartRequired],
            [.administratorAuthorizationMayBeRequired],
            [.mayRewriteConfiguration],
            [.operatingSystemUpdate],
            [.packageManagerSelfUpdate, .mayAffectDependents],
        ]
        for id in [Self.git, Self.claude, Self.node, Self.macOS] {
            for itemPolicy in [UpdatePolicy?.none] + Self.allPolicies.map(Optional.some) {
                for providerEnabled in [true, false] {
                    for allowed in [true, false] {
                        for signals in signalSets {
                            for change in [VersionChange.patch, .major, .unknown] {
                                for intent in PolicyIntent.allCases {
                                    let decision = decide(
                                        engine(
                                            item: itemPolicy,
                                            for: id,
                                            providerEnabled: providerEnabled,
                                            allowsAutomaticModification: allowed
                                        ),
                                        id,
                                        change: change,
                                        signals: signals,
                                        intent: intent
                                    )
                                    #expect(decision.item == id)
                                    #expect(decision.policy != .inherit)
                                    #expect(!decision.reason.isEmpty)
                                    #expect(decision.reason.hasSuffix("."), "\(decision.reason)")
                                    #expect(decision.reason.contains(id.name), "\(decision.reason)")
                                    #expect(decision.allowsExecution == (decision.action != .deny))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("Deciding from a candidate matches deciding from its parts")
    func candidateAndPartsAgree() throws {
        let candidate = UpdateCandidate(
            id: Self.node,
            kind: .tool,
            displayName: "node",
            installedVersion: "22.9.0",
            availableVersion: "24.1.0",
            signals: [.runtimeOrToolchain, .mayAffectDependents]
        )
        let engine = engine(item: .auto, for: Self.node)
        let fromCandidate = engine.decide(candidate, intent: .interactive)
        let fromParts = engine.decide(
            item: candidate.id,
            risk: candidate.risk,
            signals: Set(candidate.signals),
            intent: .interactive
        )
        #expect(fromCandidate == fromParts)
        #expect(fromCandidate.action == .confirm, "a major runtime change is always Ask First")
    }
}
