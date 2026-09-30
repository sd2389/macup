import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// Carrying out a confirmed uninstall: the checks made again immediately
/// before anything runs, the order things happen in, the two removal modes,
/// and what history records. Removal goes through a fake Trash inside the
/// test's temporary folder; the package managers are a fake runner.
@Suite("Uninstall: carrying it out")
struct UninstallEngineTests {
    private func engine(_ mac: UninstallScenario) -> UninstallEngine {
        UninstallEngine(history: HistoryStore(paths: mac.fixture.paths))
    }

    private func run(
        _ mac: UninstallScenario,
        _ plan: UninstallPlan,
        selection: Set<String>? = nil,
        mode: RemovalMode = .trash,
        options: UninstallOptions = UninstallOptions(origin: .cli),
        environment: UninstallEnvironment? = nil
    ) async -> UninstallReport {
        await engine(mac).run(
            plan,
            selection: selection ?? plan.defaultSelection,
            mode: mode,
            options: options,
            configuration: mac.configuration,
            environment: mac.checkEnvironment,
            uninstall: environment ?? mac.fixture.environment()
        )
    }

    private func history(_ mac: UninstallScenario) throws -> [HistoryEntry] {
        try HistoryStore(paths: mac.fixture.paths).load()
    }

    /// ChatGPT with one ticked leftover and one unticked data folder.
    private func chatGPT(_ mac: UninstallScenario) throws -> (bundle: String, preference: String, data: String) {
        let bundle = try mac.fixture.app("ChatGPT", identifier: "com.openai.chat", version: "1.2025.1")
        let preference = try mac.fixture.file("home/Library/Preferences/com.openai.chat.plist")
        let data = try mac.fixture.folder("home/Library/Application Support/com.openai.chat")
        try mac.fixture.file("home/Library/Application Support/com.openai.chat/conversations.json")
        return (bundle, preference, data)
    }

