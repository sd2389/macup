import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// What an uninstall would do, for every kind of thing MacUp uninstalls.
/// Planning runs nothing that changes anything; every test checks that too.
@Suite("Uninstall: planning")
struct UninstallPlanningTests {
    /// Homebrew's JSON, with the cask's app moved into the fixture.
    private static func info(_ mac: UninstallScenario) throws -> String {
        try Fixture.text("homebrew/info-installed-uninstall.json")
            .replacingOccurrences(of: "/Applications/Redis Insight.app", with: mac.fixture.applications + "/Redis Insight.app")
    }

    private static let services = """
        [{"name": "mysql", "status": "started", "user": "example", "file": "/Users/example/Library/LaunchAgents/homebrew.mxcl.mysql.plist", "exit_code": null},
         {"name": "postgresql@16", "status": "started", "user": "root", "file": "/Library/LaunchDaemons/homebrew.mxcl.postgresql@16.plist", "exit_code": null}]
        """

    // MARK: Apps

    @Test("A downloaded app: MacUp removes the bundle and its ticked leftovers itself, and runs no command")
    func downloadedApp() async throws {
        let mac = try UninstallScenario()
        let bundle = try mac.fixture.app("ChatGPT", identifier: "com.openai.chat")
        try mac.fixture.file("home/Library/Preferences/com.openai.chat.plist")
        try mac.fixture.folder("home/Library/Application Support/com.openai.chat")
        mac.fixture.signatures.sign(bundle, team: "2DC432GLL2")
        try mac.fixture.folder("home/Library/Group Containers/2DC432GLL2.com.openai.chat")

        let plan = try await mac.plan("ChatGPT")
        #expect(plan.canRun)
        #expect(plan.subject.kind == .app)
        #expect(plan.subject.target == "app:com.openai.chat")
        #expect(plan.steps.isEmpty)
        #expect(plan.removals.first?.path == bundle)
        #expect(plan.removals.first?.isRequired == true)
        #expect(plan.removals.first?.role == .bundle)
        #expect(plan.defaultSelection == [bundle, mac.fixture.library + "/Preferences/com.openai.chat.plist"])
        #expect(plan.removals.filter { $0.category == .appData }.count == 2)
        #expect(plan.rollback(for: .trash).explanation.contains("put back from the Trash"))
        #expect(plan.rollback(for: .delete).explanation.contains("cannot be undone"))
        #expect(plan.rollback(for: .trash).availability == .unavailable)
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("An app that is open cannot be uninstalled until it is quit")
    func runningApp() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.app("Claude", identifier: "com.anthropic.claudefordesktop")
        mac.fixture.running.open("com.anthropic.claudefordesktop", name: "Claude")
        let plan = try await mac.plan("app:com.anthropic.claudefordesktop")
        #expect(plan.blockers.map(\.kind) == [.appRunning])
        #expect(plan.blockers.first?.message == "Quit Claude first.")
    }

    @Test("An App Store app the user cannot move is not removed, and the steps say how")
    func appStoreApp() async throws {
        let mac = try UninstallScenario()
        let bundle = try mac.fixture.app("Keynote", identifier: "com.apple.iWork.Keynote", appStore: true)
        chmod(bundle, 0o555)
        let plan = try await mac.plan("Keynote")
        #expect(plan.subject.source == "Mac App Store")
        #expect(plan.blockers.first?.kind == .needsAdministrator)
        #expect(plan.blockers.first?.steps.first?.contains("Launchpad") == true)
        #expect(!plan.removals.contains { $0.path == bundle })
    }

