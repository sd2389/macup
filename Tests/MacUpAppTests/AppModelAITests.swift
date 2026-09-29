import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("AI help in the app")
@MainActor
struct AppModelAITests {
    /// Obviously not a real key; no test has or needs one.
    static let key = "ts_test_not_a_real_key_0123456789"
    static let mysql = try! PackageID(parsing: "brew:mysql")

    struct Setup {
        let harness: AppModelHarness
        let transport: FakeTypeSafeTransport
        let store: FakeAPIKeyStore
        var model: AppModel { harness.model }
    }

    private func setup(
        store: FakeAPIKeyStore = FakeAPIKeyStore(key: AppModelAITests.key),
        answers: FakeTypeSafeTransport.Handler? = nil
    ) throws -> Setup {
        let transport = FakeTypeSafeTransport()
        if let answers { transport.answerEveryRequest(answers) }
        let harness = try AppModelHarness(
            planning: StubPlanningProvider(candidates: [
                PlannedUpdateFactory.candidate("brew:mysql", installed: "8.4.3", available: "9.1.0"),
            ]),
            ai: AIService(transport: transport, keyStore: store, estimates: { AIEstimateFile(paths: $0) }, sleep: { _ in })
        )
        return Setup(harness: harness, transport: transport, store: store)
    }

    private func turnOn(_ setup: Setup) throws {
        try AISettingsEditor(paths: setup.harness.paths).setEnabled(true)
        setup.model.loadConfiguration()
    }

    static let stopUpdatingMySQL = TypeSafeReply.answering(choose: { id, _ in
        switch id {
        case "action": ("set_item_policy", 0.97)
        case "item": ("brew:mysql", 0.96)
        case "item_policy": ("ignore", 0.94)
        default: nil
        }
    })

    static let databaseEstimate = TypeSafeReply.answering(
        choose: { id, _ in id == "software_kind" ? ("database", 0.93) : nil },
        noul: { _ in 0.91 }
    )

    // MARK: Off

    @Test("With AI help off, nothing AI is shown or kept, and nothing is sent")
    func offMeansOff() async throws {
        let setup = try setup(answers: Self.stopUpdatingMySQL)
        await setup.model.checkNow()
        #expect(!setup.model.isAIOn)
        #expect(setup.model.report?.providers.allSatisfy { $0.items == nil } == true, "the check is the plain one")

        setup.model.ai.askText = "stop updating mysql"
        await setup.model.askMacUp()
        #expect(setup.model.ai.askProblem == "AI help from TypeSafe is off, so MacUp sent nothing.")
        let update = try #require(setup.model.report?.updates.first)
        await setup.model.estimate(update)
        #expect(setup.model.ai.estimateProblems[update.id] != nil)
        await setup.model.testAIConnection()

        #expect(setup.transport.requests.isEmpty)
        #expect(setup.store.reads == 0, "the key itself was never read")
    }

    // MARK: Settings

    @Test("Turning AI help on shows what it sends first, and waits for approval when that is required")
    func enabling() async throws {
        let setup = try setup()
        setup.model.requestAIEnabled(true)
        #expect(setup.model.ai.isShowingEnableSheet)
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.ai == nil, "the switch alone changes nothing")

        try setup.harness.save(security: MacUpConfiguration.SecuritySettings(requireApproval: true))
        setup.harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        await setup.model.setAIEnabled(true)
        #expect(!ConfigurationStore(paths: setup.harness.paths).load().configuration.aiSettings.enabled)
        #expect(setup.model.ai.settingsProblem != nil)