    @Test("Move to Trash moves the app and what was ticked to the Trash, and leaves unticked data alone")
    func trash() async throws {
        let mac = try UninstallScenario()
        let files = try chatGPT(mac)
        let plan = try await mac.plan("ChatGPT")
        let report = await run(mac, plan)

        #expect(report.outcome == .uninstalled)
        #expect(report.isConfirmed)
        #expect(mac.fixture.backend.trashed == [files.bundle, files.preference], "the bundle goes first")
        #expect(mac.fixture.backend.deleted.isEmpty)
        #expect(mac.fixture.exists(files.data), "data that was not ticked is never touched")
        #expect(report.kept.map(\.path) == [files.data])
        #expect(report.summary.keptData == 1)
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("Delete Permanently deletes exactly the ticked items, and nothing goes to the Trash")
    func delete() async throws {
        let mac = try UninstallScenario()
        let files = try chatGPT(mac)
        let plan = try await mac.plan("ChatGPT")
        let report = await run(mac, plan, selection: plan.everything, mode: .delete)
        #expect(report.outcome == .uninstalled)
        #expect(Set(mac.fixture.backend.deleted) == [files.bundle, files.preference, files.data])
        #expect(mac.fixture.backend.trashed.isEmpty)
        #expect(!mac.fixture.exists(files.data))
        #expect(report.removals.allSatisfy { $0.mode == .delete })
    }

    @Test("A path that is not in the plan can never be removed, whatever the selection says")
    func onlyPlannedPaths() async throws {
        let mac = try UninstallScenario()
        _ = try chatGPT(mac)
        let precious = try mac.fixture.file("home/Documents/thesis.txt")
        let plan = try await mac.plan("ChatGPT")
        _ = await run(mac, plan, selection: plan.defaultSelection.union([precious, mac.fixture.home]), mode: .delete)
        #expect(mac.fixture.exists(precious))
        #expect(!mac.fixture.backend.deleted.contains(precious))
    }

    @Test("An app opened after the plan was made stops the uninstall before anything is removed")
    func openedAfterPlanning() async throws {
        let mac = try UninstallScenario()
        let files = try chatGPT(mac)
        let plan = try await mac.plan("ChatGPT")
        mac.fixture.running.open("com.openai.chat", name: "ChatGPT")
        let report = await run(mac, plan)
        #expect(report.outcome == .refused)
        #expect(report.refusals == ["Quit ChatGPT first."])
        #expect(mac.fixture.exists(files.bundle))
        #expect(mac.fixture.backend.trashed.isEmpty)
        let entry = try #require(try history(mac).first)
        #expect(entry.outcome == .skipped)
        #expect(entry.headline.text == "Not uninstalled")
        #expect(entry.skipReason == "Quit ChatGPT first.")
    }

    @Test("Quitting the app after reading the plan is enough; the plan's own note is not what decides")
    func quitAfterPlanning() async throws {
        let mac = try UninstallScenario()
        _ = try chatGPT(mac)
        mac.fixture.running.open("com.openai.chat", name: "ChatGPT")
        let plan = try await mac.plan("ChatGPT")
        #expect(!plan.canRun)
        mac.fixture.running.quitAll()
        // The planner is asked again, as the sheet's Check Again and the CLI do.
        let again = try await mac.plan("ChatGPT")
        #expect(again.canRun)
        #expect(await run(mac, again).outcome == .uninstalled)
    }

    @Test("A scheduled or unattended run can never uninstall anything")
    func neverUnattended() async throws {
        let mac = try UninstallScenario()
        let files = try chatGPT(mac)
        let plan = try await mac.plan("ChatGPT")
        for options in [UninstallOptions(origin: .scheduled), UninstallOptions(origin: .cli, intent: .unattended)] {
            let report = await run(mac, plan, options: options)
            #expect(report.outcome == .refused)
            #expect(report.refusals.first?.contains("never uninstalls anything on a schedule") == true)
        }
        #expect(mac.fixture.exists(files.bundle))
    }

    @Test("A configuration that stopped being readable after planning stops the uninstall")
    func configurationBrokeAfterPlanning() async throws {
        let mac = try UninstallScenario()
        let files = try chatGPT(mac)
        let plan = try await mac.plan("ChatGPT")
        try mac.fixture.file("home/.config/macup/config.json", "{not json")
        let report = await UninstallEngine(configurationStore: ConfigurationStore(paths: mac.fixture.paths)).run(
            plan,
            selection: plan.defaultSelection,
            mode: .trash,
            options: UninstallOptions(origin: .cli),
            configuration: mac.configuration,
            environment: mac.checkEnvironment,
            uninstall: mac.fixture.environment()
        )
        #expect(report.outcome == .refused)
        #expect(mac.fixture.exists(files.bundle))
    }

    @Test("A formula: the service stops, Homebrew removes it with automatic removal and sudo switched off, and data stays")
    func formula() async throws {
        let mac = try UninstallScenario()
        let services = #"[{"name": "mysql", "status": "started", "user": "example", "file": "/x", "exit_code": null}]"#
        try mac.withHomebrew(info: try Fixture.text("homebrew/info-installed-uninstall.json"), services: services)
        mac.dependents(of: "mysql")
        let data = try mac.fixture.folder("homebrew/var/mysql")
        mac.runner.register("brew", ["services", "stop", "mysql"], .success("Stopping `mysql`...\n"))
        mac.runner.register("brew", ["uninstall", "--formula", "--force", "mysql"], .success("Uninstalling mysql...\n"))
        mac.runner.onRun("brew", ["uninstall", "--formula", "--force", "mysql"]) { [runner = mac.runner] in
            let info = try! Fixture.text("homebrew/info-installed-uninstall.json")
                .replacingOccurrences(of: "\"name\": \"mysql\"", with: "\"name\": \"mysql-gone\"")
                .replacingOccurrences(of: "\"full_name\": \"mysql\"", with: "\"full_name\": \"mysql-gone\"")
            runner.register("brew", ["info", "--json=v2", "--installed"], .success(info))
        }

        let plan = try await mac.plan("brew:mysql")
        let report = await run(mac, plan)
        #expect(report.outcome == .uninstalled, "\(report.refusals) \(report.checks)")
        #expect(mac.modifyingRequests.map(\.arguments) == [
            ["services", "stop", "mysql"],
            ["uninstall", "--formula", "--force", "mysql"],
        ])
        let uninstall = try #require(mac.runner.recordedRequests.first { $0.arguments.first == "uninstall" })
        #expect(uninstall.environment["HOMEBREW_NO_AUTOREMOVE"] == "1")
        #expect(uninstall.environment["HOMEBREW_NO_SUDO"] == "1")
        #expect(uninstall.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(uninstall.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(mac.fixture.exists(data))
        #expect(report.checks.contains { $0.summary == "Homebrew no longer lists mysql" && $0.passed == true })