    @Test("When Homebrew could not be asked, MacUp will not guess that it did not install the app")
    func unknownOwner() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.app("Tool", identifier: "com.example.tool")
        mac.fileSystem.addExecutable(UninstallScenario.brew)
        mac.runner.register("brew", ["--version"], .exit(1, standardError: "broken"))
        let plan = try await mac.plan("Tool")
        #expect(plan.blockers.contains { $0.kind == .ownershipUnknown })
    }

    // MARK: Homebrew

    @Test("A cask is uninstalled by Homebrew, never with --zap, and MacUp removes its zap list itself")
    func cask() async throws {
        let mac = try UninstallScenario()
        let app = try mac.fixture.app("Redis Insight", identifier: "org.RedisLabs.RedisInsight-V3")
        try mac.withHomebrew(info: try Self.info(mac))
        try mac.fixture.folder("home/Library/Caches/org.RedisLabs.RedisInsight-V3")
        try mac.fixture.folder("home/Library/Application Support/RedisInsight")
        try mac.fixture.file("home/.redisinsight-app/settings.json")

        let plan = try await mac.plan("Redis Insight")
        #expect(plan.subject.kind == .cask)
        #expect(plan.subject.target == "brew-cask:redis-insight")
        #expect(plan.steps.map(\.invocation.arguments) == [["uninstall", "--cask", "redis-insight"]])
        #expect(plan.steps.allSatisfy { $0.invocation.executable == UninstallScenario.brew && $0.effect == .modifying })
        #expect(!plan.removals.contains { $0.path == app }, "Homebrew removes the app")
        let caches = try #require(plan.removals.first { $0.path.hasSuffix("Caches/org.RedisLabs.RedisInsight-V3") })
        #expect(caches.selectedByDefault)
        let support = try #require(plan.removals.first { $0.path.hasSuffix("Application Support/RedisInsight") })
        #expect(support.category == .declaredByPackageManager || support.category == .matchedByName)
        #expect(!support.selectedByDefault)
        let dotfolder = try #require(plan.removals.first { $0.path.hasSuffix(".redisinsight-app") })
        #expect(!dotfolder.selectedByDefault)
        #expect(dotfolder.warning != nil)
        #expect(plan.canRun)
        #expect(try await mac.plan("brew-cask:redis-insight").steps == plan.steps, "the app and its cask are one plan")
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("A cask that installs with an installer package needs an administrator, so MacUp will not run it")
    func pkgCask() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Self.info(mac))
        let plan = try await mac.plan("brew-cask:example-pkg")
        #expect(plan.blockers.contains { $0.kind == .needsAdministrator })
        #expect(plan.blockers.first { $0.kind == .needsAdministrator }?.steps.first?.contains("brew uninstall --cask example-pkg") == true)
    }

    @Test("A formula stops its service first, then removes every version, and keeps its data unless ticked")
    func formula() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Self.info(mac), services: Self.services)
        mac.dependents(of: "mysql")
        let data = try mac.fixture.folder("homebrew/var/mysql")

        let plan = try await mac.plan("brew:mysql")
        #expect(plan.canRun, "\(plan.blockers)")
        #expect(plan.steps.map(\.invocation.arguments) == [
            ["services", "stop", "mysql"],
            ["uninstall", "--formula", "--force", "mysql"],
        ])
        let folder = try #require(plan.removals.first { $0.path == data })
        #expect(folder.category == .formulaData)
        #expect(!folder.selectedByDefault)
        #expect(plan.defaultSelection.isEmpty)
        #expect(plan.rationale.contains("9.7.1, 26.7.0_2"))
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("A formula other software needs is not removed, and MacUp names what needs it")
    func dependents() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Self.info(mac), services: Self.services)
        mac.dependents(of: "lua", formulae: "luarocks\nneovim\n")
        let plan = try await mac.plan("brew:lua")
        let blocker = try #require(plan.blockers.first { $0.kind == .hasDependents })
        #expect(blocker.dependents?.map(\.rawValue) == ["brew:luarocks", "brew:neovim"])
        #expect(blocker.message.contains("brew:luarocks, brew:neovim"))
    }

    @Test("When MacUp cannot find out what depends on a formula, it does not remove it")
    func dependentsUnknown() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Self.info(mac))
        mac.runner.register("brew", ["uses", "--installed", "--formula", "lua"], .exit(1, standardError: "Error"))
        mac.runner.register("brew", ["uses", "--installed", "--cask", "lua"], .success())
        let plan = try await mac.plan("brew:lua")
        #expect(plan.blockers.contains { $0.kind == .hasDependents })
    }

    @Test("A service that runs for the whole Mac needs an administrator to stop, so MacUp refuses")
    func rootService() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Self.info(mac), services: Self.services)
        mac.dependents(of: "postgresql@16")
        let plan = try await mac.plan("brew:postgresql@16")
        #expect(plan.blockers.contains { $0.kind == .needsAdministrator && $0.message.contains("for the whole Mac") })
    }

    @Test("A pinned formula is not uninstalled: MacUp does not unpin anything")
    func pinned() async throws {
        let mac = try UninstallScenario()
        let info = try Self.info(mac).replacingOccurrences(of: "\"pinned\": false,\n      \"service\": null", with: "\"pinned\": true,\n      \"service\": null")
        try mac.withHomebrew(info: info)
        mac.dependents(of: "lua")
        let plan = try await mac.plan("brew:lua")
        #expect(plan.blockers.contains { $0.kind == .pinned })
    }

    // MARK: npm and mise

    @Test("An npm package is removed with npm uninstall -g, and npm itself is not")
    func npm() async throws {
        let mac = try UninstallScenario()
        mac.withNpm(packages: ["@anthropic-ai/claude-code": "2.1.0", "npm": "10.9.8"])
        let plan = try await mac.plan("npm:@anthropic-ai/claude-code")
        #expect(plan.steps.map(\.invocation.arguments) == [["uninstall", "-g", "@anthropic-ai/claude-code"]])
        #expect(plan.canRun)
        let npm = try await mac.plan("npm:npm")
        #expect(npm.steps.isEmpty)
        #expect(npm.blockers.first?.kind == .unsupported)
    }

    @Test("A mise runtime names one exact version, and the one in use warns that the configuration still asks for it")
    func mise() async throws {
        let mac = try UninstallScenario()
        mac.withMise(list: MiseListing.twoNodes)
        let old = try await mac.plan("mise:node@24.18.0")
        #expect(old.steps.map(\.invocation.arguments) == [["uninstall", "node@24.18.0"]])
        #expect(old.warnings.isEmpty)
        let current = try await mac.plan("mise:node@24.19")
        #expect(current.steps.map(\.invocation.arguments) == [["uninstall", "node@24.19.0"]])
        #expect(current.warnings.first?.contains("still names node 24.19.0") == true)
        #expect(current.warnings.first?.contains("MacUp leaves that file alone") == true)
    }

    // MARK: What stops everything

    @Test("A configuration MacUp cannot read stops every uninstall, and a turned-off provider stops its own")
    func configuration() async throws {
        let mac = try UninstallScenario()
        mac.withNpm(packages: ["typescript": "5.9.2"])
        let broken = LoadedConfiguration(
            configuration: .defaults,
            source: .file,
            path: "/x",
            issues: [ConfigurationIssue(.error, "", "Not JSON.")]
        )
        let plan = try await mac.plan("npm:typescript", configuration: broken)
        #expect(plan.blockers.first?.kind == .configurationInvalid)
    }

    // MARK: MacUp itself

    @Test("Uninstalling MacUp removes its command, configuration, Library entries, history, and app, the app last")
    func macUp() async throws {
        let mac = try UninstallScenario()
        let paths = mac.fixture.paths
        try mac.fixture.file("home/.local/bin/macup")
        try mac.fixture.file("home/.config/macup/config.json", "{}")
        try mac.fixture.file("home/.local/state/macup/history.jsonl")
        try mac.fixture.file("home/Library/Preferences/dev.macup.MacUp.plist")
        try mac.fixture.file("home/Library/LaunchAgents/com.macup.check.plist")
        let app = try mac.fixture.app("MacUp", identifier: "dev.macup.MacUp")
        mac.fixture.keychain.saveLeftover()

        let plan = try await mac.plan("macup", environment: mac.fixture.environment(currentAppBundle: app))
        #expect(plan.subject.kind == .macUp)
        #expect(plan.canRun, "\(plan.blockers)")
        #expect(plan.actions.map(\.kind) == [.removeScheduledCheck, .deleteKeychainItem])
        #expect(plan.removals.map(\.path) == [
            mac.fixture.home + "/.local/bin/macup",
            paths.configDirectory,
            mac.fixture.library + "/Preferences/dev.macup.MacUp.plist",
            paths.stateDirectory,
            app,
        ])
        #expect(plan.removals.allSatisfy { $0.selectedByDefault })
        #expect(plan.removals.last?.role == .bundle)
        #expect(plan.removals[3].role == .macUpState)
    }

    @Test("From the command line, MacUp will not uninstall itself while its app is open")
    func macUpAppOpen() async throws {
        let mac = try UninstallScenario()
        let app = try mac.fixture.app("MacUp", identifier: "dev.macup.MacUp")
        mac.fixture.running.open(app, name: "MacUp")
        let plan = try await mac.plan("macup")
        #expect(plan.blockers.contains { $0.kind == .appRunning && $0.message == "Quit the MacUp app first." })
    }

    // MARK: Naming things

    @Test("Names resolve to exactly one thing, or MacUp says what else they could mean")
    func resolving() async throws {
        let mac = try UninstallScenario()
        try mac.fixture.app("Twin", identifier: "com.example.twin")
        try mac.fixture.app("Twin", in: mac.fixture.userApplications, identifier: "com.example.twin")
        mac.withMise(list: MiseListing.twoNodes)
        mac.withNpm(packages: ["typescript": "5.9.2"])
        let catalog = await mac.catalog()
        let home = mac.fixture.home

        guard case .failure(let twin) = UninstallTargetResolver.resolve("Twin", in: catalog, homeDirectory: home) else {
            Issue.record("two apps with one name must not resolve")
            return
        }
        #expect(twin.kind == .ambiguous)
        #expect(twin.candidates.count == 2)
        guard case .success(.app(let one)) = UninstallTargetResolver.resolve(mac.fixture.applications + "/Twin.app", in: catalog, homeDirectory: home) else {
            Issue.record("a path names one app")
            return
        }
        #expect(one.path == mac.fixture.applications + "/Twin.app")

        guard case .failure(let node) = UninstallTargetResolver.resolve("mise:node", in: catalog, homeDirectory: home) else {
            Issue.record("two installed versions need naming")
            return
        }
        #expect(node.kind == .ambiguous)
        #expect(node.candidates == ["mise:node@24.18.0", "mise:node@24.19.0"])

        guard case .failure(let hint) = UninstallTargetResolver.resolve("typescript", in: catalog, homeDirectory: home) else {
            Issue.record("a bare name is an app name")
            return
        }
        #expect(hint.message.contains("Did you mean npm:typescript?"))

        if case .success(.macUp) = UninstallTargetResolver.resolve("MacUp", in: catalog, homeDirectory: home) {} else {
            Issue.record("MacUp resolves to itself")
        }
        if case .failure = UninstallTargetResolver.resolve("macos:27.1", in: catalog, homeDirectory: home) {} else {
            Issue.record("macOS updates are not uninstalled")
        }
    }

    // MARK: The rules the commands must match

    @Test("Every uninstall command matches exactly one reviewed shape, and none of the forbidden flags fit")
    func rules() {
        func request(_ executable: String, _ arguments: [String]) -> CommandRequest {
            CommandRequest(executable: URL(fileURLWithPath: executable), arguments: arguments, effect: .modifying)
        }
        let allowed = [
            request("/opt/homebrew/bin/brew", ["uninstall", "--formula", "--force", "mysql"]),
            request("/opt/homebrew/bin/brew", ["uninstall", "--cask", "firefox"]),
            request("/opt/homebrew/bin/brew", ["services", "stop", "mysql"]),
            request("/opt/homebrew/bin/npm", ["uninstall", "-g", "@anthropic-ai/claude-code"]),
            request("/Users/example/.local/bin/mise", ["uninstall", "node@24.18.0"]),
        ]
        for command in allowed {
            #expect(ModifyingCommandRules.uninstall.filter { $0.matches(command) }.count == 1, "\(command.arguments)")
            #expect(!ModifyingCommandRules.all.contains { $0.matches(command) }, "an update may never uninstall")
        }
        let refused = [
            request("/opt/homebrew/bin/brew", ["uninstall", "--cask", "--zap", "firefox"]),
            request("/opt/homebrew/bin/brew", ["uninstall", "--formula", "--force", "--ignore-dependencies", "mysql"]),
            request("/opt/homebrew/bin/brew", ["uninstall", "--formula", "--force"]),
            request("/opt/homebrew/bin/brew", ["uninstall", "mysql"]),
            request("/opt/homebrew/bin/brew", ["autoremove"]),
            request("/opt/homebrew/bin/brew", ["cleanup"]),
            request("/opt/homebrew/bin/brew", ["services", "stop", "--all"]),
            request("/Users/example/.local/bin/mise", ["uninstall", "--all", "node@24"]),
            request("/Users/example/.local/bin/mise", ["uninstall", "node@1", "node@2"]),
            request("/opt/homebrew/bin/npm", ["uninstall", "typescript"]),
        ]
        for command in refused {
            #expect(!ModifyingCommandRules.uninstall.contains { $0.matches(command) }, "\(command.arguments)")
        }
    }
}
