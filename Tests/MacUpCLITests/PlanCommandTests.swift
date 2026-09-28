import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup plan")
struct PlanCommandTests {
    /// A configuration that lets git update on its own and takes mysql out of
    /// MacUp's hands, so one plan covers both halves of the report.
    private static let mixedPolicy = """
        {"schemaVersion": 1,
         "items": {"brew:git": {"policy": "auto"}, "brew:mysql": {"policy": "ignore"}}}
        """

    @Test("A plan shows the exact command for every change and a reason for every skip")
    func showsCommandsAndReasons() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.mixedPolicy)

        let run = try await harness.run(["plan"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("2.43.0 → 2.44.0"))
        #expect(run.standardOutput.contains("Auto Update · runs without asking"))
        #expect(run.standardOutput.contains("brew upgrade --formula --yes git"))
        #expect(run.standardOutput.contains("Not changing"))
        #expect(run.standardOutput.contains("mysql is ignored"))
        #expect(run.standardOutput.contains("Nothing has been changed."))
    }

    @Test("Planning launches nothing that changes the machine")
    func planningRunsNoModifyingCommand() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.mixedPolicy)

        _ = try await harness.run(["plan"])
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("An item needing confirmation says so on its own line, with the reason")
    func marksItemsNeedingConfirmation() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["plan", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Ask First · needs your confirmation"))
        #expect(run.standardOutput.contains("needs your confirmation first"))
        #expect(run.standardOutput.contains("1 change needs your confirmation"))
    }

    @Test("A formula Homebrew has pinned never becomes a change MacUp could run")
    func pinnedItemsAreNotPlanned() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(CLIHarness.brewOutdatedPinned))
        // Even asked to update itself, a pinned formula stays pinned.
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "auto"}}}"#)

        let run = try await harness.run(["plan", "--json"])
        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.planned.isEmpty)
        #expect(report.skipped.contains { $0.item.rawValue == "brew:git" && $0.decision?.source == .providerPin })
        #expect(report.summary.allowed == 0)
    }

    @Test("An item MacUp cannot plan is listed with the reason, not dropped")
    func unplannableItemsAreListed() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["plan"])
        #expect(run.standardOutput.contains("macos:macOS 27.2 Beta"))
        #expect(run.standardOutput.contains("does not apply them"))
    }

    @Test("plan --json is a PlanReport that decodes back, with its schema version")
    func jsonDecodesAsPlanReport() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.mixedPolicy)

        let run = try await harness.run(["plan", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == PlanReport.schemaVersion)
        #expect(object["kind"] as? String == "plan")

        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.summary.allowed == 1)
        #expect(report.allowed.first?.item.rawValue == "brew:git")
        #expect(report.allowed.first?.plan.steps.first?.invocation.arguments
            == ["upgrade", "--formula", "--yes", "git"])
        #expect(report.skipped.contains { $0.item.rawValue == "brew:mysql" })
    }

    @Test("Naming something that is not a package ID stops the command before it starts")
    func rejectsMalformedPackageID() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["plan", "git"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("is not a package ID"))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("Naming an item with no update available is a usage error")
    func rejectsUnmatchedSelection() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["plan", "brew:ripgrep"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("No update is available for brew:ripgrep"))
    }

    @Test("Plan output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.mixedPolicy)

        let run = try await harness.run(["plan", "--verbose"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }

    @Test("A configuration MacUp cannot read plans no change at all")
    func unreadableConfigurationPlansNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "global": {"defaultPolicy": "sometimes"}}"#)

        let run = try await harness.run(["plan"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardOutput.contains("could not read its configuration"))
        #expect(harness.modifyingRequests.isEmpty)
    }
}

extension JSONDecoder {
    /// Decodes the documents MacUp prints, which use ISO 8601 dates.
    static var plan: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
