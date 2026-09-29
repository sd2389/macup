import Foundation
import MacUpCore
import Testing

@testable import macup

/// `macup update` is the only command that changes anything, so these tests
/// are mostly about what it refuses to do. Nothing here can touch the host:
/// the configuration, state, and history directories are temporary, and the
/// command runner is a fake that throws for any command a test did not
/// register by hand.
@Suite("macup update")
struct UpdateCommandTests {
    /// git updates without asking; mysql is left to the user.
    private static let gitIsAutomatic = """
        {"schemaVersion": 1,
         "items": {"brew:git": {"policy": "auto"}, "brew:mysql": {"policy": "ignore"}}}
        """

    // MARK: Dry run

    @Test("A dry run launches nothing and says what would have run")
    func dryRunLaunchesNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.gitIsAutomatic)

        let run = try await harness.run(["update", "--dry-run"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("dry run"))
        #expect(run.standardOutput.contains("brew upgrade --formula --yes git"))
        #expect(run.standardOutput.contains("Nothing was launched."))
        #expect(run.standardOutput.contains("1 command would have run."))
        #expect(run.standardOutput.contains("Remove --dry-run"))
    }

    @Test("A dry run shows the commands for items that would be asked about too")
    func dryRunShowsItemsNeedingConfirmation() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["update", "brew:mysql", "--dry-run"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("needs your confirmation"))
        #expect(run.standardOutput.contains("brew upgrade --formula --yes mysql"))
        #expect(run.standardOutput.contains("1 command would have run."))
    }

    @Test("A dry run writes nothing to history")
    func dryRunRecordsNoHistory() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.gitIsAutomatic)

        _ = try await harness.run(["update", "--dry-run"])
        #expect(try harness.historyStore.load().isEmpty)
    }

    // MARK: Confirmation

    @Test("Without a terminal, an item set to Ask First is left alone")
    func nonTerminalLeavesAskItemsAlone() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = false
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("this is not a terminal, so MacUp is leaving them alone"))
        #expect(run.standardOutput.contains("pass --yes"))
        #expect(run.standardError.contains("Nothing was changed."))
    }

    @Test("Naming an item is a request, not a confirmation")
    func namingAnItemDoesNotConfirmIt() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = true
        // Somebody is at the terminal but says nothing, which is a no.
        harness.answers = []
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("Left alone: brew:git."))
    }

    @Test("Answering no at a terminal changes nothing")
    func answeringNoChangesNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = true
        harness.answers = ["n"]
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("Run the 1 change that needs your confirmation"))
        #expect(run.standardOutput.contains("Left alone: brew:git."))
    }

    @Test("Answering yes at a terminal runs exactly the plan that was shown")
    func answeringYesRunsThePlan() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = true
        harness.answers = ["y"]
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.map(\.arguments) == [["upgrade", "--formula", "--yes", "git"]])
        #expect(run.standardOutput.contains("updated · confirmed 2.44.0"))
    }

    @Test("--yes confirms the items in the plan it showed")
    func yesConfirmsTheShownPlan() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.map(\.arguments) == [["upgrade", "--formula", "--yes", "git"]])
        #expect(run.standardOutput.contains("Running 1 change."))
        #expect(run.standardOutput.contains("Running: "))
        #expect(run.standardOutput.contains("\n    Upgrading git\n"), "Homebrew's own words, as they arrive")
        #expect(run.standardOutput.contains("1 of 1 item updated"))
    }

    @Test("An update MacUp ran is recorded in history with its verification")
    func recordsWhatItDid() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        _ = try await harness.run(["update", "brew:git", "--yes"])
        let entries = try harness.historyStore.load()
        let attempt = try #require(entries.first { $0.item.rawValue == "brew:git" })
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.verification == .verified)
        #expect(attempt.versionBefore == "2.43.0")
        #expect(attempt.versionAfter == "2.44.0")
        #expect(attempt.origin == .cli)
    }

    @Test("With --json MacUp never asks, and says how to confirm instead")
    func jsonNeverPrompts() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.isTerminal = true
        harness.answers = ["y"]
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--json"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardError.contains("--json never asks"))
    }

    // MARK: Policy

    @Test("An ignored item is never updated, even when you name it with --yes")
    func ignoredItemsAreNeverUpdated() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "ignore"}}}"#)
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("git is ignored"))
        #expect(run.standardError.contains("Nothing was changed."))
    }

    @Test("A formula Homebrew has pinned is never updated, even when set to update automatically")
    func pinnedItemsAreNeverUpdated() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(CLIHarness.brewOutdatedPinned))
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "auto"}}}"#)
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "--yes"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("pinned in Homebrew"))
    }

    @Test("A provider that is turned off proposes nothing")
    func disabledProvidersAreNotRun() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebrew": {"enabled": false}}}"#)
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "--yes"])
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardError.contains("Nothing was changed."))
    }

    @Test("A configuration MacUp cannot read updates nothing, and exits 3")
    func unreadableConfigurationUpdatesNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "whenever"}}}"#)
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "--yes"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardOutput.contains("could not read its configuration"))
    }

    // MARK: Approval

    @Test("A refused approval exits 77 and changes nothing")
    func refusedApprovalChangesNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(run.standardError.contains("You cancelled"))
        #expect(run.standardError.contains("Nothing was changed."))
        #expect(try harness.historyStore.load().isEmpty)
    }

    @Test("An approved update runs, and MacUp asked about the change it was making")
    func approvedUpdateRuns() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .approved(.touchID))
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.exitCode == nil)
        #expect(harness.modifyingRequests.count == 1)
        #expect(harness.authorizer.requestedReasons.contains("update 1 item on this Mac"))
    }

    @Test("A dry run needs no approval, because it changes nothing")
    func dryRunNeedsNoApproval() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("Never asked."))

        let run = try await harness.run(["update", "brew:git", "--dry-run", "--yes"])
        #expect(run.exitCode == nil)
        #expect(harness.authorizer.requestedReasons.isEmpty)
        #expect(harness.modifyingRequests.isEmpty)
    }

    // MARK: Failure

    @Test("A failed update is reported as failed, with the provider's own output, and exits 4")
    func failedUpdateExitsFour() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade(
            "git",
            readingBack: "2.43.0",
            .exit(1, standardError: "Error: git 2.44.0 is not bottled\n")
        )

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.exitCode == MacUpExitCode.updateFailed.rawValue)
        #expect(run.standardOutput.contains("failed"))
        #expect(run.standardOutput.contains("not bottled"))
        #expect(run.standardOutput.contains("0 of 1 item updated · 1 failed"))

        let entries = try harness.historyStore.load()
        #expect(entries.contains { $0.item.rawValue == "brew:git" && $0.outcome == .failed })
    }

    @Test("An update MacUp cannot confirm is not reported as done")
    func unverifiedUpdateIsNotClaimedAsDone() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        // The upgrade succeeds, but Homebrew still reports the old version.
        harness.allowBrewUpgrade("git", readingBack: "2.43.0")

        let run = try await harness.run(["update", "brew:git", "--yes"])
        #expect(run.standardOutput.contains("but 2.43.0 is installed, not 2.44.0"))
        #expect(run.standardOutput.contains("could not confirm the new version"))
    }

    // MARK: Arguments and output

    @Test("Naming something that is not a package ID stops the command before it starts")
    func rejectsMalformedPackageID() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["update", "postgresql"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("is not a package ID"))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("Naming an item with no update available changes nothing and exits 64")
    func rejectsUnmatchedSelection() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:ripgrep", "--yes"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("No update is available for brew:ripgrep"))
        #expect(run.standardError.contains("Nothing was changed."))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("update --json is an ExecutionReport that decodes back, with its schema version")
    func jsonDecodesAsExecutionReport() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(Self.gitIsAutomatic)

        let run = try await harness.run(["update", "--dry-run", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ExecutionReport.schemaVersion)
        #expect(object["kind"] as? String == "update")

        let report = try JSONDecoder.plan.decode(ExecutionReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.dryRun)
        #expect(report.origin == .cli)
        #expect(report.executed.isEmpty)
        #expect(report.skipped.contains { $0.item.rawValue == "brew:git" })
    }

    @Test("Update output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.allowBrewUpgrade("git", readingBack: "2.44.0")

        let run = try await harness.run(["update", "brew:git", "--yes", "--verbose"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }
}
