import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// Settings > MacUp Updates: where this copy came from, and whether Homebrew
/// has a newer one. The app runs no check of its own for this — it reads the
/// check it already has.
@Suite("App: updating MacUp itself")
@MainActor
struct AppModelSelfUpdateTests {
    @Test("Before the first check, MacUp says nothing about its own version")
    func unknownUntilChecked() throws {
        let harness = try AppModelHarness()
        #expect(harness.model.selfUpdateStatus == nil)
        #expect(harness.model.selfUpdateItem == nil)
    }

    @Test("A copy that was downloaded is listed as one, with nothing to run")
    func downloadedCopy() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(prefix: "/opt/homebrew"))
        await harness.model.checkNow()

        let status = try #require(harness.model.selfUpdateStatus)
        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.downloaded])
        #expect(!status.hasUpdate)
        #expect(status.releasesURL == SelfUpdate.releasesURL)
        #expect(harness.model.selfUpdateItem == nil)
    }

    @Test("When Homebrew installed MacUp and has a newer one, Update MacUp reviews that one item")
    func reviewsTheUpdate() async throws {
        let harness = try AppModelHarness(
            provider: StubCheckProvider(updateNames: ["macup", "git"], prefix: "/opt/homebrew"),
            planning: nil
        )
        harness.fileSystem.addDirectory("/opt/homebrew/Caskroom/macup")
        await harness.model.checkNow()

        let status = try #require(harness.model.selfUpdateStatus)
        #expect(status.isManagedByHomebrew)
        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.homebrewCask])
        // The cask is what is installed, so a formula update is not MacUp's.
        #expect(!status.hasUpdate)
    }

    @Test("A cask update MacUp itself is offered, and reviewing it selects only MacUp")
    func reviewsOnlyMacUp() async throws {
        let planning = StubPlanningProvider(candidates: [
            UpdateCandidate(
                id: try PackageID(.brewCask, "macup"),
                kind: .cask,
                displayName: "macup",
                installedVersion: "0.4.0",
                availableVersion: "0.5.0"
            ),
            UpdateCandidate(
                id: try PackageID(.brew, "git"),
                kind: .formula,
                displayName: "git",
                installedVersion: "2.43.0",
                availableVersion: "2.44.0"
            ),
        ], prefix: "/opt/homebrew")
        let harness = try AppModelHarness(planning: planning)
        harness.fileSystem.addDirectory("/opt/homebrew/Caskroom/macup")
        await harness.model.checkNow()

        let status = try #require(harness.model.selfUpdateStatus)
        #expect(status.hasUpdate)
        #expect(status.headline == "MacUp \(MacUp.version) can be updated to 0.5.0.")
        #expect(harness.model.selfUpdateItem?.rawValue == "brew-cask:macup")

        await harness.model.reviewSelfUpdate()
        let plan = try #require(harness.model.updatePlan)
        #expect(
            plan.planned.map(\PlannedUpdate.item.rawValue) == ["brew-cask:macup"],
            "only MacUp, never the rest of the list"
        )
    }
}
