import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Skipping a version and keeping a note from the app")
@MainActor
struct AppModelSkipAndNoteTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let mysql = try! PackageID(parsing: "brew:mysql")

    private func checked(mysqlOffers available: String = "1.0.1") async throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:mysql", available: available),
        ]))
        await harness.model.checkNow()
        return harness
    }

    /// The rules as the CLI would read them from the throwaway home.
    private func fileRule(_ harness: AppModelHarness, _ item: PackageID) -> PolicyListing.ItemRule? {
        PolicyListing(ConfigurationStore(paths: harness.paths).load()).rule(for: item)
    }

    @Test("Skip This Version writes the version the check found, and the update moves under Ignored and Held")
    func skipFromTheApp() async throws {
        let harness = try await checked()
        let offered = try #require(harness.model.offeredVersion(of: Self.mysql))
        #expect(offered.raw == "1.0.1")

        await harness.model.skipVersion(offered, for: Self.mysql)

        #expect(harness.model.policyProblem == nil)
        #expect(harness.model.lastPolicyChange?.setting == .skipVersion)
        #expect(harness.model.lastPolicyChange?.path == "items.brew:mysql.skipVersion")
        #expect(fileRule(harness, Self.mysql)?.skipVersion == "1.0.1", "written where `macup policy list` reads it")

        let decision = try #require(harness.model.decisions[Self.mysql])
        #expect(decision.action == .deny)
        #expect(decision.source == .skippedVersion)
        #expect(decision.reason == "You skipped mysql 1.0.1. MacUp will offer the next version.")

        #expect(harness.model.pendingUpdates.map(\.id) == [Self.git])
        #expect(harness.model.leftAloneUpdates.map(\.id) == [Self.mysql])
        #expect(harness.model.skippedUpdateCount == 1)
        #expect(harness.model.ignoredUpdateCount == 0, "a skip is not an Ignore rule")
        #expect(harness.model.pinnedUpdateCount == 0)
        #expect(harness.model.heldRulesWithoutUpdate.isEmpty)
    }

    @Test("Stop Skipping brings the update back under its rule")
    func stopSkipping() async throws {
        let harness = try await checked()
        await harness.model.skipVersion("1.0.1", for: Self.mysql)
        await harness.model.stopSkipping(Self.mysql)

        #expect(harness.model.lastPolicyChange?.previousValue == "1.0.1")
        #expect(harness.model.decisions[Self.mysql]?.action == .confirm)
        #expect(harness.model.pendingUpdates.map(\.id) == [Self.git, Self.mysql])
        #expect(harness.model.skippedUpdateCount == 0)
        #expect(fileRule(harness, Self.mysql) == nil)
    }

    @Test("A different version on offer brings the item back by itself")
    func aDifferentVersionComesBack() async throws {
        let harness = try await checked(mysqlOffers: "1.0.2")
        try PolicyEditor(paths: harness.paths).skipVersion("1.0.1", for: Self.mysql)
        await harness.model.checkNow()

        #expect(harness.model.decisions[Self.mysql]?.action == .confirm)
        #expect(harness.model.pendingUpdates.map(\.id).contains(Self.mysql))
        #expect(harness.model.skippedUpdateCount == 0)
        // Nothing needed undoing; the old skip is still there and inert.
        #expect(harness.model.policyRules.rule(for: Self.mysql)?.skipVersion == "1.0.1")
    }

    @Test("A note is saved as written, travels with the decision, and can be removed")
    func noteFromTheApp() async throws {
        let harness = try await checked()
        let note = "  waiting for PHP 8.4 — \"see issue\" "
        await harness.model.setNote(note, for: Self.mysql)

        #expect(harness.model.policyProblem == nil)
        #expect(harness.model.lastPolicyChange?.setting == .note)
        #expect(fileRule(harness, Self.mysql)?.note == note)
        #expect(harness.model.decisions[Self.mysql]?.note == note)
        // A note decides nothing: the update is as pending as it was.
        #expect(harness.model.decisions[Self.mysql]?.action == .confirm)

        await harness.model.clearNote(for: Self.mysql)
        #expect(fileRule(harness, Self.mysql) == nil)
        #expect(harness.model.decisions[Self.mysql]?.note == nil)
    }

    @Test("A note the editor refuses leaves the file alone and says why")
    func tooLongNoteIsRefused() async throws {
        let harness = try await checked()
        await harness.model.setNote(String(repeating: "x", count: 201), for: Self.mysql)

        let problem = try #require(harness.model.policyProblem)
        #expect(problem.contains("A note can be at most 200 characters; this one has 201."))
        #expect(harness.model.lastPolicyChange == nil)
        #expect(fileRule(harness, Self.mysql) == nil)
        // The app checks with the same rule before offering Save.
        #expect(MacUpConfiguration.ItemSettings.problem(withNote: String(repeating: "x", count: 201)) != nil)
    }

    @Test("Changing or clearing the rule keeps the skip and the note")
    func ruleChangesKeepSkipAndNote() async throws {
        let harness = try await checked()
        await harness.model.skipVersion("1.0.1", for: Self.mysql)
        await harness.model.setNote("waiting for PHP 8.4 support", for: Self.mysql)

        await harness.model.setPolicy(.pin, for: Self.mysql)
        #expect(harness.model.decisions[Self.mysql]?.policy == .pin, "a pinned item stays pinned, skip or no skip")
        #expect(harness.model.decisions[Self.mysql]?.source == .item)

        await harness.model.clearPolicy(for: Self.mysql)
        let rule = try #require(fileRule(harness, Self.mysql))
        #expect(rule.policy == .inherit)
        #expect(rule.skipVersion == "1.0.1")
        #expect(rule.note == "waiting for PHP 8.4 support")
        #expect(harness.model.decisions[Self.mysql]?.source == .skippedVersion, "clearing the pin did not bring back the skipped version")
    }

    @Test("Refused approval skips nothing, and the prompt names the version")
    func skipNeedsApproval() async throws {
        let harness = try await checked()
        try harness.save(security: MacUpConfiguration.SecuritySettings(requireApproval: true))
        harness.model.loadConfiguration()
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        await harness.model.skipVersion("1.0.1", for: Self.mysql)

        #expect(harness.model.policyProblem == "You cancelled, so nothing was changed.")
        #expect(harness.authorizer.requestedReasons == ["skip brew:mysql 1.0.1"])
        #expect(fileRule(harness, Self.mysql) == nil)
        #expect(harness.model.skippedUpdateCount == 0)
    }

    @Test("A version skipped after the review is not run when Apply is pressed")
    func skipAfterReviewIsObeyed() async throws {
        let harness = try await checked()
        harness.allowUpdate(of: "mysql")
        await harness.model.reviewUpdates()
        harness.model.setConfirmed(true, for: Self.mysql)
        #expect(harness.model.itemsThatWouldRun.map(\.item) == [Self.mysql])

        // Skipped from somewhere else — the CLI, say — while the sheet was open.
        try PolicyEditor(paths: harness.paths).skipVersion("1.0.1", for: Self.mysql)
        await harness.applyAndWait()

        #expect(harness.launchedExecutables.isEmpty, "the engine re-reads policy before each item")
        let skipped = try #require(harness.model.executionReport?.skipped.first { $0.item == Self.mysql })
        #expect(skipped.decision?.source == .skippedVersion)
        let history = try harness.recordedHistory()
        #expect(history.contains { $0.item == Self.mysql && $0.outcome == .skipped })
    }

    @Test("Only a version the check found can be skipped from the app")
    func onlyOfferedVersions() async throws {
        let harness = try await checked()
        #expect(harness.model.offeredVersion(of: try PackageID(parsing: "brew:wget")) == nil)
        #expect(harness.model.offeredVersion(of: Self.git)?.raw == "1.0.1")
    }
}
