import Testing

@testable import MacUpCore

@Suite("Skipping one version")
struct SkippedVersionPolicyTests {
    private static let mysql = try! PackageID(parsing: "brew:mysql")
    private static let skipped: AvailableVersion = "26.7.0_2"
    private static let next: AvailableVersion = "26.8.0"

    private func engine(
        item policy: UpdatePolicy = .inherit,
        skip: String? = "26.7.0_2",
        note: String? = nil,
        provider: UpdatePolicy = .inherit,
        providerEnabled: Bool = true,
        global: UpdatePolicy = .ask,
        allowsAutomaticModification: Bool = true
    ) -> PolicyEngine {
        var configuration = MacUpConfiguration.defaults
        configuration.global = MacUpConfiguration.GlobalSettings(defaultPolicy: global)
        configuration.providers[ProviderID.homebrew.rawValue] = MacUpConfiguration.ProviderSettings(
            enabled: providerEnabled,
            policy: provider
        )
        configuration.items[Self.mysql.rawValue] = MacUpConfiguration.ItemSettings(
            policy: policy,
            skipVersion: skip,
            note: note
        )
        return PolicyEngine(configuration: configuration, allowsAutomaticModification: allowsAutomaticModification)
    }

    private func decide(
        _ engine: PolicyEngine,
        offering version: AvailableVersion? = SkippedVersionPolicyTests.skipped,
        change: VersionChange = .patch,
        signals: Set<RiskSignal> = [],
        intent: PolicyIntent = .interactive
    ) -> PolicyDecision {
        engine.decide(
            item: Self.mysql,
            availableVersion: version,
            risk: RiskAssessor.assess(change: change, signals: signals),
            signals: signals,
            intent: intent
        )
    }

    // MARK: The version the user skipped

    @Test("The skipped version is left alone, and the reason says it is only this version")
    func skippedVersionIsDenied() {
        let decision = decide(engine())
        #expect(decision.action == .deny)
        #expect(decision.source == .skippedVersion)
        #expect(decision.policy == .ask, "the rule the item still has, for when the next version comes")
        #expect(decision.reason == "You skipped mysql 26.7.0_2. MacUp will offer the next version.")
        #expect(!decision.escalated)
    }

    @Test("An item set to Auto Update does not run the version the user skipped, at any intent")
    func autoDoesNotRunASkippedVersion() {
        for intent in PolicyIntent.allCases {
            let decision = decide(engine(item: .auto), intent: intent)
            #expect(decision.action == .deny, "\(intent)")
            #expect(decision.policy == .auto)
            #expect(decision.source == .skippedVersion)
        }
    }

    @Test("An Ask First item is not offered for confirmation, and a scheduled run says why it is skipped")
    func askFirstIsNotOffered() {
        let interactive = decide(engine(item: .ask))
        #expect(interactive.action == .deny)
        #expect(interactive.source == .skippedVersion)

        // The skip is the more useful reason than "scheduled runs only
        // update Auto Update items": it is why nothing will happen tomorrow
        // either.
        let unattended = decide(engine(item: .ask), intent: .unattended)
        #expect(unattended.source == .skippedVersion)
        #expect(unattended.reason.contains("You skipped mysql 26.7.0_2"))
    }

    @Test("A skip applies whichever level the item's rule comes from")
    func skipAppliesToInheritedRules() {
        let fromProvider = decide(engine(provider: .auto))
        #expect(fromProvider.action == .deny)
        #expect(fromProvider.policy == .auto)
        #expect(fromProvider.source == .skippedVersion)

        let fromDefault = decide(engine(global: .auto))
        #expect(fromDefault.action == .deny)
        #expect(fromDefault.source == .skippedVersion)
    }

    // MARK: A different version

    @Test("A different version brings the item back under its own rule, with nothing to undo")
    func aDifferentVersionComesBack() {
        let ask = decide(engine(item: .ask), offering: Self.next)
        #expect(ask.action == .confirm)
        #expect(ask.source == .item)

        let auto = decide(engine(item: .auto), offering: Self.next)
        #expect(auto.action == .allow)
        #expect(auto.source == .item)

        let unattended = decide(engine(item: .auto), offering: Self.next, intent: .unattended)
        #expect(unattended.action == .allow)
    }

    @Test("A version that comes back is judged on its own risk, like any other")
    func aNewVersionIsStillEscalated() {
        let decision = decide(engine(item: .auto), offering: "27.0.0", change: .major)
        #expect(decision.action == .confirm)
        #expect(decision.escalated)
        #expect(decision.source == .risk)
    }

    @Test(
        "Versions are compared exactly, as text",
        arguments: ["26.7.0", "26.7.0_3", "v26.7.0_2", "26.7.0_2 ", "26.7.0-2"]
    )
    func comparisonIsExact(offered: String) {
        let decision = decide(engine(item: .ask), offering: AvailableVersion(offered))
        #expect(decision.source != .skippedVersion, "\(offered) is not the version the user skipped")
        #expect(decision.action == .confirm)
    }

