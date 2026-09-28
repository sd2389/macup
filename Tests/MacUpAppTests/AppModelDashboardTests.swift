import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the dashboard lists")
@MainActor
struct AppModelDashboardTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let mysql = try! PackageID(parsing: "brew:mysql")
    private static let wget = try! PackageID(parsing: "brew:wget")

    private func checked() async throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:mysql"),
        ]))
        await harness.model.checkNow()
        return harness
    }

    @Test("Pending updates are the ones that could still run; the ignored ones are listed apart")
    func pendingAndLeftAlone() async throws {
        let harness = try await checked()
        #expect(harness.model.pendingUpdates.map(\.id) == [Self.git, Self.mysql])
        #expect(harness.model.leftAloneUpdates.isEmpty)

        await harness.model.setPolicy(.ignore, for: Self.mysql)
        #expect(harness.model.pendingUpdates.map(\.id) == [Self.git])
        #expect(harness.model.leftAloneUpdates.map(\.id) == [Self.mysql])
    }

    @Test("An ignored or pinned item with no update now is still listed, since its rule still applies")
    func rulesWithoutAnUpdate() async throws {
        let harness = try await checked()
        await harness.model.setPolicy(.pin, for: Self.wget)
        await harness.model.setPolicy(.ignore, for: Self.mysql)
        await harness.model.setPolicy(.auto, for: Self.git)

        // mysql has an update, so it is already among the left-alone updates;
        // git's rule lets it run; only wget is a held rule with nothing to hold back yet.
        #expect(harness.model.heldRulesWithoutUpdate.map(\.item) == [Self.wget])
    }

    @Test("Turning a provider off leaves its updates out of what is pending")
    func disabledProvider() async throws {
        let harness = try await checked()
        await harness.model.setProviderEnabled(false, for: .homebrew)
        #expect(harness.model.pendingUpdates.isEmpty)
    }
}
