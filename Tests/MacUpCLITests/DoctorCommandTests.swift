import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup doctor")
struct DoctorCommandTests {
    /// A Mac where the login shell cannot be read, which is one of the
    /// conditions Doctor warns about.
    private func withUnreadableShell(_ harness: CLIHarness) {
        harness.doctorEngine = DoctorEngine(
            providers: DoctorEngine.standard().providers,
            checks: DoctorEngine.standard().checks
        )
    }

    @Test("Doctor says what it observed, what to do, and that it changed nothing")
    func explainsWithoutFixing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        withUnreadableShell(harness)

        let run = try await harness.run(["doctor"])
        #expect(run.standardOutput.contains("MacUp doctor"))
        #expect(run.standardOutput.contains("nothing was changed"))
        #expect(run.standardOutput.contains("warning MacUp could not read your login shell's environment"))
        #expect(run.standardOutput.contains("Each finding above says what MacUp observed and what you can do."))
    }

    @Test("A warning is something that needs attention, so Doctor exits 5")
    func warningExitsFive() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        withUnreadableShell(harness)

        let run = try await harness.run(["doctor"])
        #expect(run.exitCode == MacUpExitCode.attentionRequired.rawValue)
    }

    @Test("A Mac with only notes needs no attention, so Doctor exits 0")
    func notesAloneExitZero() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)

        let run = try await harness.run(["doctor"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Nothing needs attention."))
        #expect(run.standardOutput.contains("2 notes"))
        #expect(run.standardOutput.contains("macup doctor --verbose"))
    }

    @Test("Notes are shown with --verbose, along with each provider MacUp found")
    func verboseShowsNotesAndProviders() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)

        let run = try await harness.run(["doctor", "--verbose"])
        #expect(run.standardOutput.contains("note    npm is not installed"))
        #expect(run.standardOutput.contains("Homebrew  found      /opt/homebrew/bin/brew"))
    }

    @Test("Findings come most severe first")
    func mostSevereFirst() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        withUnreadableShell(harness)

        let run = try await harness.run(["doctor", "--verbose"])
        let warning = try #require(run.standardOutput.range(of: "warning "))
        let note = try #require(run.standardOutput.range(of: "note    "))
        #expect(warning.lowerBound < note.lowerBound)
    }

    @Test("Doctor runs nothing that changes the machine")
    func runsNoModifyingCommand() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)

        _ = try await harness.run(["doctor"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(harness.schedulerRunner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("doctor --json is a DoctorReport that decodes back, with its schema version")
    func jsonDecodesAsDoctorReport() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        withUnreadableShell(harness)

        let run = try await harness.run(["doctor", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == DoctorReport.schemaVersion)
        #expect(object["kind"] as? String == "doctor")

        let report = try JSONDecoder.plan.decode(DoctorReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.summary.checksRun == 11)
        #expect(report.summary.warnings >= 1)
        #expect(!report.isHealthy)
        #expect(report.findings.contains { $0.id == "environment.loginShellUnreadable" })
        #expect(report.providers.contains { $0.provider == .homebrew && $0.availability == .available })
    }

    @Test("A provider MacUp cannot find is a note, not an alarm")
    func missingProviderIsANote() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)

        let run = try await harness.run(["doctor", "--json"])
        let report = try JSONDecoder.plan.decode(DoctorReport.self, from: Data(run.standardOutput.utf8))
        let npm = try #require(report.findings.first { $0.provider == .npm })
        #expect(npm.severity == .info)
        #expect(npm.recommendation?.contains("Nothing is wrong if you do not use npm") == true)
    }

    @Test("Doctor output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        withUnreadableShell(harness)

        let run = try await harness.run(["doctor", "--verbose"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }
}
