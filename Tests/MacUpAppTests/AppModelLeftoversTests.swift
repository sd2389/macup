import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The Uninstall screen's "Left Behind by Apps You Removed".
@Suite("App: left behind by apps that are gone")
@MainActor
struct AppModelLeftoversTests {
    private func mac() throws -> (AppModelHarness, UninstallFixture) {
        let fixture = try UninstallFixture()
        try fixture.app("Chatter", identifier: "com.example.chatter", version: "2.1")
        try fixture.folder("home/Library/Containers/com.example.gone")
        try fixture.folder("home/Library/Saved Application State/com.example.gone.savedState")
        try fixture.file("home/Library/Preferences/com.example.gone.plist")
        return (try AppModelHarness(uninstall: fixture.environment()), fixture)
    }

    @Test("Opening the screen lists what is left behind, and removes nothing")
    func lists() async throws {
        let (harness, fixture) = try mac()
        await harness.model.scanUninstallable()

        #expect(harness.model.orphanedLeftovers.map(\.identifier) == ["com.example.gone"])
        #expect(harness.model.orphanedLeftovers[0].files.count == 3)
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("Reviewing one opens the ordinary review with nothing ticked")
    func review() async throws {
        let (harness, fixture) = try mac()
        await harness.model.scanUninstallable()
        let group = try #require(harness.model.orphanedLeftovers.first)

        await harness.model.reviewLeftovers(group)

        #expect(harness.model.uninstaller.isReviewing)
        let plan = try #require(harness.model.uninstaller.plan)
        #expect(plan.subject.kind == .leftovers)
        #expect(plan.removals.allSatisfy { !harness.model.isIncludedInUninstall($0.path) })
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }
}