        let entry = try #require(try history(mac).first)
        #expect(entry.item?.rawValue == "brew:mysql")
        #expect(entry.headline.text == "Uninstalled mysql; its data folder was kept")
        #expect(entry.headline.kind == .uninstalled)
        #expect(entry.command?.contains("uninstall --formula --force mysql") == true)
        #expect(entry.uninstall?.kept.map(\.path) == [data])
    }

    @Test("When the package manager's command fails, MacUp removes nothing else")
    func stepFailure() async throws {
        let mac = try UninstallScenario()
        mac.withNpm(packages: ["typescript": "5.9.2"])
        mac.runner.register("npm", ["uninstall", "-g", "typescript"], .exit(1, standardError: "npm error EACCES: permission denied"))
        let plan = try await mac.plan("npm:typescript")
        let report = await run(mac, plan)
        #expect(report.outcome == .failed)
        #expect(report.error?.message.contains("removed nothing else") == true)
        #expect(report.removals.isEmpty)
        let entry = try #require(try history(mac).first)
        #expect(entry.outcome == .failed)
        #expect(entry.headline.text == "Uninstall of typescript failed — MacUp removed nothing further")
    }

    @Test("A command that is not in the plan is refused by the guard, even when it has a reviewed shape")
    func onlyThePlansCommands() async throws {
        let mac = try UninstallScenario()
        mac.withNpm(packages: ["typescript": "5.9.2"])
        mac.runner.register("npm", ["uninstall", "-g", "left-pad"], .success())
        var plan = try await mac.plan("npm:typescript")
        // The steps the guard is given are the plan's; one swapped in after
        // review must match a step to run, so the step itself is what counts.
        let guarded = ExecutionGuard(base: mac.runner, steps: plan.steps, verification: [], modifyingRules: ModifyingCommandRules.uninstall)
        await #expect(throws: MacUpError.self) {
            _ = try await guarded.run(CommandRequest(
                executable: URL(fileURLWithPath: UninstallScenario.npm),
                arguments: ["uninstall", "-g", "left-pad"],
                effect: .modifying
            ))
        }
        // And the update rules never let an uninstall through.
        plan.steps[0].invocation.arguments = ["uninstall", "-g", "typescript"]
        let updating = ExecutionGuard(base: mac.runner, steps: plan.steps, verification: [], modifyingRules: ModifyingCommandRules.all)
        await #expect(throws: MacUpError.self) {
            _ = try await updating.run(CommandRequest(
                executable: URL(fileURLWithPath: UninstallScenario.npm),
                arguments: ["uninstall", "-g", "typescript"],
                effect: .modifying
            ))
        }
        #expect(mac.modifyingRequests.isEmpty)
    }

    @Test("A blocked plan runs nothing and removes nothing")
    func blockedPlans() async throws {
        let mac = try UninstallScenario()
        try mac.withHomebrew(info: try Fixture.text("homebrew/info-installed-uninstall.json"))
        mac.dependents(of: "lua", formulae: "neovim\n")
        let plan = try await mac.plan("brew:lua")
        let report = await run(mac, plan, selection: plan.everything, mode: .delete)
        #expect(report.outcome == .refused)
        #expect(mac.modifyingRequests.isEmpty)
        #expect(mac.fixture.backend.deleted.isEmpty)
    }

    @Test("Uninstalling MacUp turns off the schedule, deletes the Keychain item, records the uninstall, and removes the app last")
    func macUp() async throws {
        let mac = try UninstallScenario()
        let paths = mac.fixture.paths
        try mac.fixture.file("home/.config/macup/config.json", "{}")
        try mac.fixture.folder("home/.local/state/macup")
        try mac.fixture.file("home/Library/LaunchAgents/com.macup.check.plist")
        let app = try mac.fixture.app("MacUp", identifier: "dev.macup.MacUp")
        mac.fixture.keychain.saveLeftover()
        let launchctl = FakeCommandRunner()
        launchctl.register(path: Scheduler.launchctlPath, ["bootout", "gui/501/com.macup.check"], .success())
        let scheduler = Scheduler(
            paths: paths,
            executable: "/usr/local/bin/macup",
            userID: 501,
            fileSystem: FakeFileSystem().addExecutable(Scheduler.launchctlPath).addFile(paths.launchAgentsDirectory + "/com.macup.check.plist"),
            runner: launchctl
        )
        let uninstall = mac.fixture.environment(currentAppBundle: app)
        let plan = try await mac.plan("macup", environment: uninstall)
        let history = HistoryStore(paths: paths)
        let report = await UninstallEngine(history: history).run(
            plan,
            selection: plan.defaultSelection,
            mode: .trash,
            options: UninstallOptions(origin: .gui),
            configuration: mac.configuration,
            environment: mac.checkEnvironment,
            uninstall: uninstall,
            scheduler: scheduler
        )
        #expect(report.outcome == .uninstalled, "\(report.checks)")
        #expect(!mac.fixture.keychain.hasLeftoverItem())
        #expect(launchctl.recordedInvocations.map(\.arguments) == [["bootout", "gui/501/com.macup.check"]])
        #expect(mac.fixture.backend.trashed.last == app, "the app goes last")
        #expect(mac.fixture.backend.trashed.dropLast().last == paths.stateDirectory, "then its history, just before")
        // The record was written into the state folder before it went to the
        // Trash, and says what was removed after it.
        let trashedState = try #require(report.removals.first { $0.path == paths.stateDirectory }?.trashedTo)
        let entries = try HistoryStore(fileURL: URL(fileURLWithPath: trashedState + "/history.jsonl")).load()
        let entry = try #require(entries.first)
        #expect(entry.item == nil)
        #expect(entry.subjectID == "macup")
        #expect(entry.uninstall?.removedAfterRecord == [paths.stateDirectory, app])
        #expect(entry.headline.text.hasPrefix("Uninstalled MacUp · "))
    }
}

