import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A skipped version through planning and execution: the planner leaves it
/// out, and the engine's re-read before each item honours a skip added after
/// the plan was built (CLAUDE.md §2.20). Nothing here touches the host.
@Suite("Skipped versions in plans and runs", .timeLimit(.minutes(1)))
struct SkippedVersionExecutionTests {
    private static let git = try! PackageID(parsing: "brew:git")

    private func configuration(_ items: [String: MacUpConfiguration.ItemSettings]) -> MacUpConfiguration {
        MacUpConfiguration(
            providers: Dictionary(uniqueKeysWithValues: ProviderID.known.map { ($0.rawValue, .init()) }),
            items: items
        )
    }

    private func gitPlan(action: PolicyDecision.Action = .allow, policy: UpdatePolicy = .auto) -> PlanReport {
        PlannedUpdateFactory.report([PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.50.1"),
            steps: [ExecutionHarness.brewUpgradeGit],
            action: action,
            policy: policy
        )])
    }

    // MARK: The re-read before execution

    @Test("A version skipped after the plan was built is not run, and history says why")
    func skipAddedAfterPlanningWins() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        // Planned while 2.50.1 was on offer and git updated automatically…
        let planned = try harness.save(configuration(["brew:git": .init(policy: .auto)]))
        // …then the user skipped exactly that version.
        try PolicyEditor(store: harness.configurationStore).skipVersion("2.50.1", for: Self.git)

        let report = await harness.engine().run(
            gitPlan(),
            configuration: planned,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.decision?.source == .skippedVersion)
        #expect(report.skipped.first?.reason == "You skipped git 2.50.1. MacUp will offer the next version.")
        #expect(harness.runner.recordedRequests.isEmpty, "nothing may run once the version is skipped")

        let history = try harness.history.load()
        #expect(history.count == 1)
        #expect(history.first?.outcome == .skipped)
        #expect(history.first?.skipReason?.contains("You skipped git 2.50.1") == true)
    }

    @Test("Confirming an item does not run a version the user skipped")
    func confirmationDoesNotOverrideASkip() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .init(policy: .ask, skipVersion: "2.50.1")]))

        let report = await harness.engine().run(
            gitPlan(action: .confirm, policy: .ask),
            configuration: loaded,
            options: ExecutionOptions(origin: .gui, confirmed: [Self.git]),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.decision?.source == .skippedVersion)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("A skip for another version does not stop the one on offer")
    func aDifferentSkipDoesNotStopTheItem() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .init(policy: .auto, skipVersion: "2.50.0")]))

        let report = await harness.engine().run(
            gitPlan(),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.summary.succeeded == 1)
        #expect(harness.runner.recordedInvocations.map(\.arguments) == [["upgrade", "--formula", "git"]])
    }

    @Test("A dry run leaves a skipped version out too, rather than listing its command")
    func dryRunHonoursTheSkip() async throws {
        let harness = try ExecutionHarness()
        let loaded = try harness.save(configuration(["brew:git": .init(policy: .auto, skipVersion: "2.50.1")]))

        let report = await harness.engine().run(
            gitPlan(),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli, dryRun: true),
            environment: harness.environment
        )

        #expect(report.skipped.first?.decision?.source == .skippedVersion)
        #expect(report.skipped.first?.reason.contains("MacUp would run") == false)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    // MARK: Planning

    private func plan(_ items: [String: MacUpConfiguration.ItemSettings]) async throws -> PlanReport {
        let mac = try FakeMac()
        let loaded = LoadedConfiguration(
            configuration: configuration(items),
            source: .file,
            path: "/Users/example/.config/macup/config.json"
        )
        let check = await CheckEngine.standard().run(configuration: loaded, environment: mac.checkEnvironment)
        return await UpdatePlanner.standard().plan(
            check,
            request: PlanRequest(),
            configuration: loaded,
            environment: mac.checkEnvironment
        )
    }

    @Test("The planner leaves the skipped version out of the plan, with the reason and the note")
    func plannerSkips() async throws {
        let report = try await plan(["brew:mysql": .init(
            policy: .auto,
            skipVersion: "26.7.0_2",
            note: "waiting for PHP 8.4 support"
        )])

        #expect(!report.planned.contains { $0.item.rawValue == "brew:mysql" })
        let skipped = try #require(report.skipped.first { $0.item.rawValue == "brew:mysql" })
        #expect(skipped.decision?.action == .deny)
        #expect(skipped.decision?.source == .skippedVersion)
        #expect(skipped.decision?.note == "waiting for PHP 8.4 support")
        #expect(skipped.reason == "You skipped mysql 26.7.0_2. MacUp will offer the next version.")
        #expect(skipped.proposedVersion == "26.7.0_2")
        #expect(report.summary.deniedByPolicy == 1)
    }

    @Test("The planner plans the item again once a different version is on offer")
    func plannerPlansTheNextVersion() async throws {
        let report = try await plan(["brew:mysql": .init(policy: .ask, skipVersion: "26.7.0_1", note: "check the changelog")])

        let planned = try #require(report.planned.first { $0.item.rawValue == "brew:mysql" })
        #expect(planned.needsConfirmation)
        #expect(planned.decision.note == "check the changelog")
        #expect(!report.skipped.contains { $0.item.rawValue == "brew:mysql" })
    }
}
