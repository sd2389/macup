import ArgumentParser
import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

@Suite("macup security")
struct SecurityCommandTests {
    @Test("status reports the Mac's own sensor and whether MacUp asks")
    func status() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["security"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Approval · not required"))
        #expect(run.standardOutput.contains("This Mac: Touch ID, ready"))
        #expect(run.standardOutput.contains("not a lock"))

        harness.authorizer.set(
            capability: BiometricCapability(
                kind: .faceID,
                isAvailable: true,
                hasFallback: true
            )
        )
        let faceID = try await harness.run(["security", "status"])
        #expect(faceID.standardOutput.contains("This Mac: Face ID, ready"))
    }

    @Test("status --json is versioned and machine-readable")
    func statusJSON() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let run = try await harness.run(["security", "status", "--json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "security")
        #expect(object["requireApproval"] as? Bool == false)
        #expect(object["biometry"] as? String == "touchID")
        #expect(object["biometryDisplayName"] as? String == "Touch ID")
        #expect(object["biometricsAvailable"] as? Bool == true)
    }

    @Test("Turning approval on records it")
    func requireOn() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["security", "require", "on"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("ask for Touch ID"))

        let security = try #require(try harness.readConfig()["security"] as? [String: Any])
        #expect(security["requireApproval"] as? Bool == true)
    }

    @Test("Turning approval off needs the approval that is in force now")
    func requireOffIsItselfGated() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)

        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        let refused = try await harness.run(["security", "require", "off"])
        #expect(refused.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(refused.standardError.contains("You cancelled"))
        #expect(refused.standardError.contains("Nothing was changed."))
        let unchanged = try #require(try harness.readConfig()["security"] as? [String: Any])
        #expect(unchanged["requireApproval"] as? Bool == true)

        harness.authorizer.set(outcome: .approved(.touchID))
        let allowed = try await harness.run(["security", "require", "off"])
        #expect(allowed.exitCode == nil)
        let changed = try #require(try harness.readConfig()["security"] as? [String: Any])
        #expect(changed["requireApproval"] as? Bool == false)
    }

    @Test("MacUp refuses to require an approval this Mac could never give")
    func refusesToLockTheUserOut() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.authorizer.set(capability: .unavailable)

        let run = try await harness.run(["security", "require", "on"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(run.standardError.contains("cannot ask you to confirm"))
        #expect(!FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path))
    }

    @Test("A declined approval stops the schedule changing, and installs nothing")
    func scheduleIsGated() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        let refused = try await harness.run(["schedule", "enable", "--time", "09:00"])
        #expect(refused.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(refused.standardError.contains("Nothing was changed."))
        #expect(!FileManager.default.fileExists(atPath: harness.agentPath))
        #expect(harness.schedulerRunner.recordedInvocations.isEmpty)

        harness.authorizer.set(outcome: .approved(.touchID))
        let allowed = try await harness.run(["schedule", "enable", "--time", "09:00"])
        #expect(allowed.exitCode == nil)
        #expect(FileManager.default.fileExists(atPath: harness.agentPath))
        #expect(harness.authorizer.requestedReasons.contains("change MacUp's scheduled run"))
    }

    @Test("Turning the schedule off is gated too")
    func disableIsGated() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl()
        _ = try await harness.run(["schedule", "enable"])
        try harness.writeConfig(#"{"schemaVersion": 1, "schedule": {"enabled": true}, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        let run = try await harness.run(["schedule", "disable"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(FileManager.default.fileExists(atPath: harness.agentPath))
        #expect(harness.authorizer.requestedReasons.contains("turn off MacUp's scheduled check"))
    }
}