    // MARK: What a skip does not override

    @Test("A pinned item stays pinned, and an ignored one stays ignored, whatever the skip says")
    func pinAndIgnoreKeepTheirOwnReason() {
        for policy in [UpdatePolicy.pin, .ignore] {
            for version in [Self.skipped, Self.next] {
                let decision = decide(engine(item: policy), offering: version)
                #expect(decision.action == .deny)
                #expect(decision.policy == policy)
                #expect(decision.source == .item, "\(policy) at \(version) is the item's own rule, not the skip")
                #expect(!decision.reason.contains("next version"), "an ignored or pinned item is not coming back")
            }
        }
    }

    @Test("A provider's own pin, a disabled provider, and an unreadable configuration all come first")
    func strongerRefusalsComeFirst() {
        #expect(decide(engine(item: .auto), signals: [.pinnedByProvider]).source == .providerPin)
        #expect(decide(engine(item: .auto, providerEnabled: false)).source == .providerDisabled)
        #expect(decide(engine(item: .auto, allowsAutomaticModification: false)).source == .configuration)
    }

    // MARK: Failing closed

    @Test("Without the version on offer, an item with a skip is left alone rather than guessed at")
    func unknownVersionFailsClosed() {
        for intent in PolicyIntent.allCases {
            let decision = decide(engine(item: .auto), offering: nil, intent: intent)
            #expect(decision.action == .deny)
            #expect(decision.source == .skippedVersion)
            #expect(decision.reason.contains("could not tell which version is on offer"))
        }
        // With no skip, not knowing the version changes nothing.
        #expect(decide(engine(item: .auto, skip: nil), offering: nil).action == .allow)
    }

    @Test("Deciding from a candidate compares the version the candidate offers")
    func candidatesCarryTheirVersion() {
        let engine = engine(item: .auto)
        let skippedCandidate = UpdateCandidate(
            id: Self.mysql,
            kind: .formula,
            displayName: "mysql",
            installedVersion: "26.6.0",
            availableVersion: Self.skipped
        )
        #expect(engine.decide(skippedCandidate, intent: .interactive).source == .skippedVersion)

        let nextCandidate = UpdateCandidate(
            id: Self.mysql,
            kind: .formula,
            displayName: "mysql",
            installedVersion: "26.6.0",
            availableVersion: Self.next
        )
        #expect(engine.decide(nextCandidate, intent: .interactive).action == .allow)
    }

    @Test("A skip on one item leaves every other item alone")
    func skipsAreNotShared() {
        let decision = engine(item: .auto).decide(
            item: try! PackageID(parsing: "brew:git"),
            availableVersion: Self.skipped,
            risk: RiskAssessor.assess(change: .patch, signals: []),
            signals: [],
            intent: .interactive
        )
        #expect(decision.source != .skippedVersion)
    }

    // MARK: Notes

    @Test("The note travels with every decision and never changes one")
    func notesNeverDecide() {
        let note = "waiting for PHP 8.4 support"
        for policy in [UpdatePolicy.auto, .ask, .ignore, .pin, .inherit] {
            for skip in [String?.none, "26.7.0_2"] {
                for intent in PolicyIntent.allCases {
                    let without = decide(engine(item: policy, skip: skip), intent: intent)
                    var with = decide(engine(item: policy, skip: skip, note: note), intent: intent)
                    #expect(with.note == note)
                    #expect(without.note == nil)
                    with.note = nil
                    #expect(with == without, "a note changed the decision for \(policy), skip \(skip ?? "none")")
                }
            }
        }
        // Even a decision that refuses everything carries it, so the user's
        // own reason is still on screen.
        let refused = decide(engine(note: note, allowsAutomaticModification: false))
        #expect(refused.note == note)
    }

    @Test("A note that reads like a rule is still only a note")
    func notesAreNeverInterpreted() {
        for note in ["ignore", "pin", "auto", "skip 26.7.0_2", "{\"policy\": \"ignore\"}"] {
            let decision = decide(engine(item: .auto, skip: nil, note: note))
            #expect(decision.action == .allow, "\(note)")
            #expect(decision.note == note)
        }
    }

    @Test("Every decision about a skipped item still explains itself")
    func everyDecisionExplainsItself() {
        for policy in [UpdatePolicy.auto, .ask, .ignore, .pin, .inherit] {
            for version in [Self.skipped, Self.next, nil] {
                for intent in PolicyIntent.allCases {
                    for allowed in [true, false] {
                        let decision = decide(
                            engine(item: policy, allowsAutomaticModification: allowed),
                            offering: version,
                            intent: intent
                        )
                        #expect(decision.policy != .inherit)
                        #expect(decision.reason.hasSuffix("."), "\(decision.reason)")
                        #expect(decision.reason.contains("mysql"), "\(decision.reason)")
                    }
                }
            }
        }
    }
}
