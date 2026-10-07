import Foundation
import MacUpCore
import Testing

@testable import macup

/// `macup update --scheduled`: what the launchd agent runs when installing is
/// turned on (ADR-023). Nobody is watching, so only Auto Update items may run.
@Suite("macup update --scheduled")
struct ScheduledUpdateCommandTests {
    /// Homebrew with git and mysql outdated, and git allowed to upgrade.
    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")
        return harness
    }

    @Test("It installs the Auto Update items and leaves everything else alone")
    func installsOnlyAutoItems() async throws {
        let harness = try harness()
        _ = try await harness.run(["policy", "set", "brew:git", "auto"])
        _ = try await harness.run(["policy", "set", "brew:mysql", "ask"])

        let run = try await harness.run(["update", "--scheduled"])

        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.map(\.displayString) == ["/opt/homebrew/bin/brew upgrade --formula --yes git"])
        // mysql is Ask First, and the harness also has a macOS update, which
        // is always Ask First.
        #expect(run.standardOutput.contains("2 updates need your word"), "what was left alone is named, not run")

        let history = try harness.historyStore.load()
        #expect(history.contains { $0.item?.rawValue == "brew:git" && $0.origin == .scheduled && $0.outcome == .succeeded })
        #expect(history.contains { $0.item?.rawValue == "brew:mysql" && $0.outcome == .skipped })
    }

    @Test("With nothing set to Auto Update, a scheduled run changes nothing")
    func nothingAutomatic() async throws {
        let harness = try harness()
        let run = try await harness.run(["update", "--scheduled"])

        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("It saves the check where a scheduled check saves it, so the app can say what happened")
    func savesTheCheck() async throws {
        let harness = try harness()
        _ = try await harness.run(["policy", "set", "brew:git", "auto"])
        _ = try await harness.run(["update", "--scheduled"])

        let saved = harness.stateDirectory.appending(MacUpPaths.lastCheckFileName)
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test("It installs nothing while MacUp is set to ask the owner to approve every change")
    func refusesWhenApprovalIsRequired() async throws {
        let harness = try harness()
        _ = try await harness.run(["policy", "set", "brew:git", "auto"])
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)

        let run = try await harness.run(["update", "--scheduled"])

        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(run.standardError.contains("nobody to ask"))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("It takes no items, no --yes, and no --dry-run: a scheduled run is defined by your rules")
    func refusesArgumentsThatWouldWidenIt() async throws {
        let harness = try harness()
        #expect(try await harness.run(["update", "--scheduled", "brew:git"]).exitCode != nil)
        #expect(try await harness.run(["update", "--scheduled", "--yes"]).exitCode != nil)
        #expect(try await harness.run(["update", "--scheduled", "--dry-run"]).exitCode != nil)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("The agent runs the check unless installing is turned on, and nothing else can be added to it")
    func agentCommand() throws {
        let paths = MacUpPaths.standard(homeDirectory: "/Users/example")
        var settings = MacUpConfiguration.ScheduleSettings(enabled: true, time: "23:00", refresh: true)

        let check = try LaunchAgent.scheduledCheck(settings: settings, executable: "/usr/local/bin/macup", paths: paths)
        #expect(check.invocation.arguments == ["check", "--save-state", "--refresh"])

        settings.installsAutoUpdates = true
        let updates = try LaunchAgent.scheduledCheck(settings: settings, executable: "/usr/local/bin/macup", paths: paths)
        #expect(updates.invocation.arguments == ["update", "--scheduled", "--refresh"])
    }

    @Test("Installing on a schedule is off unless the configuration says otherwise")
    func offByDefault() throws {
        #expect(!MacUpConfiguration.ScheduleSettings().installsAutoUpdates)
        let decoded = try JSONDecoder().decode(
            MacUpConfiguration.ScheduleSettings.self,
            from: Data(#"{"enabled": true, "frequency": "daily", "time": "23:00"}"#.utf8)
        )
        #expect(!decoded.installsAutoUpdates, "a file that does not mention it never turns it on")
    }
}
