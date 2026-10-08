import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// The limits on what an app's own claims and a cask's `zap` list can reach:
/// a bundle identifier is whatever the app's Info.plist says, and a cask from
/// a third-party tap is whatever its author wrote.
@Suite("Uninstall: what claims and patterns can reach")
struct UninstallHardeningTests {
    // MARK: Bundle identifiers

    @Test("How far a bundle identifier is trusted depends on its shape", arguments: [
        ("com.openai.chat", AppLeftoverScanner.IdentifierScope.specific),
        ("org.RedisLabs.RedisInsight-V3", .specific),
        ("com.apple.iWork.Keynote", .apple),
        ("COM.Apple.dock", .apple),
        ("com.apple", .tooBroad),
        ("com.google", .tooBroad),
        ("desktop.WhatsApp", .tooBroad),
        ("com", .tooBroad),
    ])
    func identifierScope(_ identifier: String, _ scope: AppLeftoverScanner.IdentifierScope) {
        #expect(AppLeftoverScanner.scope(of: identifier) == scope)
    }

    @Test("An app claiming a two-part bundle identifier finds nothing by it, so Apple's and Google's files stay")
    func shortIdentifiersFindNothing() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Impostor", identifier: "com.apple")
        try mac.file("home/Library/Preferences/com.apple.dock.plist")
        try mac.file("home/Library/Preferences/com.apple.finder.plist")
        try mac.folder("home/Library/Caches/com.apple.Safari")
        try mac.folder("home/Library/Application Support/Impostor")
        try mac.launchAgent(mac.home + "/Library/LaunchAgents/com.apple.agent.plist", label: "com.apple.agent", program: "/usr/bin/true")
        for identifier in ["com.apple", "com"] {
            let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
                .scan(bundleIdentifier: identifier, bundlePath: bundle, names: ["Impostor"], teamIdentifier: "TEAM")
            #expect(found.map(\.path) == [mac.home + "/Library/Application Support/Impostor"], "\(identifier)")
            #expect(found.allSatisfy { !$0.selectedByDefault })
        }
    }

    @Test("An identifier in Apple's namespace finds its files but ticks none of them")
    func appleNamespaceIsNeverTicked() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Dock Tweaks", identifier: "com.apple.dock")
        try mac.file("home/Library/Preferences/com.apple.dock.plist")
        try mac.folder("home/Library/Caches/com.apple.dock.extra")
        try mac.launchAgent(mac.home + "/Library/LaunchAgents/com.apple.dock.agent.plist", label: "com.apple.dock.agent", program: "/usr/bin/true")
        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: "com.apple.dock", bundlePath: bundle, names: [], teamIdentifier: nil)
        #expect(found.count == 3)
        #expect(found.allSatisfy { !$0.selectedByDefault && $0.warning == AppLeftoverScanner.appleWarning })
    }

    @Test("A launch agent that starts a program inside the app is still the app's, whatever the identifier")
    func agentsInsideTheBundleStayTicked() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Helper", identifier: "com.apple")
        let agent = try mac.launchAgent(
            mac.home + "/Library/LaunchAgents/helper.plist", label: "helper", program: bundle + "/Contents/MacOS/Helper"
        )
        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: "com.apple", bundlePath: bundle, names: [], teamIdentifier: nil)
        #expect(found.map(\.path) == [agent])
        #expect(found.first?.selectedByDefault == true)
    }

    @Test("System leftovers are not matched by a bundle identifier too short to name one app")
    func systemLeftoversNeedASpecificIdentifier() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Impostor", identifier: "com.google")
        let system = mac.root + "/SystemLibrary"
        try mac.file("SystemLibrary/Application Support/com.google.Keystone")
        let found = SystemLeftoverScanner(
            systemLibrary: system,
            receiptsDirectory: mac.root + "/receipts",
            otherBundleIdentifiers: [],
            userID: getuid()
        ).scan(bundleIdentifier: "com.google", bundlePath: bundle)
        #expect(found.isEmpty)
    }

    @Test("A maker's namespace does not claim what another installed app's identifier or name claims")
    func systemLeftoversLeaveOtherAppsAlone() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Word", identifier: "com.microsoft.Word")
        try mac.app("Excel", identifier: "com.microsoft.Excel")
        try mac.folder("SystemLibrary/Application Support/com.microsoft.Excel")
        try mac.folder("SystemLibrary/Application Support/com.microsoft.autoupdate")
        try mac.folder("SystemLibrary/Application Support/Excel")
        try mac.file("SystemLibrary/Caches/Word")
        let found = SystemLeftoverScanner(
            systemLibrary: mac.root + "/SystemLibrary",
            receiptsDirectory: mac.root + "/receipts",
            otherBundleIdentifiers: ["com.microsoft.Excel"],
            otherNames: ["Excel"],
            userID: getuid()
        ).scan(bundleIdentifier: "com.microsoft.Word", bundlePath: bundle, names: ["Word"])

        #expect(found.map(\.path) == [mac.root + "/SystemLibrary/Application Support/com.microsoft.autoupdate"])
        #expect(found[0].reason.contains("Another installed app has the same maker, so check whose it is"))
    }

    @Test("A maker's namespace is not read out of an identifier too short, or Apple's")
    func vendorNamespaceNeedsASpecificIdentifier() {
        #expect(SystemLeftoverScanner.vendorNamespace(of: "com.teamviewer.TeamViewer") == "com.teamviewer")
        #expect(SystemLeftoverScanner.vendorNamespace(of: "com.google") == nil)
        #expect(SystemLeftoverScanner.vendorNamespace(of: "com.apple.iWork.Keynote") == nil)
    }

    @Test("The plan says why an app's bundle identifier was not used, or why nothing it matched is ticked")
    func identifierWarnings() {
        #expect(UninstallPlanner.identifierWarning("com.openai.chat", app: "ChatGPT") == nil)
        #expect(UninstallPlanner.identifierWarning("com.google", app: "X")?.contains("too short") == true)
        #expect(UninstallPlanner.identifierWarning("com.apple.iWork.Keynote", app: "Keynote")?.contains("ticks none of them") == true)
    }

    // MARK: Zap patterns

    private let home = "/Users/example"

    @Test("A zap wildcard tied to the app is expanded", arguments: [
        "~/Library/Caches/com.microsoft.VSCode*",
        "~/Library/Preferences/ByHost/com.microsoft.VSCode.ShipIt.*.plist",
        "~/Library/Application Support/Code/*",
        "~/Library/Logs/DiagnosticReports/Firefox*",
        "~/Library/Caches/RedisInsight*",
        "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/org.mozilla.firefox.sfl*",
        "~/Library/Caches/Mozilla/updates/*",
        "~/Library/Preferences/org.mozilla.firefox.plist",
        "~/.vscode/extensions/*",
        "/Library/Caches/*",
    ])
    func anchoredPatterns(_ pattern: String) {
        let expander = ZapPathExpander(homeDirectory: home)
        #expect(expander.isAnchored(pattern, owners: ["visual-studio-code", "Visual Studio Code", "Code", "Firefox", "Redis Insight"]))
    }

    @Test("A zap wildcard that could sweep a shared folder is not expanded", arguments: [
        "~/Library/Preferences/*",
        "~/Library/Preferences/ByHost/*",
        "~/Library/Caches/*.plist",
        "~/Library/Caches/com.*",
        "~/Library/Caches/com.microsoft.*",
        "~/Library/Logs/DiagnosticReports/*",
        "~/Library/Application Support/CrashReporter/*",
        "~/Library/Application Support/com.apple.sharedfilelist/*",
        "~/Library/*",
        "~/*",
        "~/.*",
        "~/Documents/*",
        "~/.config/*",
        "~/.local/share/*",
        "~/Library/{Caches/com.example.app,Preferences/*}",
        "/Users/example/Library/Preferences/*",
        "~/Library/Mobile Documents/com~apple~CloudDocs/*",
        "~/Library/Mobile Documents/com~apple~CloudDocs/Documents/*",
        "/Users/example/Library/Mobile Documents/com~apple~CloudDocs/*",
        "~/Library/CloudStorage/*",
        "~/Library/CloudStorage/GoogleDrive-person@example.com/My Drive/*",
    ])
    func broadPatterns(_ pattern: String) {
        let expander = ZapPathExpander(homeDirectory: home)
        #expect(!expander.isAnchored(pattern, owners: ["example", "Example App", "com.example.app"]))
    }

    @Test("In a plan, a broad zap pattern is listed as left in place, and nothing it would match is offered")
    func broadPatternInAPlan() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.app("Redis Insight", identifier: "org.RedisLabs.RedisInsight-V3")
        let info = try Fixture.text("homebrew/info-installed-uninstall.json")
            .replacingOccurrences(of: "/Applications/Redis Insight.app", with: mac.fixture.applications + "/Redis Insight.app")
            .replacingOccurrences(of: "\"~/Library/Logs/RedisInsight\"", with: "\"~/Library/Preferences/*\"")
        try mac.withHomebrew(info: info)
        let dock = try mac.fixture.file("home/Library/Preferences/com.apple.dock.plist")
        let own = try mac.fixture.file("home/Library/Preferences/org.RedisLabs.RedisInsight-V3.plist")

        let plan = try await mac.plan("Redis Insight")
        #expect(!plan.removals.contains { $0.path == dock })
        #expect(plan.removals.contains { $0.path == own && $0.selectedByDefault })
        let refused = try #require(plan.cannotRemove.first { $0.path == "~/Library/Preferences/*" })
        #expect(refused.reason.contains("could match other apps' files"))
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("In a plan, a folder the cask removes only when empty is left in place while it holds your files")
    func rmdirFolderInAPlan() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Fixture.text("homebrew/info-installed-uninstall.json"))
        let codex = try mac.fixture.folder("home/.codex")
        try mac.fixture.file("home/.codex/history.jsonl")

        let plan = try await mac.plan("brew-cask:codex")
        #expect(!plan.removals.contains { $0.path == codex })
        #expect(plan.cannotRemove.contains { $0.path == codex })
        var everything = UninstallSelection(plan)
        everything.includeEverything(from: plan)
        #expect(!everything.contains(codex), "not even \"include everything\" removes a folder that is not empty")
    }

    @Test("A zap entry in Apple's namespace is offered unticked; the cask's own caches stay ticked")
    func appleZapEntriesAreUnticked() {
        let apple = UninstallPlanner.zapLeftover(home + "/Library/Preferences/com.apple.dock.plist", token: "example", homeDirectory: home)
        #expect(!apple.selectedByDefault)
        #expect(apple.warning == AppLeftoverScanner.appleWarning)
        let own = UninstallPlanner.zapLeftover(home + "/Library/Caches/com.example.app", token: "example", homeDirectory: home)
        #expect(own.selectedByDefault)
        #expect(own.warning == nil)
    }

    @Test("A cask cannot anchor a wildcard on a name that is the start of every app's identifier")
    func namespaceNamesAreNotOwners() {
        let expander = ZapPathExpander(homeDirectory: home)
        // A cask declaring `name: ["com"]`: Homebrew constrains neither the
        // token nor the name, so the pattern must be refused on its own.
        #expect(!expander.isAnchored("~/Library/Caches/com.*", owners: ["com", "Com"]))
        #expect(!expander.isAnchored("~/Library/Caches/org.*", owners: ["org"]))
        #expect(!expander.isAnchored("~/Library/Caches/com.google.*", owners: ["com.google"]))
        #expect(expander.isAnchored("~/Library/Caches/com.example.app*", owners: ["com.example.app"]))
    }

    @Test("What a zap wildcard matched is ticked only when the file's own name says it is the app's")
    func wildcardMatchesAreTickedByOwnership() {
        let owners = ["example", "Example App", "com.example.app"]
        let mine = UninstallPlanner.zapLeftover(
            home + "/Library/Caches/com.example.app.helper",
            token: "example",
            owners: owners,
            homeDirectory: home
        )
        #expect(mine.selectedByDefault)
        let theirs = UninstallPlanner.zapLeftover(
            home + "/Library/Caches/com.other.app",
            token: "example",
            owners: owners,
            homeDirectory: home
        )
        #expect(!theirs.selectedByDefault, "a wildcard's anchor says where it looked, not whose files it found")
        #expect(theirs.reason.contains("does not say it is example's"))
        // An exact path the cask wrote out is as far as its word goes, and
        // that has not changed: it is ticked where it always was.
        let exact = UninstallPlanner.zapLeftover(
            home + "/Library/Caches/Example Helper",
            token: "example",
            homeDirectory: home
        )
        #expect(exact.selectedByDefault)
    }

    // MARK: Folders a cask removes only when empty

    private func emptyPlan() -> UninstallPlan {
        UninstallPlan(
            createdAt: Date(),
            subject: UninstallSubject(kind: .cask, target: "brew-cask:example", name: "Example", source: "Homebrew cask"),
            rationale: ""
        )
    }

    @Test("An empty folder, or one holding only Finder's .DS_Store, is offered to remove only while empty")
    func emptyFolderIsOffered() throws {
        let mac = try UninstallFixture()
        let folder = try mac.folder("home/Library/Application Support/Example")
        try mac.file("home/Library/Application Support/Example/.DS_Store")
        var plan = emptyPlan()
        let leftover = try #require(UninstallPlanner.emptyFolderLeftover(folder, token: "example", plan: &plan))
        #expect(leftover.onlyIfEmpty)
        #expect(leftover.selectedByDefault)
        #expect(plan.cannotRemove.isEmpty)
    }

    @Test("A folder holding files the cask does not list is left in place, never offered whole")
    func fullFolderIsLeft() throws {
        let mac = try UninstallFixture()
        let folder = try mac.folder("home/.codex")
        try mac.file("home/.codex/history.jsonl")
        var plan = emptyPlan()
        #expect(UninstallPlanner.emptyFolderLeftover(folder, token: "codex", plan: &plan) == nil)
        #expect(plan.cannotRemove.map(\.path) == [folder])
        #expect(plan.cannotRemove.first?.reason.contains("holds files the cask does not list") == true)
    }

    @Test("A folder emptied by what the plan already removes is offered, ticked as its contents are")
    func folderEmptiedByThePlan() throws {
        let mac = try UninstallFixture()
        let folder = try mac.folder("home/Library/Application Support/Example")
        let cache = try mac.folder("home/Library/Application Support/Example/Cache")
        var plan = emptyPlan()
        plan.removals.append(PlannedRemoval(path: cache, category: .declaredByPackageManager, kind: .directory, selectedByDefault: false, reason: "r"))
        let leftover = try #require(UninstallPlanner.emptyFolderLeftover(folder, token: "example", plan: &plan))
        #expect(leftover.onlyIfEmpty)
        #expect(!leftover.selectedByDefault, "ticked only when everything inside it is")
    }

    @Test("At removal time, a folder to remove only when empty is skipped if anything is in it")
    func removerChecksEmptiness() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let folder = try mac.folder("home/Library/Application Support/Example")
        let status = try #require(FileTree.status(folder))
        let removal = PlannedRemoval(
            path: folder, category: .declaredByPackageManager, kind: .directory, selectedByDefault: true, reason: "r",
            identity: status.identity, onlyIfEmpty: true
        )
        try mac.file("home/Library/Application Support/Example/new-since-review.db")
        for mode in RemovalMode.allCases {
            let outcome = GuardedFileRemover(backend: mac.backend).remove(removal, mode: mode, within: boundary)
            #expect(outcome.status == .skipped)
            #expect(outcome.reason?.contains("not empty") == true)
        }
        #expect(mac.exists(folder + "/new-since-review.db"))
        #expect(mac.backend.trashed.isEmpty && mac.backend.deleted.isEmpty)

        try FileManager.default.removeItem(atPath: folder + "/new-since-review.db")
        try mac.file("home/Library/Application Support/Example/.DS_Store")
        let emptied = GuardedFileRemover(backend: mac.backend).remove(removal, mode: .trash, within: boundary)
        #expect(emptied.status == .removed)
        #expect(!mac.exists(folder))
    }

    @Test("A folder deleted permanently is walked first, and an ordinary one has no other disk inside it")
    func deleteWalksTheFolder() throws {
        let mac = try UninstallFixture()
        let boundary = mac.environment().boundary(homebrewPrefix: nil, forMacUp: false)
        let folder = try mac.folder("home/Library/Caches/com.example.app")
        try mac.file("home/Library/Caches/com.example.app/one")
        #expect(FileTree.size(of: folder)?.otherVolumes == 0)
        let status = try #require(FileTree.status(folder))
        let removal = PlannedRemoval(
            path: folder, category: .belongsToApp, kind: .directory, selectedByDefault: true, reason: "r", identity: status.identity
        )
        #expect(GuardedFileRemover(backend: mac.backend).remove(removal, mode: .delete, within: boundary).status == .removed)
        #expect(!mac.exists(folder))
    }
}
