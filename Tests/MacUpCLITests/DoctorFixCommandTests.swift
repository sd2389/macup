import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup doctor --fix")
struct DoctorFixCommandTests {
    /// A Mac whose configuration has a rule for something that is not
    /// installed, which is one of the findings that carries a fix.
    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = true
        harness.answers = ["y"]
        try harness.writeConfig(#"""
            {"schemaVersion": 1, "items": {"brew:not-installed": {"policy": "ignore"}}}
            """#)
        return harness
    }

    @Test("Doctor on its own still changes nothing, and names the fix a finding offers")
    func listsTheFix() async throws {
        let harness = try harness()
        let run = try await harness.run(["doctor", "--verbose"])

        #expect(run.exitCode == nil || run.exitCode == MacUpExitCode.attentionRequired.rawValue)
        #expect(run.standardOutput.contains("configuration.staleItemPolicy"))
        #expect(try harness.readConfig()["items"] != nil, "nothing was changed")
    }

    @Test("--fix shows what it will change, asks, and then changes it")
    func appliesTheFix() async throws {
        let harness = try harness()
        let run = try await harness.run(["doctor", "--fix", "configuration.staleItemPolicy"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("What these fixes change"))
        #expect(run.standardOutput.contains("brew:not-installed"))
        let items = try harness.readConfig()["items"] as? [String: Any]
        #expect(items?["brew:not-installed"] == nil)
        #expect(harness.modifyingRequests.isEmpty, "a fix never runs a package manager")
    }

    @Test("--fix --dry-run changes nothing")
    func dryRun() async throws {
        let harness = try harness()
        let run = try await harness.run(["doctor", "--fix", "configuration.staleItemPolicy", "--dry-run"])

        #expect(run.standardOutput.contains("Would remove the rule"))
        #expect(run.standardOutput.contains("Nothing was changed."))
        let items = try harness.readConfig()["items"] as? [String: Any]
        #expect(items?["brew:not-installed"] != nil)
    }

    @Test("Answering no changes nothing")
    func refused() async throws {
        let harness = try harness()
        harness.answers = ["n"]
        let run = try await harness.run(["doctor", "--fix", "configuration.staleItemPolicy"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Nothing was changed."))
        let items = try harness.readConfig()["items"] as? [String: Any]
        #expect(items?["brew:not-installed"] != nil)
    }

    @Test("Without a terminal it will not fix anything unless --yes says so")
    func needsATerminalOrYes() async throws {
        let harness = try harness()
        harness.isTerminal = false
        harness.answers = []

        let asked = try await harness.run(["doctor", "--fix", "configuration.staleItemPolicy"])
        #expect(asked.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect((try harness.readConfig()["items"] as? [String: Any])?["brew:not-installed"] != nil)

        let confirmed = try await harness.run(["doctor", "--fix", "configuration.staleItemPolicy", "--yes"])
        #expect(confirmed.exitCode == nil)
        #expect((try harness.readConfig()["items"] as? [String: Any])?["brew:not-installed"] == nil)
    }

    @Test("A finding that does not exist, or has no fix, is refused before anything happens")
    func unknownFinding() async throws {
        let harness = try harness()

        let unknown = try await harness.run(["doctor", "--fix", "nothing.like.this"])
        #expect(unknown.exitCode == MacUpExitCode.usage.rawValue)
        #expect(unknown.standardError.contains("found nothing with the id"))

        let noFix = try await harness.run(["doctor", "--fix", "provider.notFound"])
        #expect(noFix.exitCode == MacUpExitCode.usage.rawValue)
        #expect(noFix.standardError.contains("has no fix"))
    }

    @Test("--dry-run and --yes mean nothing without --fix")
    func flagsNeedFix() async throws {
        let harness = try harness()
        #expect(try await harness.run(["doctor", "--dry-run"]).exitCode == MacUpExitCode.usage.rawValue)
        #expect(try await harness.run(["doctor", "--yes"]).exitCode == MacUpExitCode.usage.rawValue)
    }
}
