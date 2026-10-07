import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// Doctor's fixes, each over a throwaway configuration directory. Nothing
/// here runs a package manager, and launchctl is faked.
@Suite("Doctor fixes what belongs to MacUp")
struct DoctorFixerTests {
    @MainActor
    private final class Machine {
        let directory: TemporaryDirectory
        let agents: TemporaryDirectory
        let bin: TemporaryDirectory
        let launchctl = FakeCommandRunner()
        /// The real file system, so "installed" and "removed" mean the file
        /// is really there or really gone. Only launchctl is faked, so no
        /// test loads anything into this Mac's launchd.
        let fileSystem = LocalFileSystem()
        let executable: String
        let paths: MacUpPaths

        init() throws {
            directory = try TemporaryDirectory(prefix: "macup-fix-config")
            agents = try TemporaryDirectory(prefix: "macup-fix-agents")
            bin = try TemporaryDirectory(prefix: "macup-fix-bin")
            executable = try bin.makeScript("macup", "exit 0").path
            paths = MacUpPaths(
                configDirectory: directory.path,
                stateDirectory: directory.path,
                launchAgentsDirectory: agents.path
            )
        }

        var store: ConfigurationStore { ConfigurationStore(paths: paths) }

        var scheduler: Scheduler {
            Scheduler(
                paths: paths,
                executable: executable,
                userID: 501,
                fileSystem: fileSystem,
                runner: launchctl,
                processEnvironment: [:]
            )
        }

        var fixer: DoctorFixer {
            DoctorFixer(store: store, makeScheduler: { [scheduler] in scheduler })
        }

        func write(_ json: String) throws {
            try json.write(to: URL(fileURLWithPath: directory.path + "/config.json"), atomically: true, encoding: .utf8)
        }

        /// Answers the launchctl calls installing and removing an agent make.
        func expectLaunchctl() {
            let target = "gui/501/" + LaunchAgent.label
            launchctl.register(path: Scheduler.launchctlPath, ["bootout", target], .success())
            launchctl.register(path: Scheduler.launchctlPath, ["bootstrap", "gui/501", agents.path + "/" + LaunchAgent.fileName], .success())
            launchctl.register(path: Scheduler.launchctlPath, ["print", target], .success("state = running"))
        }
    }

    private func finding(_ id: String, _ fix: DiagnosticFix) -> DiagnosticFinding {
        DiagnosticFinding(id: id, severity: .warning, provider: nil, title: id, fix: fix)
    }

    @Test("A finding with no fix is not fixed, and says so")
    @MainActor
    func noFix() async throws {
        let machine = try Machine()
        let result = await machine.fixer.apply(
            DiagnosticFinding(id: "homebrew.multipleInstallations", severity: .warning, provider: nil, title: "Two")
        )
        #expect(!result.succeeded)
        #expect(result.problem?.contains("no fix") == true)
    }

