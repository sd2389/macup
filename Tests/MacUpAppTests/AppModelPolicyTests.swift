import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Changing a rule from the app")
@MainActor
struct AppModelPolicyTests {
    private static let git = try! PackageID(parsing: "brew:git")

    @Test("A rule set in the app is written to the configuration and reported back")
    func settingAnItemRuleIsWrittenAndReported() async throws {
        let harness = try AppModelHarness()
        await harness.model.setPolicy(.ignore, for: Self.git)

        let change = try #require(harness.model.lastPolicyChange)
        #expect(harness.model.policyProblem == nil)
        #expect(change.changed)
        #expect(change.path == "items.brew:git.policy")
        #expect(change.newValue == "ignore")
        // What changed, not merely that something did.
        #expect(change.summary.contains("Ignore"))

        // The rule is in the file the CLI reads, not only in the app's head.
        let listing = PolicyListing(ConfigurationStore(paths: harness.paths).load())
        #expect(listing.rule(for: Self.git)?.policy == .ignore)
        #expect(harness.model.policyRules.rule(for: Self.git)?.policy == .ignore)
    }

    @Test("Setting the rule a second time says nothing changed rather than claiming it did")
    func settingTheSameRuleTwiceReportsNoChange() async throws {
        let harness = try AppModelHarness()
        await harness.model.setPolicy(.ignore, for: Self.git)
        await harness.model.setPolicy(.ignore, for: Self.git)

        let change = try #require(harness.model.lastPolicyChange)
        #expect(!change.changed)
        #expect(change.summary.contains("nothing was changed"))
    }

    @Test("Clearing a rule makes the item inherit again, and says what it was")
    func clearingAnItemRule() async throws {
        let harness = try AppModelHarness()
        await harness.model.setPolicy(.auto, for: Self.git)
        await harness.model.clearPolicy(for: Self.git)

        let change = try #require(harness.model.lastPolicyChange)
        #expect(change.changed)
        #expect(change.newValue == nil)
        #expect(change.previousValue == "auto")
        #expect(harness.model.policyRules.rule(for: Self.git) == nil)
    }

    @Test("A provider can be turned off and its rule changed, both through the editor")
    func providerRules() async throws {
        let harness = try AppModelHarness()
        await harness.model.setPolicy(.auto, for: ProviderID.npm)
        #expect(harness.model.policyRules.rule(for: .npm)?.policy == .auto)

        await harness.model.setProviderEnabled(false, for: .npm)
        let change = try #require(harness.model.lastPolicyChange)
        #expect(change.path == "providers.npm.enabled")
        #expect(change.newValue == "false")
        #expect(harness.model.policyRules.rule(for: .npm)?.enabled == false)
    }

    @Test("The global default can be changed, and the listing agrees with the engine")
    func globalDefault() async throws {
        let harness = try AppModelHarness()
        await harness.model.setDefaultPolicy(.auto)

        #expect(harness.model.policyProblem == nil)
        #expect(harness.model.policyRules.defaultPolicy == .auto)
        #expect(harness.model.lastPolicyChange?.path == "global.defaultPolicy")
    }

    @Test("A rule the editor would refuse leaves the file alone and says why")
    func aRefusedRuleChangesNothing() async throws {
        let harness = try AppModelHarness()
        // Pin applies to individual items, never to a whole provider, and the
        // validator refuses it. The app does not check this itself; it shows
        // the editor's refusal.
        await harness.model.setPolicy(.pin, for: ProviderID.homebrew)

        let problem = try #require(harness.model.policyProblem)
        #expect(problem.contains("Pin applies to individual items"))
        #expect(harness.model.lastPolicyChange == nil)
        #expect(harness.model.policyRules.rule(for: .homebrew)?.policy != .pin)
    }

