import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The Uninstall screen over a pretend Mac in a temporary folder, with a fake
/// Trash: no test removes a real file.
@Suite("Uninstalling from the app")
@MainActor
struct AppModelUninstallTests {
    /// One downloaded app, a cache that belongs to it, and its data.
    private func mac(security: MacUpConfiguration.SecuritySettings? = nil) throws
        -> (AppModelHarness, UninstallFixture, app: String, cache: String, data: String) {
        let fixture = try UninstallFixture()
        let app = try fixture.app("Chatter", identifier: "com.example.chatter", version: "2.1")
        let cache = try fixture.folder("home/Library/Caches/com.example.chatter")
        let data = try fixture.folder("home/Library/Application Support/com.example.chatter")
        let harness = try AppModelHarness(uninstall: fixture.environment())
        if let security { try harness.save(security: security) }
        return (harness, fixture, app, cache, data)
    }

    private func chatter(_ harness: AppModelHarness) throws -> InstalledApp {
        try #require(harness.model.uninstaller.catalog?.apps.first { $0.name == "Chatter" })
    }

    @Test("Looking lists the app, and removes nothing")
    func scan() async throws {
        let (harness, fixture, _, _, _) = try mac()
        await harness.model.scanUninstallable()
        #expect(try chatter(harness).version == "2.1")
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("A review always opens on Move to Trash, with what belongs ticked and the data not")
    func reviewDefaults() async throws {
        let (harness, fixture, app, cache, data) = try mac()
        await harness.model.scanUninstallable()
        let target = UninstallTarget.app(try chatter(harness))
        await harness.model.reviewUninstall(target)
        let state = harness.model.uninstaller
        #expect(state.isReviewing)
        #expect(state.mode == .trash)
        #expect(harness.model.isIncludedInUninstall(app))
        #expect(harness.model.isIncludedInUninstall(cache))
        #expect(!harness.model.isIncludedInUninstall(data), "data stays unless it is ticked")

        // Choosing Delete Permanently lasts for this review only.
        state.mode = .delete
        harness.model.endUninstallReview()
        await harness.model.reviewUninstall(target)
        #expect(harness.model.uninstaller.mode == .trash)
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("Select Everything ticks the data too; the app itself cannot be unticked; the totals follow")
    func selection() async throws {
        // The fixture is kept to the end: releasing it deletes the pretend Mac.
        let (harness, fixture, app, _, data) = try mac()
        await harness.model.scanUninstallable()
        await harness.model.reviewUninstall(.app(try chatter(harness)))
        let before = try #require(harness.model.uninstallTotals)
        #expect(before.keptCount == 1)

        harness.model.selectEverythingForUninstall()
        #expect(harness.model.isIncludedInUninstall(data))
        #expect(try #require(harness.model.uninstallTotals).keptCount == 0)

        harness.model.setIncludedInUninstall(false, path: app)
        #expect(harness.model.isIncludedInUninstall(app), "the app is what is being uninstalled")

        harness.model.selectDefaultsForUninstall()
        #expect(!harness.model.isIncludedInUninstall(data))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty, "choosing removes nothing")
    }

    @Test("Uninstalling moves what was ticked to the Trash, keeps the data, and records it")
    func uninstallToTrash() async throws {
        let (harness, fixture, app, cache, data) = try mac()
        await harness.model.scanUninstallable()
        await harness.model.reviewUninstall(.app(try chatter(harness)))
        harness.model.runUninstall()
        await harness.model.uninstaller.task?.value

        let report = try #require(harness.model.uninstaller.report)
        #expect(report.outcome == .uninstalled)
        #expect(report.mode == .trash)
        #expect(Set(fixture.backend.trashed).isSuperset(of: [app, cache]))
        #expect(!fixture.backend.trashed.contains(data))
        #expect(fixture.backend.deleted.isEmpty)
        #expect(try harness.recordedHistory().contains { $0.uninstall?.name == "Chatter" })
        #expect(!harness.model.uninstaller.isRunning)
    }

    @Test("Delete Permanently deletes instead, only when it was chosen for this uninstall")
    func uninstallDeleting() async throws {
        let (harness, fixture, app, _, _) = try mac()
        await harness.model.scanUninstallable()
        await harness.model.reviewUninstall(.app(try chatter(harness)))
        harness.model.uninstaller.mode = .delete
        harness.model.runUninstall()
        await harness.model.uninstaller.task?.value
        #expect(fixture.backend.deleted.contains(app))
        #expect(fixture.backend.trashed.isEmpty)
    }

    @Test("Refused approval removes nothing and says why")
    func refusedApproval() async throws {
        let (harness, fixture, _, _, _) = try mac(security: .init(requireApproval: true))
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        await harness.model.scanUninstallable()
        await harness.model.reviewUninstall(.app(try chatter(harness)))
        harness.model.runUninstall()
        await harness.model.uninstaller.task?.value
        #expect(harness.model.uninstaller.problem == "You cancelled, so nothing was changed.")
        #expect(harness.model.uninstaller.report == nil)
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
        #expect(harness.authorizer.requestedReasons == ["uninstall Chatter from this Mac"])
    }
}
