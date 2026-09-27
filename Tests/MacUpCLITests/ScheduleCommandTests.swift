import ArgumentParser
import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup schedule")
struct ScheduleCommandTests {
    private func installedPropertyList(_ harness: CLIHarness) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: harness.agentPath))
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("With nothing installed, status says so and how to turn it on")
    func statusWhenOff() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)

        let run = try await harness.run(["schedule"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Scheduled check · off"))
        #expect(run.standardOutput.contains("macup schedule enable"))
        #expect(run.standardOutput.contains("MacUp updates nothing on a schedule."))
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))
    }

    @Test("Enabling installs the agent and records the schedule")
    func enableInstalls() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()

        let run = try await harness.run(["schedule", "enable", "--time", "09:30"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("every day at 09:30"))
        #expect(run.standardOutput.contains("check --save-state --refresh"))
        #expect(run.standardOutput.contains("read-only"))

        let plist = try installedPropertyList(harness)
        #expect(plist["Label"] as? String == "com.macup.check")
        let interval = try #require(plist["StartCalendarInterval"] as? [String: Any])
        #expect(interval["Hour"] as? Int == 9)
        #expect(interval["Minute"] as? Int == 30)
        #expect(plist["ProgramArguments"] as? [String] == [harness.executablePath, "check", "--save-state", "--refresh"])

        let schedule = try #require(try harness.readConfig()["schedule"] as? [String: Any])
        #expect(schedule["enabled"] as? Bool == true)
        #expect(schedule["time"] as? String == "09:30")
    }

    @Test("A weekly schedule without a metadata refresh is installed as asked")
    func enableWeeklyWithoutRefresh() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()

        let run = try await harness.run([
            "schedule", "enable", "--frequency", "weekly", "--weekday", "wednesday", "--no-refresh",
        ])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("every Wednesday at 23:00"))

        let plist = try installedPropertyList(harness)
        let interval = try #require(plist["StartCalendarInterval"] as? [String: Any])
        #expect(interval["Weekday"] as? Int == 3)
        #expect(plist["ProgramArguments"] as? [String] == [harness.executablePath, "check", "--save-state"])
    }

    @Test("A time MacUp cannot read is a usage error, and installs nothing")
    func rejectsBadTime() {
        do {
            _ = try MacUpCommand.parseAsRoot(["schedule", "enable", "--time", "25:00"])
            Issue.record("expected a validation error")
        } catch {
            #expect(MacUpCommand.exitCode(for: error).rawValue == MacUpExitCode.usage.rawValue)
            #expect(MacUpCommand.message(for: error).contains("24-hour HH:mm"))
        }
    }

    @Test("MacUp will not schedule against a configuration it cannot read")
    func refusesInvalidConfiguration() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebew": {}}}"#)

        let run = try await harness.run(["schedule", "enable"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("will not change a configuration it cannot read"))
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))
        #expect(harness.schedulerRunner.recordedInvocations.isEmpty)
    }

    @Test("Disabling removes the agent and clears the setting")
    func disableRemoves() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()
        _ = try await harness.run(["schedule", "enable"])
        #expect(FileManager.default.fileExists(atPath: harness.agentPath))

        let run = try await harness.run(["schedule", "disable"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Nothing runs automatically."))
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))

        let schedule = try #require(try harness.readConfig()["schedule"] as? [String: Any])
        #expect(schedule["enabled"] as? Bool == false)
    }

    @Test("Disabling when nothing is scheduled says so and changes nothing")
    func disableWhenNothingInstalled() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.schedulerRunner.register(
            path: Scheduler.launchctlPath,
            ["bootout", harness.serviceTarget],
            .exit(3, standardError: "Boot-out failed: 3: No such process\n")
        )
        let run = try await harness.run(["schedule", "disable"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("No scheduled check was installed."))
    }

    @Test("status --json is versioned and machine-readable")
    func statusJSON() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()
        _ = try await harness.run(["schedule", "enable", "--time", "23:00"])

        let run = try await harness.run(["schedule", "status", "--json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "schedule")
        #expect(object["enabledInConfiguration"] as? Bool == true)
        #expect(object["agentInstalled"] as? Bool == true)
        #expect(object["agentLoaded"] as? Bool == true)
        #expect(object["label"] as? String == "com.macup.check")
        #expect(object["refreshesMetadata"] as? Bool == true)
        #expect((object["warnings"] as? [Any])?.isEmpty == true)
    }

    @Test("check --save-state leaves the report where a scheduled run would")
    func checkSavesState() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["check", "--save-state"])
        #expect(run.exitCode == nil)

        let path = harness.stateDirectory.path + "/" + MacUpPaths.lastCheckFileName
        let saved = try #require(
            JSONSerialization.jsonObject(with: try Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
        )
        #expect(saved["kind"] as? String == "check")
        #expect(saved["mode"] as? String == "readOnly")
        let summary = try #require(saved["summary"] as? [String: Any])
        #expect(summary["updatesAvailable"] as? Int == 3)

        // The saved report is what `schedule status` then reports back.
        harness.expectLaunchctl(loaded: false)
        let status = try await harness.run(["schedule", "status"])
        #expect(status.standardOutput.contains("Last check:"))
        #expect(status.standardOutput.contains("3 updates found"))
    }
}