        setup.harness.authorizer.set(outcome: .approved(.touchID))
        await setup.model.setAIEnabled(true)
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.aiSettings.enabled)
        #expect(!setup.model.ai.isShowingEnableSheet)
        #expect(setup.model.isAIOn)

        await setup.model.setAIEnabled(false)
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.ai == nil)
        #expect(setup.transport.requests.isEmpty, "turning AI help on and off sends nothing")
    }

    @Test("A pasted key goes to the Keychain, is never shown again, and can be cleared")
    func keys() async throws {
        let store = FakeAPIKeyStore()
        let setup = try setup(store: store)
        #expect(await setup.model.saveAIKey("not a key") == false)
        #expect(setup.model.ai.settingsProblem?.contains("does not look like a TypeSafe API key") == true)
        #expect(store.key == nil)

        #expect(await setup.model.saveAIKey("  \(Self.key)\n"))
        #expect(store.key == (try TypeSafeAPIKey(validating: Self.key)))
        #expect(setup.model.ai.status?.key.keychainHasKey == true)
        let summary = setup.model.ai.status?.summary ?? ""
        #expect(summary.contains(Self.key) == false)

        await setup.model.clearAIKey()
        #expect(store.key == nil)
        #expect(setup.model.ai.status?.key.source == nil)
    }

    // MARK: Ask MacUp

    @Test("Ask MacUp proposes an exact change and makes it only when confirmed, through PolicyEditor")
    func ask() async throws {
        let setup = try setup(answers: Self.stopUpdatingMySQL)
        try turnOn(setup)
        await setup.model.checkNow()

        setup.model.ai.askText = "stop updating mysql"
        await setup.model.askMacUp()
        let proposal = try #require(setup.model.ai.interpretation?.proposal)
        #expect(proposal.change == .setItemPolicy(Self.mysql, .ignore))
        #expect(proposal.path == "items.brew:mysql.policy")
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.items.isEmpty, "asking changed nothing")

        setup.model.cancelAsk()
        #expect(setup.model.ai.interpretation == nil)
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.items.isEmpty)

        await setup.model.askMacUp()
        await setup.model.confirmAsk(try #require(setup.model.ai.interpretation?.proposal))
        #expect(ConfigurationStore(paths: setup.harness.paths).load().configuration.items[Self.mysql.rawValue]?.policy == .ignore)
        #expect(setup.model.ai.appliedSummary == setup.model.lastPolicyChange?.summary)
        #expect(setup.model.lastPolicyChange?.path == "items.brew:mysql.policy")
        #expect(setup.transport.requests.count == 2)
        #expect(setup.harness.runner.recordedRequests.allSatisfy { $0.effect == .readOnly }, "nothing on the Mac was changed")
    }

    // MARK: AI caution

    @Test("An estimate makes an Auto Update item ask first everywhere; clearing it, or turning AI off, takes that away")
    func caution() async throws {
        let setup = try setup(answers: Self.databaseEstimate)
        try turnOn(setup)
        var configuration = ConfigurationStore(paths: setup.harness.paths).load().configuration
        configuration.global.confirmMajorUpdates = false
        configuration.items[Self.mysql.rawValue] = MacUpConfiguration.ItemSettings(policy: .auto)
        try ConfigurationStore(paths: setup.harness.paths).save(configuration)
        await setup.model.checkNow()
        #expect(setup.model.decisions[Self.mysql]?.action == .allow)

        let update = try #require(setup.model.report?.updates.first)
        await setup.model.estimate(update)
        let caution = try #require(setup.model.ai.estimates[Self.mysql]?.caution)
        #expect(caution.note.hasPrefix("AI estimate from TypeSafe, 91%: mysql looks like a database"))
        #expect(setup.model.decisions[Self.mysql]?.action == .confirm)
        #expect(setup.model.decisions[Self.mysql]?.reason == "An AI estimate from TypeSafe says updating mysql needs extra care, so it asks first.")
        #expect(setup.model.report?.updates.first?.notes.contains(caution.note) == true)
        #expect(setup.transport.requests.count == 1)

        // The next check keeps the caution without asking again.
        await setup.model.checkNow()
        #expect(setup.model.decisions[Self.mysql]?.action == .confirm)
        #expect(setup.transport.requests.count == 1)

        await setup.model.setAIEnabled(false)
        #expect(setup.model.decisions[Self.mysql]?.action == .allow, "with AI help off, MacUp behaves as though it never asked")

        try turnOn(setup)
        setup.model.reapplyAICautions()
        #expect(setup.model.decisions[Self.mysql]?.action == .confirm)
        setup.model.forgetAIEstimates()
        #expect(setup.model.decisions[Self.mysql]?.action == .allow)
        #expect(setup.model.ai.savedEstimateCount == 0)
    }
}
