import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// Finding what to remove: apps, the leftovers an app keeps in the Library,
/// what only an administrator can remove, and what Homebrew declares. All of
/// it runs over a pretend Mac inside a temporary folder.
@Suite("Uninstall: finding what to remove")
struct UninstallScanningTests {
    // MARK: Apps

    @Test("Apps are found in each Applications folder and one folder down, with what their Info.plist says")
    func findsApps() async throws {
        let mac = try UninstallFixture()
        try mac.app("ChatGPT", identifier: "com.openai.chat", version: "1.2025.1", bundleName: "ChatGPT")
        try mac.folder("Applications/Utilities")
        try mac.app("Helper", in: mac.applications + "/Utilities", identifier: "com.example.helper")
        try mac.folder("Applications/Suite/Deeper")
        try mac.app("TooDeep", in: mac.applications + "/Suite/Deeper", identifier: "com.example.deep")
        try mac.app("Mine", in: mac.userApplications, identifier: "com.example.mine")

        let apps = await AppScanner(applicationDirectories: [mac.applications, mac.userApplications]).scan(measure: true)
        #expect(apps.map(\.name) == ["ChatGPT", "Helper", "Mine"])
        let chat = try #require(apps.first)
        #expect(chat.bundleIdentifier == "com.openai.chat")
        #expect(chat.version == "1.2025.1")
        #expect(chat.target == "app:com.openai.chat")
        #expect(chat.source.kind == .downloaded)
        #expect(chat.removability.isRemovable)
        #expect((chat.sizeBytes ?? 0) >= 4096)
    }

    @Test("A Mac App Store receipt and a cask's app target decide where an app came from")
    func sources() async throws {
        let mac = try UninstallFixture()
        let store = try mac.app("Slack", identifier: "com.tinyspeck.slackmacgap", appStore: true)
        let cask = try mac.app("Redis Insight", identifier: "org.RedisLabs.RedisInsight-V3")
        let apps = await AppScanner(applicationDirectories: [mac.applications])
            .scan(caskApps: [cask: "redis-insight"], measure: false)
        #expect(apps.first { $0.path == store }?.source.kind == .appStore)
        let owned = try #require(apps.first { $0.path == cask })
        #expect(owned.source.kind == .homebrewCask)
        #expect(owned.source.caskToken == "redis-insight")
    }

    @Test("An app linked into Applications, as Safari is, is never offered, and says why")
    func linkedApps() async throws {
        let mac = try UninstallFixture()
        let real = try mac.app("Browser", in: try mac.folder("elsewhere"), identifier: "com.example.browser")
        try FileManager.default.createSymbolicLink(atPath: mac.applications + "/Browser.app", withDestinationPath: real)
        let apps = await AppScanner(applicationDirectories: [mac.applications]).scan(measure: false)
        let link = try #require(apps.first)
        #expect(!link.removability.isRemovable)
        #expect(link.removability.kind == .notSupported)
        #expect(link.removability.reason?.contains("link") == true)
    }

    @Test("An app the user cannot move needs an administrator, with the steps to do it by hand")
    func appsThatNeedAnAdministrator() async throws {
        let mac = try UninstallFixture()
        let path = try mac.app("Xcode", identifier: "com.apple.dt.Xcode", appStore: true)
        chmod(path, 0o555)
        let app = try #require(AppScanner(applicationDirectories: [mac.applications]).app(at: path, measure: true))
        #expect(app.removability.kind == .needsAdministrator)
        #expect(app.removability.steps.contains { $0.contains("Launchpad") })
        #expect(app.removability.steps.contains { $0.contains("administrator") })
    }

    // MARK: Leftovers in the Library