    @Test("MacUp refuses to edit a configuration it could not read, and says so")
    func aConfigurationWithErrorsIsNotEdited() async throws {
        let harness = try AppModelHarness()
        try FileManager.default.createDirectory(
            atPath: (harness.paths.configFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        // An unrecognized key is an error, and rewriting the file would drop
        // it along with whatever the user meant by it.
        try Data(#"{"schemaVersion": 1, "somethingMacUpDoesNotKnow": true}"#.utf8)
            .write(to: URL(fileURLWithPath: harness.paths.configFile))
        harness.model.loadConfiguration()

        await harness.model.setPolicy(.ignore, for: Self.git)

        let problem = try #require(harness.model.policyProblem)
        #expect(problem.contains("could not read every rule"))
        #expect(harness.model.lastPolicyChange == nil)
        // No approval was asked for a change that could never happen.
        #expect(harness.authorizer.requestedReasons.isEmpty)
        let text = try String(contentsOf: URL(fileURLWithPath: harness.paths.configFile), encoding: .utf8)
        #expect(text.contains("somethingMacUpDoesNotKnow"))
    }

    @Test("Refused approval leaves the rule exactly as it was")
    func refusedApprovalChangesNoRule() async throws {
        let harness = try AppModelHarness()
        try harness.save(security: MacUpConfiguration.SecuritySettings(requireApproval: true))
        harness.model.loadConfiguration()
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        await harness.model.setPolicy(.ignore, for: Self.git)

        #expect(harness.model.policyProblem == "You cancelled, so nothing was changed.")
        #expect(harness.model.lastPolicyChange == nil)
        #expect(harness.model.policyRules.rule(for: Self.git) == nil)
        #expect(harness.authorizer.requestedReasons == ["set the rule for brew:git"])
    }

    @Test("Pin from the app holds an item the way the CLI's pin does, with no pin of the provider's own")
    func pinHoldsAnItemWithoutANativePin() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        await harness.model.checkNow()
        #expect(!harness.model.capabilities(of: .homebrew).contains(.nativePin))

        await harness.model.setPolicy(.pin, for: Self.git)

        #expect(harness.model.policyProblem == nil)
        let decision = try #require(harness.model.decisions[Self.git])
        #expect(decision.policy == .pin)
        #expect(decision.action == .deny)
        // Written where `macup policy list` reads it.
        let listing = PolicyListing(ConfigurationStore(paths: harness.paths).load())
        #expect(listing.rule(for: Self.git)?.policy == .pin)
    }

    @Test("A provider that only reports updates is not offered as one MacUp can apply")
    func applyingFollowsTheProviderCapability() async throws {
        let reporting = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")],
            canApplyUpdates: false
        ))
        await reporting.model.checkNow()
        #expect(!reporting.model.canApplyUpdates(of: .homebrew))

        let applying = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        await applying.model.checkNow()
        #expect(applying.model.canApplyUpdates(of: .homebrew))

        // A provider that was never checked is not assumed to apply anything.
        #expect(!applying.model.canApplyUpdates(of: .macos))
    }

    @Test("What policy decides is available after a check, with the reason")
    func decisionsAreAvailableWithReasons() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:wget"),
            PlannedUpdateFactory.candidate("brew:node", signals: [.pinnedByProvider]),
        ]))
        try harness.rule(.ignore, for: try PackageID(parsing: "brew:wget"))
        await harness.model.checkNow()

        let decisions = harness.model.decisions
        #expect(decisions.count == 3)
        #expect(decisions[Self.git]?.action == .confirm)
        #expect(decisions[try PackageID(parsing: "brew:wget")]?.action == .deny)
        #expect(decisions[try PackageID(parsing: "brew:node")]?.source == .providerPin)
        // Every decision can say why, because that is what makes it reviewable.
        #expect(decisions.values.allSatisfy { !$0.reason.isEmpty })

        #expect(harness.model.updatesNeedingConfirmation == 1)
        #expect(harness.model.ignoredUpdateCount == 1)
        #expect(harness.model.pinnedUpdateCount == 1)
    }
}
