import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Scheduler")
struct SchedulerTests {
    typealias Settings = MacUpConfiguration.ScheduleSettings

    /// A scheduler pointed at temporary directories, with a fake `launchctl`.
    /// Files are written for real; no agent is ever loaded.
    struct Harness {
        let state: TemporaryDirectory
        let agents: TemporaryDirectory
        let bin: TemporaryDirectory
        let runner = FakeCommandRunner()
        let scheduler: Scheduler
        let executable: String

        init(userID: uid_t = 501, executableExists: Bool = true) throws {
            state = try TemporaryDirectory(prefix: "macup-state")
            agents = try TemporaryDirectory(prefix: "macup-agents")
            bin = try TemporaryDirectory(prefix: "macup-bin")
            executable = executableExists
                ? try bin.makeScript("macup", "exit 0").path
                : bin.appending("macup").path
            scheduler = Scheduler(
                paths: MacUpPaths(
                    configDirectory: state.path,
                    stateDirectory: state.path,
                    launchAgentsDirectory: agents.path
                ),
                executable: executable,
                userID: userID,
                fileSystem: LocalFileSystem(),
                runner: runner,
                processEnvironment: ["PATH": "/usr/bin:/bin"]
            )
        }

        var agentPath: String { agents.path + "/" + LaunchAgent.fileName }
        var serviceTarget: String { "gui/501/com.macup.check" }

        func answerLaunchctl(bootstrap: FakeCommandRunner.Response = .success(), loaded: Bool = true) {
            runner.register(path: Scheduler.launchctlPath, ["bootout", serviceTarget], .success())
            runner.register(path: Scheduler.launchctlPath, ["bootstrap", "gui/501", agentPath], bootstrap)
            runner.register(
                path: Scheduler.launchctlPath,
                ["print", serviceTarget],
                loaded ? .success() : .exit(113, standardError: "Could not find service")
            )
        }
    }

    @Test("Installing writes the agent and loads it, replacing any earlier one")
    func installsAndLoads() async throws {
        let harness = try Harness()
        harness.answerLaunchctl()
        let agent = try await harness.scheduler.install(Settings(enabled: true, time: "23:00"))

        #expect(FileManager.default.fileExists(atPath: harness.agentPath))
        let mode = try FileManager.default.attributesOfItem(atPath: harness.agentPath)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        let arguments = harness.runner.recordedInvocations.map(\.arguments)
        #expect(arguments == [
            ["bootout", harness.serviceTarget],
            ["bootstrap", "gui/501", harness.agentPath],
        ])
        for invocation in harness.runner.recordedInvocations {
            #expect(invocation.executable == "/bin/launchctl")
        }

        let installed = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: URL(fileURLWithPath: harness.agentPath)),
            format: nil
        ) as? [String: Any]
        #expect(agent.matches(installedPropertyList: try #require(installed)))
    }

    @Test("A command that is not there is never scheduled")
    func refusesMissingExecutable() async throws {
        let harness = try Harness(executableExists: false)
        harness.answerLaunchctl()
        await #expect(throws: MacUpError.self) {
            try await harness.scheduler.install(Settings(enabled: true))
        }
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))
        #expect(harness.runner.recordedInvocations.isEmpty)
    }

    @Test("launchd refusing to load is reported, with what it said")
    func reportsBootstrapFailure() async throws {
        let harness = try Harness()
        harness.answerLaunchctl(bootstrap: .exit(5, standardError: "Load failed: 5: Input/output error\n"))
        await #expect(throws: MacUpError.self) {
            try await harness.scheduler.install(Settings(enabled: true))
        }
        do {
            try await harness.scheduler.install(Settings(enabled: true))
        } catch let error as MacUpError {
            #expect(error.message.contains("Load failed: 5: Input/output error"))
            #expect(error.kind == .commandFailed)
        }
    }

    @Test("Disabling unloads the job and deletes the agent")
    func removesEverything() async throws {
        let harness = try Harness()
        harness.answerLaunchctl()
        try await harness.scheduler.install(Settings(enabled: true))
        #expect(FileManager.default.fileExists(atPath: harness.agentPath))

        let removed = try await harness.scheduler.remove()
        #expect(removed)
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))
    }

    @Test("Disabling when nothing is installed removes nothing and says so")
    func removeIsIdempotent() async throws {
        let harness = try Harness()
        harness.runner.register(
            path: Scheduler.launchctlPath,
            ["bootout", harness.serviceTarget],
            .exit(3, standardError: "Boot-out failed: 3: No such process\n")
        )
        #expect(try await harness.scheduler.remove() == false)
    }

    @Test("Status reports an installed, loaded agent as on")
    func statusWhenActive() async throws {
        let harness = try Harness()
        harness.answerLaunchctl()
        let settings = Settings(enabled: true, time: "23:00")
        try await harness.scheduler.install(settings)

        let status = await harness.scheduler.status(settings)
        #expect(status.isActive)
        #expect(status.agentInstalled)
        #expect(status.agentLoaded == true)
        #expect(status.agentMatchesConfiguration == true)
        #expect(status.schedule == "every day at 23:00")
        #expect(status.command.hasSuffix("check --save-state --refresh"))
        #expect(status.warnings.isEmpty)
    }

    @Test("A schedule turned on with no agent installed is reported, not assumed to work")
    func statusWhenConfiguredButNotInstalled() async throws {
        let harness = try Harness()
        harness.answerLaunchctl(loaded: false)
        let status = await harness.scheduler.status(Settings(enabled: true))
        #expect(!status.isActive)
        #expect(!status.agentInstalled)
        #expect(status.warnings.contains { $0.contains("no agent is installed") })
    }

    @Test("An agent that no longer matches the configuration is reported")
    func statusWhenAgentIsStale() async throws {
        let harness = try Harness()
        harness.answerLaunchctl()
        try await harness.scheduler.install(Settings(enabled: true, time: "23:00"))

        let status = await harness.scheduler.status(Settings(enabled: true, time: "07:30"))
        #expect(status.agentMatchesConfiguration == false)
        #expect(status.warnings.contains { $0.contains("does not match the configuration") })
    }

    @Test("An agent whose command has been removed is reported")
    func statusWhenExecutableDisappears() async throws {
        let harness = try Harness()
        harness.answerLaunchctl()
        try await harness.scheduler.install(Settings(enabled: true))
        try FileManager.default.removeItem(atPath: harness.executable)

        let status = await harness.scheduler.status(Settings(enabled: true))
        #expect(!status.executableExists)
        #expect(status.warnings.contains { $0.contains("no longer exists") })
    }

    @Test("The last saved check is summarised, and an unreadable one is not guessed at")
    func readsLastCheck() async throws {
        let harness = try Harness()
        let report = """
            {"schemaVersion": 1, "kind": "check", "finishedAt": "2026-09-25T23:00:12Z",
             "summary": {"updatesAvailable": 4, "providersWithErrors": 1}}
            """
        let path = harness.state.path + "/" + MacUpPaths.lastCheckFileName
        try report.write(toFile: path, atomically: true, encoding: .utf8)

        let last = try #require(harness.scheduler.readLastCheck())
        #expect(last.updatesAvailable == 4)
        #expect(last.providersWithErrors == 1)
        #expect(last.finishedAt != nil)
        #expect(!last.unreadable)

        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(harness.scheduler.readLastCheck()?.unreadable == true)

        try FileManager.default.removeItem(atPath: path)
        #expect(harness.scheduler.readLastCheck() == nil)
    }
}
