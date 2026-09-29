import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the menu bar lists")
@MainActor
struct AppModelMenuBarTests {
    private func checked(_ candidates: [UpdateCandidate]) async throws -> AppModelHarness {
        let harness = try AppModelHarness(planning: StubPlanningProvider(candidates: candidates))
        await harness.model.checkNow()
        return harness
    }

    private func names(_ count: Int) -> [UpdateCandidate] {
        (1...count).map { PlannedUpdateFactory.candidate("brew:tool\(String(format: "%02d", $0))") }
    }

    @Test("Each pending update is listed by name, current → new, in the order the Updates screen uses")
    func listsPendingUpdates() async throws {
        let harness = try await checked([
            PlannedUpdateFactory.candidate("brew:wget", installed: "1.24.5", available: "1.25.0"),
            PlannedUpdateFactory.candidate("brew:git", installed: "2.43.0", available: "2.44.0"),
        ])
        let menu = harness.model.menuBarUpdates
        #expect(menu.entries.map(\.title) == ["git  2.43.0 → 2.44.0", "wget  1.24.5 → 1.25.0"])
        #expect(menu.entries.map(\.accessibilityLabel) == ["git, 2.43.0 to 2.44.0", "wget, 1.24.5 to 1.25.0"])
        #expect(menu.remaining == 0)
        #expect(menu.remainingLine == nil)
        #expect(menu.attention == nil)
    }

    @Test("Past eight updates the menu names eight and says how many more")
    func capsTheList() async throws {
        let harness = try await checked(names(11))
        let menu = harness.model.menuBarUpdates
        #expect(AppModel.menuBarUpdateLimit == 8)
        #expect(menu.entries.count == 8)
        #expect(menu.entries.first?.title == "tool01  1.0.0 → 1.0.1")
        #expect(menu.entries.last?.title == "tool08  1.0.0 → 1.0.1")
        #expect(menu.remaining == 3)
        #expect(menu.remainingLine == "and 3 more")
    }

    @Test("Exactly eight updates are all listed, with no \"and more\" line")
    func exactlyAtTheCap() async throws {
        let menu = try await checked(names(8)).model.menuBarUpdates
        #expect(menu.entries.count == 8)
        #expect(menu.remainingLine == nil)
    }

    @Test("An update a rule leaves alone is not listed as if it would run")
    func leavesOutWhatARuleHolds() async throws {
        let harness = try await checked(names(2))
        await harness.model.setPolicy(.ignore, for: try PackageID(parsing: "brew:tool02"))
        let menu = harness.model.menuBarUpdates
        #expect(menu.entries.map(\.id.rawValue) == ["brew:tool01"])
        #expect(menu.remaining == 0)
    }

    @Test("An unfinished install or a build from source gets a line of its own")
    func attentionLine() async throws {
        let unfinished = try await checked([
            PlannedUpdateFactory.candidate("brew:git"),
            PlannedUpdateFactory.candidate("brew:mysql", signals: [.installationIncomplete, .buildsFromSource]),
        ]).model.menuBarUpdates
        #expect(unfinished.attention == "mysql: an earlier install did not finish")
        #expect(unfinished.attentionItem?.rawValue == "brew:mysql")

        let compiled = try await checked([PlannedUpdateFactory.candidate("brew:llvm", signals: [.buildsFromSource])])
            .model.menuBarUpdates
        #expect(compiled.attention == "llvm will be compiled from source")

        let several = try await checked([
            PlannedUpdateFactory.candidate("brew:a", signals: [.buildsFromSource]),
            PlannedUpdateFactory.candidate("brew:b", signals: [.installationIncomplete]),
            PlannedUpdateFactory.candidate("brew:c", signals: [.buildsFromSource]),
            PlannedUpdateFactory.candidate("brew:d", signals: [.buildsFromSource]),
        ]).model.menuBarUpdates
        #expect(several.attention == "4 need attention: a, b, c, …")
        #expect(several.attentionItem?.rawValue == "brew:a")
    }

    @Test("Names from a provider are shown safely")
    func namesAreDisplaySafe() async throws {
        let menu = try await checked([
            PlannedUpdateFactory.candidate("brew:evil", displayName: "evil\u{202E}\u{1B}[2J"),
        ]).model.menuBarUpdates
        let title = try #require(menu.entries.first?.title)
        #expect(!title.contains("\u{202E}"))
        #expect(!title.contains("\u{1B}"))
    }

    @Test("Choosing an update opens the Updates screen with that update selected")
    func revealSelectsTheItem() async throws {
        let harness = try await checked(names(2))
        let item = try PackageID(parsing: "brew:tool02")
        harness.model.section = .dashboard
        harness.model.reveal(item)
        #expect(harness.model.section == .updates)
        #expect(harness.model.selectedUpdate == item)
    }

    @Test("Before any check the menu lists nothing")
    func nothingBeforeACheck() throws {
        let menu = try AppModelHarness().model.menuBarUpdates
        #expect(menu.entries.isEmpty)
        #expect(menu.remainingLine == nil)
        #expect(menu.attention == nil)
    }
}