/// What history says about an uninstall, and that it keeps reading what
/// older versions wrote.
@Suite("Uninstall: history")
struct UninstallHistoryTests {
    private static func entry(
        _ outcome: ExecutionResult.Outcome,
        verification: VerificationResult.Outcome? = .verified,
        removed: Int,
        keptData: Int = 0,
        mode: RemovalMode = .trash,
        name: String = "ChatGPT",
        item: PackageID? = nil
    ) -> HistoryEntry {
        var entry = HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_790_000_000),
            origin: .gui,
            item: item,
            versionBefore: "1.2025.1",
            versionTarget: nil,
            versionAfter: nil,
            command: nil,
            outcome: outcome,
            verification: verification
        )
        entry.uninstall = UninstallRecord(
            target: item?.rawValue ?? "app:com.openai.chat",
            name: name,
            kind: item == nil ? .app : .formula,
            mode: mode,
            removed: (0..<removed).map { UninstallRecord.RecordedPath(path: "/x/\($0)", category: .belongsToApp) },
            kept: (0..<keptData).map { UninstallRecord.RecordedPath(path: "/data/\($0)", category: .appData) }
        )
        return entry
    }

    @Test("Headlines say what was removed, how, and what was kept")
    func headlines() throws {
        let mysql = try PackageID(parsing: "brew:mysql")
        #expect(Self.entry(.succeeded, removed: 7).headline.text == "Uninstalled ChatGPT · 7 items moved to the Trash")
        #expect(Self.entry(.succeeded, removed: 1, mode: .delete).headline.text == "Uninstalled ChatGPT · 1 item deleted permanently")
        #expect(Self.entry(.succeeded, removed: 0, keptData: 1, name: "mysql", item: mysql).headline.text == "Uninstalled mysql; its data folder was kept")
        #expect(Self.entry(.succeeded, removed: 2, keptData: 3).headline.text == "Uninstalled ChatGPT · 2 items moved to the Trash; its 3 data folders were kept")
        #expect(Self.entry(.succeeded, verification: .failed, removed: 2).headline.kind == .unconfirmed)
        #expect(Self.entry(.failed, removed: 0).headline.text == "Uninstall of ChatGPT failed — MacUp removed nothing further")
        #expect(Self.entry(.failed, removed: 3).headline.text == "Uninstall of ChatGPT did not finish — 3 items moved to the Trash")
        #expect(Self.entry(.skipped, removed: 0).headline.text == "Not uninstalled")
        #expect(Self.entry(.cancelled, removed: 0).headline.kind == .stopped)
        let done = Self.entry(.succeeded, removed: 7).headline
        #expect(done.tone == .good)
        #expect(done.symbolName == "trash.circle")
    }

    @Test("An uninstall is written and read back whole, and old lines still decode beside it")
    func roundTrip() throws {
        let directory = try TemporaryDirectory(prefix: "macup-uninstall-history")
        let store = HistoryStore(fileURL: directory.appending("history.jsonl"))
        let old = try Fixture.data("history/before-read-back.jsonl")
        try old.write(to: directory.appending("history.jsonl"))
        let written = Self.entry(.succeeded, removed: 7, keptData: 1)
        try store.append(written)

        let reading = try store.read()
        #expect(reading.unreadableLines == 0)
        let first = try #require(reading.entries.first)
        #expect(first.uninstall == written.uninstall)
        #expect(first.item == nil)
        #expect(first.subjectID == "app:com.openai.chat")
        #expect(first.subjectName == "ChatGPT")
        #expect(first.versionSummary == "1.2025.1 → removed")
        #expect(first.circumstances.first == "by MacUp")
        #expect(reading.entries.dropFirst().allSatisfy { $0.uninstall == nil && $0.item != nil })
        #expect(HistoryFilter(search: "chatgpt uninstalled").includes(first))
        #expect(!HistoryFilter(items: [try PackageID(parsing: "brew:mysql")]).includes(first))
    }
}
