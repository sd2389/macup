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

    @Test("A folder in the Caskroom does not make this copy Homebrew's, and offers no update")
    func caskroomFolderIsNotProvenance() async throws {
        let harness = try AppModelHarness(
            provider: StubCheckProvider(updateNames: ["macup", "git"], prefix: "/opt/homebrew"),
            planning: nil
        )
        // A folder anyone can create. Homebrew reports no MacUp cask, so
        // nothing here says Homebrew installed the copy that is running.
        harness.fileSystem.addDirectory("/opt/homebrew/Caskroom/macup")
        await harness.model.checkNow()

        let status = try #require(harness.model.selfUpdateStatus)
        #expect(!status.isRunningCopyManagedByHomebrew)
        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.downloaded])
        #expect(!status.hasUpdate, "a formula update is not this copy's either")
        #expect(status.headline.contains("not installed by a package manager"))
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
        // The app is where a cask puts one, and the cask update Homebrew
        // reports is what ties it to Homebrew.
        let fixture = try UninstallFixture()
        let harness = try AppModelHarness(
            planning: planning,
            uninstall: fixture.environment(currentAppBundle: fixture.applications + "/MacUp.app")
        )
        await harness.model.checkNow()

        let status = try #require(harness.model.selfUpdateStatus)
        #expect(status.isRunningCopyManagedByHomebrew)
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