    @Test("Stale item rules are dropped, and only the ones the finding named")
    @MainActor
    func clearsStaleRules() async throws {
        let machine = try Machine()
        try machine.write(#"""
            {"schemaVersion": 1, "items": {"brew:gone": {"policy": "ignore"}, "brew:here": {"policy": "auto"}}}
            """#)

        let result = await machine.fixer.apply(finding(
            "configuration.staleItemPolicy",
            DiagnosticFix(action: .clearItemRules(["brew:gone"]), summary: "Drop this rule", detail: "…")
        ))

        #expect(result.succeeded)
        #expect(result.changes.count == 1)
        let after = machine.store.load().configuration
        #expect(after.items["brew:gone"] == nil)
        #expect(after.items["brew:here"]?.policy == .auto, "the rule the finding did not name is untouched")
    }

    @Test("A rule that is already gone is not an error, and nothing is written")
    @MainActor
    func ruleAlreadyGone() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "items": {"brew:here": {"policy": "auto"}}}"#)

        let result = await machine.fixer.apply(finding(
            "configuration.staleItemPolicy",
            DiagnosticFix(action: .clearItemRules(["brew:gone"]), summary: "Drop this rule", detail: "…")
        ))

        #expect(!result.succeeded)
        #expect(result.problem?.contains("not in the configuration") == true)
        #expect(machine.store.load().configuration.items["brew:here"]?.policy == .auto)
    }

    @Test("A dry run says what it would change and changes nothing")
    @MainActor
    func dryRun() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "items": {"brew:gone": {"policy": "ignore"}}}"#)

        let result = await machine.fixer.apply(
            finding(
                "configuration.staleItemPolicy",
                DiagnosticFix(action: .clearItemRules(["brew:gone"]), summary: "Drop this rule", detail: "…")
            ),
            dryRun: true
        )

        #expect(result.succeeded)
        #expect(result.dryRun)
        #expect(result.changes == ["Would remove the rule for brew:gone."])
        #expect(machine.store.load().configuration.items["brew:gone"] != nil)
    }

    @Test("A configured path that cannot be used is forgotten, and the tool itself is untouched")
    @MainActor
    func clearsProviderPath() async throws {
        let machine = try Machine()
        try machine.write(#"""
            {"schemaVersion": 1, "providers": {"homebrew": {"enabled": true, "executablePath": "/nope/brew"}}}
            """#)

        let result = await machine.fixer.apply(finding(
            "provider.configuredPathUnusable",
            DiagnosticFix(action: .clearProviderPath(.homebrew), summary: "Forget it", detail: "…")
        ))

        #expect(result.succeeded)
        #expect(machine.store.load().configuration.settings(for: .homebrew).executablePath == nil)
        #expect(machine.store.load().configuration.settings(for: .homebrew).enabled, "nothing else changed")
    }

    @Test("The scheduled run is installed when the configuration asks for one")
    @MainActor
    func installsAgent() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "schedule": {"enabled": true, "time": "23:00"}}"#)
        machine.expectLaunchctl()

        let result = await machine.fixer.apply(finding(
            "schedule.notInstalled",
            DiagnosticFix(action: .installScheduleAgent, summary: "Install it", detail: "…")
        ))

        #expect(result.succeeded)
        #expect(FileManager.default.fileExists(atPath: machine.agents.path + "/" + LaunchAgent.fileName))
        #expect(result.changes.contains { $0.contains("check --save-state") })
    }

    @Test("It will not install a schedule the configuration has since turned off")
    @MainActor
    func refusesToInstallWhatIsNotAskedFor() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "schedule": {"enabled": false}}"#)

        let result = await machine.fixer.apply(finding(
            "schedule.notInstalled",
            DiagnosticFix(action: .installScheduleAgent, summary: "Install it", detail: "…")
        ))

        #expect(!result.succeeded)
        #expect(result.problem?.contains("no longer asks") == true)
        #expect(!FileManager.default.fileExists(atPath: machine.agents.path + "/" + LaunchAgent.fileName))
    }

    @Test("An agent left behind by a schedule that is off is removed")
    @MainActor
    func removesAgent() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "schedule": {"enabled": false}}"#)
        machine.expectLaunchctl()
        let agentPath = machine.agents.path + "/" + LaunchAgent.fileName
        try "x".write(to: URL(fileURLWithPath: agentPath), atomically: true, encoding: .utf8)

        let result = await machine.fixer.apply(finding(
            "schedule.installedWhileDisabled",
            DiagnosticFix(action: .removeScheduleAgent, summary: "Remove it", detail: "…")
        ))

        #expect(result.succeeded)
        #expect(!FileManager.default.fileExists(atPath: machine.agents.path + "/" + LaunchAgent.fileName))
    }

    @Test("Nothing is fixed while the configuration cannot be read")
    @MainActor
    func refusesBrokenConfiguration() async throws {
        let machine = try Machine()
        try machine.write(#"{"schemaVersion": 1, "global": {"defaultPolicy": "sometimes"}}"#)

        let result = await machine.fixer.apply(finding(
            "configuration.staleItemPolicy",
            DiagnosticFix(action: .clearItemRules(["brew:gone"]), summary: "Drop this rule", detail: "…")
        ))

        #expect(!result.succeeded)
        #expect(result.problem?.contains("cannot read") == true)
    }
}