    @Test("Each leftover is found by its rule and ticked by default only when it is not data")
    func libraryLeftovers() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("ChatGPT", identifier: "com.openai.chat")
        let lib = "home/Library/"
        try mac.file(lib + "Preferences/com.openai.chat.plist")
        try mac.file(lib + "Preferences/ByHost/com.openai.chat.0F2A.plist")
        try mac.folder(lib + "Caches/com.openai.chat")
        try mac.folder(lib + "Saved Application State/com.openai.chat.savedState")
        try mac.file(lib + "HTTPStorages/com.openai.chat.binarycookies")
        try mac.folder(lib + "Logs/com.openai.chat")
        try mac.folder(lib + "Application Support/com.openai.chat")
        try mac.folder(lib + "Containers/com.openai.chat")
        try mac.folder(lib + "Group Containers/2DC432GLL2.com.openai.chat.notifications")
        try mac.folder(lib + "Group Containers/2DC432GLL2.com.openai.sky")
        try mac.folder(lib + "Application Support/ChatGPT")
        // Near misses, which must not match.
        try mac.file(lib + "Preferences/com.openai.chatter.plist")
        try mac.file(lib + "Preferences/com.openai.plist")
        try mac.file(lib + "Application Support/ChatGPT Notes")

        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: "com.openai.chat", bundlePath: bundle, names: ["ChatGPT"], teamIdentifier: "2DC432GLL2")
        func item(_ relative: String) -> Leftover? { found.first { $0.path == mac.home + "/Library/" + relative } }

        for own in ["Preferences/com.openai.chat.plist", "Preferences/ByHost/com.openai.chat.0F2A.plist", "Caches/com.openai.chat",
                    "Saved Application State/com.openai.chat.savedState", "HTTPStorages/com.openai.chat.binarycookies",
                    "Logs/com.openai.chat"] {
            #expect(item(own)?.category == .belongsToApp, "\(own)")
            #expect(item(own)?.selectedByDefault == true, "\(own)")
        }
        for data in ["Application Support/com.openai.chat", "Containers/com.openai.chat",
                     "Group Containers/2DC432GLL2.com.openai.chat.notifications"] {
            #expect(item(data)?.category == .appData, "\(data)")
            #expect(item(data)?.selectedByDefault == false, "\(data)")
            #expect(item(data)?.warning == "Your chats, saved games, and settings in this app.")
        }
        let byName = try #require(item("Application Support/ChatGPT"))
        #expect(byName.category == .matchedByName)
        #expect(!byName.selectedByDefault)
        #expect(byName.reason.contains("Matched by name only; check before removing"))

        #expect(item("Preferences/com.openai.chatter.plist") == nil)
        #expect(item("Preferences/com.openai.plist") == nil)
        #expect(item("Group Containers/2DC432GLL2.com.openai.sky") == nil)
        #expect(item("Application Support/ChatGPT Notes") == nil)
        #expect(found.count == 10)
    }

    @Test("A name belonging to another installed app's longer bundle ID is left to that app")
    func otherAppsKeepTheirs() throws {
        let mac = try UninstallFixture()
        let chrome = try mac.app("Google Chrome", identifier: "com.google.Chrome")
        try mac.file("home/Library/Preferences/com.google.Chrome.plist")
        try mac.file("home/Library/Preferences/com.google.Chrome.canary.plist")
        try mac.folder("home/Library/Caches/com.google.Chrome.canary")
        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: ["com.google.Chrome.canary"])
            .scan(bundleIdentifier: "com.google.Chrome", bundlePath: chrome, names: [], teamIdentifier: nil)
        #expect(found.map(\.path) == [mac.home + "/Library/Preferences/com.google.Chrome.plist"])
    }

    @Test("Without a team identifier from the signature, no group container is tied to the app")
    func groupContainersNeedTheTeam() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Chat", identifier: "com.openai.chat")
        try mac.folder("home/Library/Group Containers/2DC432GLL2.com.openai.chat")
        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: "com.openai.chat", bundlePath: bundle, names: [], teamIdentifier: nil)
        #expect(found.isEmpty)
    }

    @Test("A launch agent is the app's when its label follows the bundle ID or it starts a program inside the app")
    func launchAgents() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Docker", identifier: "com.docker.docker")
        let agents = mac.home + "/Library/LaunchAgents/"
        try mac.launchAgent(agents + "com.docker.docker.helper.plist", label: "com.docker.docker.helper", program: "/usr/bin/true")
        try mac.launchAgent(agents + "com.docker.socket.plist", label: "com.docker.socket", program: bundle + "/Contents/MacOS/Docker")
        try mac.launchAgent(agents + "com.other.agent.plist", label: "com.other.agent", program: "/usr/bin/true")
        let found = AppLeftoverScanner(homeDirectory: mac.home, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: "com.docker.docker", bundlePath: bundle, names: [], teamIdentifier: nil)
        #expect(Set(found.map(\.path)) == [agents + "com.docker.docker.helper.plist", agents + "com.docker.socket.plist"])
        #expect(found.allSatisfy { $0.category == .belongsToApp && $0.selectedByDefault })
        #expect(found.contains { $0.reason.contains("starts a program inside Docker.app") })
    }

    @Test("What an app left where only an administrator can change it is listed with the exact steps")
    func systemLeftovers() throws {
        let mac = try UninstallFixture()
        let bundle = try mac.app("Docker", identifier: "com.docker.docker")
        try mac.folder("SystemLibrary/Application Support/com.docker.docker")
        try mac.launchAgent(mac.root + "/SystemLibrary/LaunchDaemons/com.docker.vmnetd.plist", label: "com.docker.vmnetd", program: bundle + "/Contents/Library/vmnetd")
        try mac.file("receipts/com.docker.docker.pkg.plist")
        try mac.file("receipts/com.docker.docker.pkg.bom")
        let found = SystemLeftoverScanner(
            systemLibrary: mac.root + "/SystemLibrary",
            receiptsDirectory: mac.root + "/receipts",
            otherBundleIdentifiers: [],
            userID: 501
        ).scan(bundleIdentifier: "com.docker.docker", bundlePath: bundle)
        #expect(found.count == 3)
        let daemon = try #require(found.first { $0.path.hasSuffix("com.docker.vmnetd.plist") })
        #expect(daemon.steps.first == "In Terminal, stop it: sudo launchctl bootout system/com.docker.vmnetd")
        #expect(daemon.reason.contains("MacUp never asks for a password"))
        let receipt = try #require(found.first { $0.path.hasSuffix(".pkg.plist") })
        #expect(receipt.steps == ["In Terminal, run: sudo pkgutil --forget com.docker.docker.pkg"])
    }

    // MARK: Homebrew

    @Test("A cask's app target, zap list, and need for an administrator come from Homebrew's own JSON")
    func caskFixture() throws {
        let data = try Fixture.data("homebrew/info-installed-uninstall.json")
        let listing = try HomebrewCaskParser.parse(data, homeDirectory: "/Users/example")
        #expect(listing.elements.map(\.token) == ["codex", "redis-insight", "example-pkg"])

        let redis = try #require(listing.elements.first { $0.token == "redis-insight" })
        #expect(redis.appPaths == ["/Applications/Redis Insight.app"])
        #expect(redis.installedVersion == "3.6.0")
        #expect(redis.zap.count == 9)
        #expect(redis.zap.allSatisfy { $0.action == .trash })
        #expect(redis.zap.contains { $0.pattern == "~/Library/Preferences/org.RedisLabs.RedisInsight-V3.plist" })
        #expect(redis.administratorReasons.isEmpty)

        let codex = try #require(listing.elements.first { $0.token == "codex" })
        #expect(codex.appPaths.isEmpty, "a binary is not an app")
        #expect(codex.zap == [ZapDirective(action: .rmdir, pattern: "~/.codex")])

        let pkg = try #require(listing.elements.first { $0.token == "example-pkg" })
        #expect(pkg.administratorReasons.count == 2)
    }

    @Test("Zap patterns expand in code: home, globs, and braces, never ** and never through a link")
    func zapExpansion() throws {
        let mac = try UninstallFixture()
        try mac.file("home/Library/Application Support/com.apple.sharedfilelist/Recent/org.example.app.sfl2")
        try mac.file("home/Library/Application Support/com.apple.sharedfilelist/Recent/org.example.app.sfl3")
        try mac.file("home/Library/Application Support/com.apple.sharedfilelist/Recent/org.other.sfl2")
        try mac.folder("home/Library/Caches/org.example.app")
        try mac.folder("home/Library/Caches/org.example.app.ShipIt")
        try mac.folder("outside/secret")
        try FileManager.default.createSymbolicLink(atPath: mac.home + "/Library/Caches/link", withDestinationPath: mac.root + "/outside")
        let expander = ZapPathExpander(homeDirectory: mac.home)

        #expect(expander.expand("~/Library/Application Support/com.apple.sharedfilelist/Recent/org.example.app.sfl*") == .paths([
            mac.home + "/Library/Application Support/com.apple.sharedfilelist/Recent/org.example.app.sfl2",
            mac.home + "/Library/Application Support/com.apple.sharedfilelist/Recent/org.example.app.sfl3",
        ]))
        #expect(expander.expand("~/Library/Caches/org.example.app{,.ShipIt}") == .paths([
            mac.home + "/Library/Caches/org.example.app",
            mac.home + "/Library/Caches/org.example.app.ShipIt",
        ]))
        #expect(expander.expand("~/Library/Caches/missing") == .paths([]))
        #expect(expander.expand("~/Library/Caches/link/secret") == .paths([]), "a link is never walked through")
        #expect(expander.expand("~/Library/Caches/link") == .paths([mac.home + "/Library/Caches/link"]))
        if case .refused = expander.expand("~/Library/**/org.example.app") {} else { Issue.record("** must be refused") }
        if case .refused = expander.expand("Library/Caches/x") {} else { Issue.record("a relative pattern must be refused") }
        if case .refused = expander.expand("~/Library/../../outside") {} else { Issue.record(".. must be refused") }
    }

    @Test("A formula's data folders are offered unticked, its downloads ticked, and a longer name is not a match")
    func formulaLeftovers() throws {
        let mac = try UninstallFixture()
        let prefix = try mac.folder("homebrew")
        try mac.folder("homebrew/var/mysql")
        try mac.folder("homebrew/var/mysql-3307")
        try mac.file("homebrew/etc/my.cnf")
        let cache = try mac.folder("home/Library/Caches/Homebrew")
        let sha = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        try mac.file("home/Library/Caches/Homebrew/downloads/\(sha)--mysql--9.7.1.arm64_tahoe.bottle.tar.gz")
        try mac.file("home/Library/Caches/Homebrew/downloads/\(other)--mysql-9.7.1.bottle_manifest.json")
        try mac.file("home/Library/Caches/Homebrew/downloads/\(sha)--mysql-connector--1.0.bottle.tar.gz")
        try FileManager.default.createSymbolicLink(
            atPath: cache + "/mysql--9.7.1",
            withDestinationPath: "downloads/\(sha)--mysql--9.7.1.arm64_tahoe.bottle.tar.gz"
        )
        try mac.file("home/Library/Caches/Homebrew/mysql-connector--1.0")

        let found = HomebrewLeftoverScanner(prefix: prefix, cacheDirectory: cache).formula("mysql")
        let data = found.filter { $0.category == .formulaData }
        #expect(data.map(\.path) == [prefix + "/var/mysql"])
        #expect(data.allSatisfy { !$0.selectedByDefault && $0.warning != nil })
        let caches = found.filter { $0.category == .downloadCache }
        #expect(Set(caches.map(\.path)) == [
            cache + "/mysql--9.7.1",
            cache + "/downloads/\(sha)--mysql--9.7.1.arm64_tahoe.bottle.tar.gz",
            cache + "/downloads/\(other)--mysql-9.7.1.bottle_manifest.json",
        ])
        #expect(caches.allSatisfy { $0.selectedByDefault })
    }

    // MARK: The whole list

    @Test("The list has apps, every package manager's packages, and each mise version on its own")
    func catalog() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.app("ChatGPT", identifier: "com.openai.chat")
        try mac.fixture.app("Redis Insight", identifier: "org.RedisLabs.RedisInsight-V3")
        let info = try Fixture.text("homebrew/info-installed-uninstall.json")
            .replacingOccurrences(of: "/Applications/Redis Insight.app", with: mac.fixture.applications + "/Redis Insight.app")
        try mac.withHomebrew(info: info)
        mac.withNpm(packages: ["typescript": "5.9.2", "@anthropic-ai/claude-code": "2.1.0"])
        mac.withMise(list: MiseListing.twoNodes)

        let catalog = await mac.catalog()
        #expect(catalog.apps.map(\.name) == ["ChatGPT", "Redis Insight"])
        #expect(catalog.apps.last?.source.caskToken == "redis-insight")
        #expect(catalog.packages.map(\.target) == [
            "brew:lua", "brew:mysql", "brew:postgresql@16",
            "brew-cask:codex", "brew-cask:example-pkg", "brew-cask:redis-insight",
            "npm:@anthropic-ai/claude-code", "npm:typescript",
            "mise:node@24.18.0", "mise:node@24.19.0",
        ], "\(catalog.packages.map(\.target))")
        #expect(catalog.packages.first { $0.target == "brew:mysql" }?.note == "2 versions installed: 9.7.1, 26.7.0_2")
        #expect(catalog.packages.first { $0.target == "mise:node@24.19.0" }?.note == "In use")
        #expect(catalog.providers.allSatisfy { $0.state == .available })
        #expect(mac.modifyingRequests.isEmpty)
        #expect(catalog.commands.allSatisfy { $0.effect == .readOnly })
    }

    @Test("A package manager turned off in MacUp is not asked at all")
    func providerOff() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Fixture.text("homebrew/info-installed-uninstall.json"))
        var configuration = MacUpConfiguration.defaults
        configuration.providers["homebrew"] = MacUpConfiguration.ProviderSettings(enabled: false)
        let catalog = await mac.catalog(configuration: LoadedConfiguration(configuration: configuration, source: .file, path: "/x"))
        #expect(catalog.state(of: .homebrew)?.state == .off)
        #expect(catalog.packages(of: .homebrew).isEmpty)
        #expect(!mac.runner.recordedInvocations.contains { $0.executable.hasSuffix("/brew") })
    }

    @Test("A python.org Python is listed with the manual steps, never as something MacUp removes")
    func pythonOrg() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.folder("SystemLibrary/Frameworks/Python.framework/Versions/3.13")
        try FileManager.default.createSymbolicLink(
            atPath: mac.fixture.root + "/SystemLibrary/Frameworks/Python.framework/Versions/Current",
            withDestinationPath: "3.13"
        )
        let catalog = await mac.catalog()
        let python = try #require(catalog.manualInstalls.first)
        #expect(python.name == "Python 3.13 from python.org")
        #expect(python.reason.contains("only an administrator"))
        #expect(python.steps.contains { $0.contains("sudo rm -rf") })
        #expect(python.steps.contains { $0.contains("pkgutil --forget") })
    }
}

/// `mise ls --json` with two installed Node versions, one in use from the
/// global configuration.
enum MiseListing {
    static let twoNodes = """
        {"node": [
          {"version": "24.18.0", "install_path": "/Users/example/.local/share/mise/installs/node/24.18.0", "installed": true, "active": false},
          {"version": "24.19.0", "requested_version": "24.19.0", "install_path": "/Users/example/.local/share/mise/installs/node/24.19.0",
           "source": {"type": "mise.toml", "path": "/Users/example/.config/mise/config.toml"}, "installed": true, "active": true}
        ]}
        """
}
