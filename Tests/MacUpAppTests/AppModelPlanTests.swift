import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the review sheet is given to show")
@MainActor
struct AppModelPlanTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let wget = try! PackageID(parsing: "brew:wget")
    private static let node = try! PackageID(parsing: "brew:node")

    private func harness(_ names: [String] = ["brew:git", "brew:wget"]) throws -> AppModelHarness {
        try AppModelHarness(planning: StubPlanningProvider(
            candidates: names.map { PlannedUpdateFactory.candidate($0) }
        ))
    }

    @Test("A plan carries the exact executable and argument list, not a sentence about it")
    func planCarriesTheExactCommand() async throws {
        let harness = try harness(["brew:git"])
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        let planned = try #require(plan.planned.first)
        let step = try #require(planned.plan.steps.first)
        #expect(step.invocation.executable == StubPlanningProvider.executable)
        #expect(step.invocation.arguments == StubPlanningProvider.arguments(for: "git"))
        #expect(step.effect == .modifying)
        // Planning describes; it never launches.
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("An ignored item never enters the plan, and is listed with the reason instead")
    func ignoredItemsAreSkippedAndShown() async throws {
        let harness = try harness()
        try harness.rule(.ignore, for: Self.wget)
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        #expect(plan.planned.map(\.item) == [Self.git])
        let skip = try #require(plan.skipped.first { $0.item == Self.wget })
        #expect(skip.decision?.action == .deny)
        #expect(skip.reason.contains("is ignored"))
        // It is still visible as the decision the user made.
        #expect(plan.skipped.count == 1)
        #expect(!harness.model.itemsThatWouldRun.contains { $0.item == Self.wget })
    }

    @Test("An item held at its current version never enters the plan either")
    func pinnedItemsAreSkippedAndShown() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:node", signals: [.pinnedByProvider]),
        ]))
        try harness.rule(.pin, for: Self.git)
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        #expect(plan.planned.isEmpty)
        #expect(Set(plan.skipped.map(\.item)) == [Self.git, Self.node])
        #expect(plan.skipped.first { $0.item == Self.git }?.reason.contains("held at its current version") == true)
        // MacUp never unpins what the provider pinned.
        #expect(plan.skipped.first { $0.item == Self.node }?.reason.contains("does not unpin it for you") == true)
        #expect(harness.model.itemsThatWouldRun.isEmpty)
    }

    @Test("An item MacUp cannot plan is reported with the provider's own error, never guessed at")
    func unplannableItemsCarryTheirError() async throws {
        let provider = StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:wget"),
        ])
        provider.refusePlan(
            for: Self.wget,
            MacUpError(.unsupported, "This provider has no plan for wget.", recoverySuggestion: "Update it yourself.")
        )
        let harness = try AppModelHarness(planning: provider)
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        #expect(plan.planned.map(\.item) == [Self.git])
        let skip = try #require(plan.skipped.first { $0.item == Self.wget })
        #expect(skip.error?.message.contains("no plan for wget") == true)
        #expect(plan.summary.unplannable == 1)
    }

    @Test("Reviewing one item plans that item and nothing else")
    func reviewingOneItem() async throws {
        let harness = try harness()
        await harness.model.checkNow()
        await harness.model.reviewUpdates([Self.git])

        let plan = try #require(harness.model.updatePlan)
        #expect(plan.planned.map(\.item) == [Self.git])
        #expect(plan.skipped.isEmpty)
        #expect(harness.model.isReviewingPlan)
    }

    @Test("Nothing that needs confirming counts towards what Apply would change until it is confirmed")
    func confirmationDecidesWhatWouldRun() async throws {
        let harness = try harness()
        // Ask First by default, so both items wait for a person.
        await harness.reviewEverything()

        #expect(harness.model.itemsAwaitingConfirmation.count == 2)
        #expect(harness.model.itemsThatWouldRun.isEmpty)

        harness.model.setConfirmed(true, for: Self.git)
        #expect(harness.model.itemsThatWouldRun.map(\.item) == [Self.git])

        harness.model.setConfirmed(false, for: Self.git)
        #expect(harness.model.itemsThatWouldRun.isEmpty)
    }

    @Test("An item set to update automatically needs no confirmation")
    func autoItemsAreAllowedOutright() async throws {
        let harness = try harness(["brew:git"])
        try harness.rule(.auto, for: Self.git)
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        #expect(plan.allowed.map(\.item) == [Self.git])
        #expect(plan.needingConfirmation.isEmpty)
        #expect(harness.model.itemsThatWouldRun.map(\.item) == [Self.git])
    }

    @Test("Asking to review before any check says so rather than showing an empty plan")
    func reviewBeforeAnyCheck() async throws {
        let harness = try harness()
        await harness.model.reviewUpdates()

        #expect(harness.model.updatePlan == nil)
        #expect(!harness.model.isReviewingPlan)
        #expect(harness.model.planProblem?.contains("has not checked this Mac yet") == true)
    }

    @Test("The command for one item can be read on its own, without opening a review")
    func viewingOneCommand() async throws {
        let harness = try harness(["brew:git"])
        await harness.model.checkNow()
        await harness.model.showCommand(for: Self.git)

        #expect(harness.model.isShowingCommand)
        #expect(!harness.model.isReviewingPlan)
        let planned = try #require(harness.model.commandPlan?.planned.first)
        #expect(planned.plan.steps.first?.invocation.arguments == StubPlanningProvider.arguments(for: "git"))
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("The command view says why there is no command, when there is none")
    func viewingACommandThatDoesNotExist() async throws {
        let harness = try harness(["brew:git"])
        try harness.rule(.ignore, for: Self.git)
        await harness.model.checkNow()
        await harness.model.showCommand(for: Self.git)

        #expect(harness.model.commandPlan?.planned.isEmpty == true)
        #expect(harness.model.commandPlan?.skipped.first?.reason.contains("is ignored") == true)
    }

    @Test("What a batch declares about itself is counted from the plans, not assumed")
    func batchEffectsComeFromThePlans() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:node", signals: [.restartRequired, .administratorAuthorizationMayBeRequired]),
        ]))
        try harness.rule(.auto, for: Self.git)
        try harness.rule(.auto, for: Self.node)
        await harness.reviewEverything()

        let plan = try #require(harness.model.updatePlan)
        let effects = PlanEffects(plan.planned)
        #expect(effects.total == 2)
        #expect(effects.restart == 1)
        #expect(effects.privilege == 1)
        #expect(effects.network == 2)
        // Rollback is never claimed without a tested strategy.
        #expect(effects.rollbackAvailable == 0)
        #expect(effects.rollbackUnknown == 0)
    }
}
