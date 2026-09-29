import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What Copy Details and Copy Command copy")
@MainActor
struct AppModelExplainTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let wget = try! PackageID(parsing: "brew:wget")

    private func checked(_ names: [String] = ["brew:git", "brew:wget"]) async throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: names.map { PlannedUpdateFactory.candidate($0) }
        ))
        await harness.model.checkNow()
        return harness
    }

    @Test("Copy Details is word for word what macup explain prints, from the check on screen")
    func detailsAreTheExplainText() async throws {
        let harness = try await checked()
        let copied = try #require(await harness.model.copiedDetails(for: Self.git))

        // The CLI's text, built by the same MacUpCore code from the same
        // check, rules, and history.
        let report = try #require(harness.model.report)
        let loaded = harness.model.loadConfiguration()
        let explanation = await ItemExplainer(
            checkEngine: CheckEngine(providers: [try #require(harness.planning)]),
            planner: UpdatePlanner(providers: [try #require(harness.planning)])
        ).explain(
            Self.git,
            from: report,
            configuration: loaded,
            environment: CheckEnvironment(
                runner: harness.runner,
                fileSystem: harness.fileSystem,
                processEnvironment: [:],
                homeDirectory: harness.home.canonicalPath,
                system: SystemInfo(productVersion: "15.0", buildVersion: "24A335", architecture: "arm64")
            ),
            history: HistoryStore(paths: harness.paths)
        )
        #expect(copied == ExplanationText(homeDirectory: harness.home.canonicalPath).render(explanation))

        #expect(copied.hasPrefix("MacUp explain · read-only · nothing was changed"))
        #expect(copied.contains("Policy: Ask First · needs your confirmation"))
        #expect(copied.contains("    Runs: /stub/bin/brew upgrade --formula --yes git"))
        #expect(!copied.contains("\u{1B}["), "the clipboard gets plain text")
        // Copying runs nothing.
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("Copy Command is the exact command line from the item's plan")
    func commandIsThePlansCommandLine() async throws {
        let harness = try await checked()
        #expect(await harness.model.copiedCommand(for: Self.git) == "/stub/bin/brew upgrade --formula --yes git")
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("An item a rule leaves alone has details to copy but no command")
    func ignoredItemHasNoCommand() async throws {
        let harness = try await checked()
        try harness.rule(.ignore, for: Self.wget)

        #expect(await harness.model.copiedCommand(for: Self.wget) == nil)
        let details = try #require(await harness.model.copiedDetails(for: Self.wget))
        #expect(details.contains("Policy: Ignore · will not run"))
        #expect(details.contains("What MacUp would run: nothing"))
    }

    @Test("An item MacUp cannot plan has no command, and the details say why")
    func unplannableItemHasNoCommand() async throws {
        let provider = StubPlanningProvider(candidates: [PlannedUpdateFactory.candidate("brew:git")])
        provider.refusePlan(for: Self.git, MacUpError(.unsupported, "This provider has no plan for git."))
        let harness = try AppModelHarness(planning: provider)
        await harness.model.checkNow()

        #expect(await harness.model.copiedCommand(for: Self.git) == nil)
        let explanation = try #require(await harness.model.explanation(for: Self.git))
        #expect(explanation.skipped?.reason.contains("no plan for git") == true)
        #expect(harness.model.detailsText(for: explanation).contains("This provider has no plan for git."))
    }

    @Test("A rule changed after the check is what the copied details say")
    func detailsFollowTheRulesInForce() async throws {
        let harness = try await checked()
        await harness.model.setPolicy(.auto, for: Self.git)
        let details = try #require(await harness.model.copiedDetails(for: Self.git))
        #expect(details.contains("Policy: Auto Update · runs without asking"))
        #expect(details.contains("  Set by: a rule you set for this item (items.brew:git.policy)"))
    }

    @Test("The copied details include the item's own history")
    func detailsIncludeHistory() async throws {
        let harness = try await checked()
        try HistoryStore(paths: harness.paths).append(HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_790_000_000),
            origin: .gui,
            item: Self.git,
            versionBefore: "0.9.0",
            versionTarget: "1.0.0",
            versionAfter: nil,
            command: "/stub/bin/brew upgrade --formula --yes git",
            outcome: .failed,
            verification: nil,
            errorSummary: "Homebrew failed.",
            durationSeconds: 3
        ))
        let details = try #require(await harness.model.copiedDetails(for: Self.git))
        #expect(details.contains("History · 1 entry"))
        #expect(details.contains("0.9.0 → 1.0.0"))
        #expect(details.contains("Failed — MacUp changed nothing further"))
        #expect(details.contains("      Details: Homebrew failed."))
    }

    @Test("Before any check there is nothing to copy")
    func nothingBeforeACheck() async throws {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [PlannedUpdateFactory.candidate("brew:git")]))
        #expect(await harness.model.copiedDetails(for: Self.git) == nil)
        #expect(await harness.model.copiedCommand(for: Self.git) == nil)
    }
}
