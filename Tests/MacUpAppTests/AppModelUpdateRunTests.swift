import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Applying a plan from the app")
@MainActor
struct AppModelUpdateRunTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let wget = try! PackageID(parsing: "brew:wget")

    /// A Mac with two updates, the first set to update automatically and the
    /// second left at Ask First, which is what most reviews look like.
    private func harness(
        _ names: [String] = ["brew:git", "brew:wget"],
        auto: [String] = ["brew:git"],
        security: MacUpConfiguration.SecuritySettings? = nil
    ) throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: names.map { PlannedUpdateFactory.candidate($0) }
        ))
        // Security first: saving it writes a whole configuration, so a rule
        // set before it would be lost.
        if let security { try harness.save(security: security) }
        for name in auto {
            try harness.rule(.auto, for: try PackageID(parsing: name))
        }
        harness.model.loadConfiguration()
        for name in names {
            harness.allowUpdate(of: try PackageID(parsing: name).name)
        }
        return harness
    }

    @Test("An update that worked and was confirmed is recorded as the app's own")
    func aSuccessfulUpdateIsVerifiedAndRecorded() async throws {
        let harness = try harness(["brew:git"])
        await harness.reviewEverything()
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.origin == .gui)
        #expect(!report.dryRun)
        #expect(report.summary.attempted == 1)
        #expect(report.summary.succeeded == 1)
        #expect(report.summary.verified == 1)
        #expect(report.summary.unverified == 0)

        let executed = try #require(report.executed.first)
        #expect(executed.verification?.outcome == .verified)
        #expect(OutcomeLabel.wording(executed.result.outcome, executed.verification?.outcome).text
            == "Updated and confirmed")

        // The command that ran is the one the plan showed, and nothing else.
        #expect(harness.runner.recordedInvocations.map(\.arguments)
            == [StubPlanningProvider.arguments(for: "git")])

        let history = try harness.recordedHistory()
        #expect(history.count == 1)
        #expect(history.first?.origin == .gui)
        #expect(history.first?.outcome == .succeeded)
        #expect(history.first?.verification == .verified)
        #expect(history.first?.versionAfter == "1.0.1")
    }

    @Test("A success MacUp could not confirm is never shown as confirmed")
    func anUnverifiedSuccessIsNotCalledVerified() async throws {
        let harness = try harness(["brew:git"])
        harness.planning?.verifies(.failed)
        await harness.reviewEverything()
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.summary.succeeded == 1)
        #expect(report.summary.verified == 0)
        #expect(report.summary.unverified == 1)

        let executed = try #require(report.executed.first)
        #expect(executed.verification?.outcome == .failed)
        let wording = OutcomeLabel.wording(executed.result.outcome, executed.verification?.outcome)
        #expect(wording.text == "Succeeded, but MacUp could not confirm it")
        #expect(wording.isGood == false)
        #expect(try harness.recordedHistory().first?.versionAfter == nil)
    }

    @Test("An update that reached a different version says which one")
    func aDifferentVersionIsReportedAsSuch() async throws {
        let harness = try harness(["brew:git"])
        harness.planning?.verifies(.targetNotReached, observed: "1.0.0")
        await harness.reviewEverything()
        await harness.applyAndWait()

        let executed = try #require(harness.model.executionReport?.executed.first)
        #expect(executed.verification?.observedVersion == "1.0.0")
        #expect(OutcomeLabel.wording(executed.result.outcome, executed.verification?.outcome).text
            == "Ran, but a different version is installed")
    }

    @Test("A failure carries the provider's own words, and what MacUp found when it read the item back")
    func aFailureCarriesTheProvidersError() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        try harness.rule(.auto, for: Self.git)
        harness.allowUpdate(of: "git", .exit(1, standardError: "Error: git could not be linked."))
        harness.planning?.verifies(.targetNotReached, observed: "1.0.0")
        await harness.reviewEverything()
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.hasFailures)
        #expect(report.summary.failed == 1)
        #expect(report.summary.verified == 0)
        let executed = try #require(report.executed.first)
        #expect(executed.result.outcome == .failed)
        let error = try #require(executed.result.error)
        #expect(error.detail?.contains("could not be linked") == true)
        // Read back, because a command that failed part-way can leave the
        // item changed; never counted as confirmed.
        #expect(executed.verification?.outcome == .targetNotReached)
        let entry = try #require(try harness.recordedHistory().first)
        #expect(entry.outcome == .failed)
        #expect(entry.versionAfter == "1.0.0")
        #expect(entry.headline.text == "Failed — git was not updated")
    }

    @Test("An item waiting for confirmation is left alone until it is confirmed")
    func anUnconfirmedItemDoesNotRun() async throws {
        let harness = try harness()
        await harness.reviewEverything()
        #expect(harness.model.itemsThatWouldRun.map(\.item) == [Self.git])

        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.executed.map(\.item) == [Self.git])
        let skip = try #require(report.skipped.first { $0.item == Self.wget })
        #expect(skip.reason.contains("not confirmed"))
        // The skip is part of what MacUp did, so it is recorded too.
        let history = try harness.recordedHistory()
        #expect(history.contains { $0.item == Self.wget && $0.outcome == .skipped })

        // Confirming it is what lets it run.
        harness.model.setConfirmed(true, for: Self.wget)
        await harness.applyAndWait()
        #expect(harness.model.executionReport?.executed.contains { $0.item == Self.wget } == true)
    }

    @Test("A batch with nothing confirmed starts nothing at all")
    func nothingConfirmedStartsNothing() async throws {
        let harness = try harness(auto: [])
        await harness.reviewEverything()
        #expect(harness.model.itemsThatWouldRun.isEmpty)

        await harness.applyAndWait()

        #expect(harness.model.applyTask == nil)
        #expect(harness.model.executionReport == nil)
        #expect(harness.launchedExecutables.isEmpty)
        #expect(try harness.recordedHistory().isEmpty)
    }

    @Test("Refused approval means nothing ran and nothing was recorded")
    func refusedApprovalChangesNothing() async throws {
        let harness = try harness(["brew:git"], security: .init(requireApproval: true))
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        await harness.reviewEverything()
        await harness.applyAndWait()

        #expect(harness.model.executionProblem == "You cancelled, so nothing was changed.")
        #expect(harness.model.executionReport == nil)
        #expect(harness.launchedExecutables.isEmpty)
        #expect(try harness.recordedHistory().isEmpty)
        #expect(harness.authorizer.requestedReasons == ["apply one update on this Mac"])
    }

    @Test("Approval MacUp could not ask for stops the batch rather than skipping the question")
    func unavailableApprovalStopsTheBatch() async throws {
        let harness = try harness(["brew:git"], security: .init(requireApproval: true))
        harness.authorizer.set(outcome: .unavailable("This Mac cannot ask you to confirm right now."))
        await harness.reviewEverything()
        await harness.applyAndWait()

        #expect(harness.model.executionProblem == "This Mac cannot ask you to confirm right now.")
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("Cancelling says the run was stopped, and never that it succeeded")
    func cancellationIsReportedHonestly() async throws {
        let harness = try harness(["brew:git", "brew:wget"], auto: ["brew:git", "brew:wget"])
        await harness.reviewEverything()

        // Held inside detection, which the engine does before it launches
        // anything, so the cancellation lands while the batch is underway.
        let rendezvous = Rendezvous()
        harness.planning?.detectRendezvous = rendezvous
        harness.model.applyReviewedPlan()
        await rendezvous.waitUntilReached()
        harness.model.cancelApply()
        rendezvous.open()
        await harness.model.applyTask?.value

        let report = try #require(harness.model.executionReport)
        #expect(report.cancelled)
        #expect(report.summary.succeeded == 0)
        #expect(report.summary.verified == 0)
        #expect(harness.launchedExecutables.isEmpty)

        let executed = try #require(report.executed.first)
        #expect(executed.result.outcome == .cancelled)
        #expect(OutcomeLabel.wording(executed.result.outcome, executed.verification?.outcome).text
            == "Stopped before it finished")
        // Everything behind the cancellation is left alone, and says why.
        #expect(report.skipped.contains { $0.item == Self.wget && $0.reason.contains("cancelled") })
        #expect(!harness.model.isApplying)
        #expect(harness.model.runningItem == nil)
    }

    @Test("Stop while an update runs lets it finish and be confirmed, and starts nothing after it")
    func stopLetsTheRunningUpdateFinish() async throws {
        let harness = try harness(["brew:git", "brew:wget"], auto: ["brew:git", "brew:wget"])
        // git's upgrade takes a moment, as a real one does.
        harness.allowUpdate(of: "git", FakeCommandRunner.Response(standardOutput: "==> Upgrading git\n", delay: .milliseconds(400)))
        await harness.reviewEverything()

        harness.model.applyReviewedPlan()
        while harness.model.runningItem != Self.git { await Task.yield() }
        harness.model.cancelApply()
        #expect(harness.model.isStopRequested)
        await harness.model.applyTask?.value

        let report = try #require(harness.model.executionReport)
        let git = try #require(report.executed.first { $0.item == Self.git })
        #expect(git.result.outcome == .succeeded, "the running update was not cut short")
        #expect(git.verification?.outcome == .verified)
        #expect(report.skipped.contains { $0.item == Self.wget && $0.reason.contains("cancelled") })
        #expect(harness.runner.recordedRequests.filter { $0.effect == .modifying }.count == 1, "wget never started")
        #expect(harness.model.runningOutput.recent == ["==> Upgrading git"])
        #expect(!harness.model.isStopRequested, "Stop is forgotten once the run is over")
        #expect(try harness.recordedHistory().contains { $0.item == Self.git && $0.outcome == .succeeded })
    }

    @Test("A plan whose provider MacUp can no longer find is skipped, not run")
    func anUndetectableProviderIsSkipped() async throws {
        let harness = try harness(["brew:git"])
        await harness.reviewEverything()
        harness.planning?.becomesUndetectable()
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.reason.contains("could not find the Homebrew installation") == true)
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("Progress names the item being updated and counts what has started")
    func progressIsReportedPerItem() async throws {
        let harness = try harness(["brew:git", "brew:wget"], auto: ["brew:git", "brew:wget"])
        await harness.reviewEverything()
        await harness.applyAndWait()

        // One entry per item, in the order the engine ran them, and no item
        // is counted twice.
        #expect(harness.model.startedItems == [Self.git, Self.wget])
        #expect(harness.model.runningItem == nil)
        #expect(!harness.model.isApplying)
    }

    @Test("An ignored item cannot be applied even when it is named directly")
    func anIgnoredItemCannotBeApplied() async throws {
        let harness = try harness(["brew:git"])
        try harness.rule(.ignore, for: Self.git)
        await harness.model.checkNow()
        await harness.model.reviewUpdates([Self.git])
        await harness.applyAndWait()

        #expect(harness.model.updatePlan?.planned.isEmpty == true)
        #expect(harness.model.executionReport == nil)
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("A provider that only reports updates never has one of its plans run")
    func aReportOnlyProviderIsNotApplied() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")],
            canApplyUpdates: false
        ))
        try harness.rule(.auto, for: Self.git)
        harness.allowUpdate(of: "git")
        await harness.reviewEverything()
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.item == Self.git)
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("A rule changed after the review is obeyed, not the one the plan was built with")
    func policyIsRereadImmediatelyBeforeExecution() async throws {
        let harness = try harness(["brew:git"])
        await harness.reviewEverything()
        #expect(harness.model.itemsThatWouldRun.map(\.item) == [Self.git])

        // The plan said this item may run. The rule says otherwise now.
        try harness.rule(.ignore, for: Self.git)
        await harness.applyAndWait()

        let report = try #require(harness.model.executionReport)
        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.reason.contains("is ignored") == true)
        #expect(harness.launchedExecutables.isEmpty)
    }
}
