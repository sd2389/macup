import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// What apps that are gone left in `~/Library`, over a pretend Mac in a
/// temporary folder.
@Suite("Left behind by apps that are gone")
struct OrphanScanTests {
    /// An app that is gone: a sandbox container and saved window state, which
    /// only a windowed app writes.
    private func removedApp(_ mac: UninstallFixture, _ identifier: String) throws {
        try mac.folder("home/Library/Containers/" + identifier)
        try mac.folder("home/Library/Saved Application State/" + identifier + ".savedState")
        try mac.file("home/Library/Preferences/" + identifier + ".plist")
        try mac.folder("home/Library/Caches/" + identifier)
    }

    @Test("Files named after an app that is not installed are found, with why MacUp thinks an app left them")
    func findsLeftovers() throws {
        let mac = try UninstallFixture()
        try removedApp(mac, "com.example.chatter")

        let found = OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: [])

        let group = try #require(found.first)
        #expect(found.count == 1)
        #expect(group.identifier == "com.example.chatter")
        #expect(group.guessedName == "chatter")
        #expect(group.target == "leftovers:com.example.chatter")
        #expect(group.files.count == 4)
        #expect(group.evidence.contains { $0.contains("sandbox container") })
        #expect(group.files.contains { $0.path.hasSuffix("Containers/com.example.chatter") && $0.category == .appData })
        #expect(group.files.contains { $0.path.hasSuffix("Caches/com.example.chatter") && $0.category == .belongsToApp })
    }

    @Test("An installed app's files are never leftovers, nor are a longer identifier's")
    func leavesInstalledAppsAlone() throws {
        let mac = try UninstallFixture()
        try removedApp(mac, "com.google.Chrome")
        try removedApp(mac, "com.google.Chrome.canary")
        try removedApp(mac, "com.example.gone")

        let found = OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: ["com.google.Chrome"])

        #expect(found.map(\.identifier) == ["com.example.gone"])
    }

    @Test("Apple's own files are left alone, and so is anything that is not a bundle identifier")
    func leavesAppleAndPlainNamesAlone() throws {
        let mac = try UninstallFixture()
        try removedApp(mac, "com.apple.Safari")
        try mac.folder("home/Library/Containers/Chatter")
        try mac.folder("home/Library/Containers/com.google")

        let found = OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: [])

        #expect(found.isEmpty)
    }

    @Test("A command-line tool's settings file alone is not enough to call it an app's leftovers")
    func needsEvidenceOfAnApp() throws {
        let mac = try UninstallFixture()
        try mac.file("home/Library/Preferences/com.example.tool.plist")
        try mac.folder("home/Library/Caches/com.example.daemon")

        #expect(OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: []).isEmpty)

        // Settings and a data folder together are enough, and say so weakly.
        try mac.folder("home/Library/Application Support/com.example.tool")
        let found = OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: [])
        #expect(found.map(\.identifier) == ["com.example.tool"])
        #expect(found[0].evidence == ["It left its settings and its data."])
    }

    @Test("The suffixes macOS adds are not part of the identifier")
    func stripsSuffixes() {
        #expect(OrphanScanner.identifier(fromEntry: "com.example.app.plist", in: "Preferences") == "com.example.app")
        #expect(OrphanScanner.identifier(fromEntry: "com.example.app.savedState", in: "Saved Application State") == "com.example.app")
        #expect(OrphanScanner.identifier(fromEntry: "com.example.app.binarycookies", in: "HTTPStorages") == "com.example.app")
        #expect(
            OrphanScanner.identifier(
                fromEntry: "com.example.app.6E4C1A45-55C3-4D32-9B33-31A2B0C1F9A1.plist",
                in: "Preferences/ByHost"
            ) == "com.example.app"
        )
        #expect(
            OrphanScanner.identifier(fromEntry: "com.example.app.0011223344ff.plist", in: "Preferences/ByHost")
                == "com.example.app",
            "the older MAC-address form is a host identifier too"
        )
        #expect(OrphanScanner.identifier(fromEntry: "com.apple.finder.plist", in: "Preferences") == nil)
        #expect(OrphanScanner.identifier(fromEntry: "settings.plist", in: "Preferences") == nil)
    }

    @Test("A plan for leftovers runs nothing, ticks nothing, and says why")
    func planTicksNothing() async throws {
        let mac = try UninstallFixture()
        try removedApp(mac, "com.example.chatter")
        let group = try #require(OrphanScanner(homeDirectory: mac.home).scan(installedIdentifiers: []).first)

        let plan = UninstallPlanner().planLeftovers(
            group,
            uninstall: mac.environment(),
            environment: CheckEnvironment(
                runner: FakeCommandRunner(),
                fileSystem: FakeFileSystem(),
                processEnvironment: [:],
                homeDirectory: mac.home,
                system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
                now: { Date(timeIntervalSince1970: 1_790_000_000) }
            )
        )

        #expect(plan.steps.isEmpty, "no package manager owns these")
        #expect(plan.subject.kind == .leftovers)
        #expect(plan.subject.target == "leftovers:com.example.chatter")
        #expect(!plan.removals.isEmpty)
        #expect(plan.removals.allSatisfy { !$0.selectedByDefault }, "nothing is ticked for the user")
        #expect(plan.rationale.contains("cannot ask an app that is gone"))
        #expect(plan.warnings == group.evidence)
        #expect(mac.backend.trashed.isEmpty && mac.backend.deleted.isEmpty)
    }

    @Test("A name nobody scanned for cannot be uninstalled by typing it")
    func resolverNeedsAScan() {
        let catalog = UninstallCatalog(createdAt: Date())
        let result = UninstallTargetResolver.resolve(
            "leftovers:com.example.chatter",
            in: catalog,
            homeDirectory: "/Users/example"
        )
        guard case .failure(let error) = result else {
            Issue.record("a group nobody has seen must not resolve")
            return
        }
        #expect(error.kind == .notFound)
        #expect(error.message.contains("--orphans"))
    }
}
