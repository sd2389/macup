import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Finding an update on the Updates screen")
@MainActor
struct AppModelUpdateListTests {
    private static let git = try! PackageID(parsing: "brew:git")
    private static let mysql = try! PackageID(parsing: "brew:mysql")
    private static let typescript = try! PackageID(parsing: "npm:typescript")

    /// git: a low-risk patch. mysql: a major change whose last install did
    /// not finish. typescript: a moderate minor change, from npm.
    private func checked() async throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: [
            PlannedUpdateFactory.candidate("brew:git", installed: "2.44.0", available: "2.44.1"),
            PlannedUpdateFactory.candidate("brew:mysql", installed: "9.7.1", available: "26.7.0_2", signals: [.installationIncomplete]),
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.8.0", available: "5.9.0", kind: .globalPackage),
        ]))
        await harness.model.checkNow()
        return harness
    }

    @Test("A filter narrows the Updates list and says how many it hides; nothing else is filtered")
    func filterHidesOnlyFromTheList() async throws {
        let harness = try await checked()
        let model = harness.model
        model.updateFilter = UpdateFilter(riskLevels: [.high])

        #expect(model.updateListing.shown.map(\.id) == [Self.mysql])
        #expect(model.updateListing.hiddenCount == 2)
        #expect(model.hiddenUpdatesMessage == "2 updates hidden by the current filter")
        // The dashboard, the sidebar badge, and the menu bar count everything.
        #expect(model.updateCount == 3)
        #expect(model.pendingUpdates.count == 3)
        #expect(model.status == .updatesAvailable(3))
        #expect(model.report?.updates.count == 3)

        model.updateFilter = UpdateFilter(riskLevels: [.high, .low])
        #expect(model.hiddenUpdatesMessage == "1 update hidden by the current filter")
    }

    @Test("Show All clears the search and every filter, and keeps the order")
    func showAll() async throws {
        let harness = try await checked()
        let model = harness.model
        model.updateSort = .name
        model.updateFilter = UpdateFilter(searchText: "zzz", providers: [.npm], needsAttentionOnly: true)
        #expect(model.updateListing.shown.isEmpty)
        #expect(model.hiddenUpdatesMessage == "3 updates hidden by the current filter")

        model.showAllUpdates()
        #expect(!model.updateFilter.isActive)
        #expect(model.updateSort == .name)
        #expect(model.hiddenUpdatesMessage == nil)
        #expect(model.updateListing.shown.map(\.id) == [Self.git, Self.mysql, Self.typescript])
    }

    @Test("The policy filter matches the policy each row shows, rules included")
    func policyFilter() async throws {
        let harness = try await checked()
        let model = harness.model
        await model.setPolicy(.ignore, for: Self.mysql)
        await model.setPolicy(.auto, for: Self.git)

        model.updateFilter = UpdateFilter(policies: [.ignore])
        #expect(model.updateListing.shown.map(\.id) == [Self.mysql])
        model.updateFilter = UpdateFilter(policies: [.ask])
        #expect(model.updateListing.shown.map(\.id) == [Self.typescript])
        model.updateFilter = UpdateFilter(policies: [.auto, .ask])
        #expect(model.updateListing.shown.map(\.id) == [Self.git, Self.typescript])
    }

    @Test("Needs Attention keeps what MacUpCore marks, and sorting hides nothing")
    func attentionAndSort() async throws {
        let harness = try await checked()
        let model = harness.model
        model.updateFilter = UpdateFilter(needsAttentionOnly: true)
        #expect(model.updateListing.shown.map(\.id) == [Self.mysql])

        model.showAllUpdates()
        model.updateSort = .risk
        let listing = model.updateListing
        #expect(listing.shown.map(\.id) == [Self.mysql, Self.typescript, Self.git])
        #expect(listing.hiddenCount == 0)
        #expect(listing.groups.count == 1, "one list, not one section per provider")
        #expect(model.hiddenUpdatesMessage == nil)

        model.updateSort = .provider
        #expect(model.updateListing.groups.map(\.provider) == [.homebrew, .npm])
    }

    @Test("Search matches the name, the package ID, and the provider")
    func search() async throws {
        let harness = try await checked()
        let model = harness.model
        model.updateFilter.searchText = "npm"
        #expect(model.updateListing.shown.map(\.id) == [Self.typescript])
        model.updateFilter.searchText = "brew:my"
        #expect(model.updateListing.shown.map(\.id) == [Self.mysql])
        model.updateFilter.searchText = "HOMEBREW"
        #expect(model.updateListing.shown.map(\.id) == [Self.git, Self.mysql])
        #expect(model.hiddenUpdatesMessage == "1 update hidden by the current filter")
    }

    @Test("Opening an update the filter would hide clears the filter; one it shows keeps it")
    func showUpdate() async throws {
        let harness = try await checked()
        let model = harness.model
        model.section = .dashboard
        model.updateFilter = UpdateFilter(riskLevels: [.low])

        model.showUpdate(Self.git)
        #expect(model.updateFilter.isActive, "git is shown, so the filter stays")
        #expect(model.selectedUpdate == Self.git)
        #expect(model.section == .updates)

        model.showUpdate(Self.mysql)
        #expect(!model.updateFilter.isActive)
        #expect(model.selectedUpdate == Self.mysql)
    }

    @Test("The Filter menu offers the providers with updates, and any the filter already names")
    func filterableProviders() async throws {
        let harness = try await checked()
        #expect(harness.model.filterableProviders == [.homebrew, .npm])
        harness.model.updateFilter.providers = [.mise]
        #expect(harness.model.filterableProviders == [.homebrew, .npm, .mise])
    }

    @Test("⌘1…⌘7 follow the sidebar's order, and ⌘F opens the Updates search")
    func keyboard() async throws {
        #expect(AppModel.Section.allCases == [.dashboard, .providers, .updates, .uninstall, .features, .doctor, .history])
        #expect(AppModel.Section.allCases.map(\.title) == ["Dashboard", "Providers", "Updates", "Uninstall", "Features", "Doctor", "History"])

        let harness = try await checked()
        let model = harness.model
        model.section = .history
        model.searchUpdates()
        #expect(model.section == .updates)
        for _ in 0..<100 where !model.isSearchingUpdates { await Task.yield() }
        #expect(model.isSearchingUpdates)
    }
}
