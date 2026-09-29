import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup explain")
struct ExplainCommandTests {
    /// `brew outdated` with only mysql outdated, so git is an installed item
    /// with no update.
    private static let onlyMysqlOutdated = """
        {"formulae": [{"name": "mysql", "installed_versions": ["9.7.1"], "current_version": "26.7.0_2", "pinned": false, "pinned_version": null}],
         "casks": []}
        """

    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        return harness
    }

    @Test("An update MacUp can plan: versions, risk, policy and its rule, the exact command, and history")
    func plannableUpdate() async throws {
        let harness = try harness()
        try harness.historyStore.append(HistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1_790_000_000),
            origin: .gui,
            item: try PackageID(parsing: "brew:git"),
            versionBefore: "2.42.0",
            versionTarget: "2.43.0",
            versionAfter: "2.43.0",
            command: "/opt/homebrew/bin/brew upgrade --formula --yes git",
            outcome: .succeeded,
            verification: .verified,
            durationSeconds: 4
        ))

        let run = try await harness.run(["explain", "brew:git"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.hasPrefix("MacUp explain · read-only · nothing was changed"))
        #expect(output.contains("An update is available: 2.43.0 → 2.44.0. MacUp would apply it once you confirm."))
        #expect(output.contains("  Available: 2.44.0, a minor change"))
        #expect(output.contains("  What changes: Minor 43 → 44."))
        #expect(output.contains("Risk: moderate"))
        #expect(output.contains("Policy: Ask First · needs your confirmation"))
        #expect(output.contains("  Set by: the default policy (global.defaultPolicy)"))
        #expect(output.contains("    Runs: /opt/homebrew/bin/brew upgrade --formula --yes git"))
        #expect(output.contains("  Undo: MacUp has no tested rollback strategy for this action."))
        #expect(output.contains("History · 1 entry"))
        #expect(output.contains("updated, confirmed  from the app"))
        // Explaining is read-only, and it only asks the item's own provider.
        #expect(harness.modifyingRequests.isEmpty)
        #expect(harness.runner.recordedRequests.allSatisfy { $0.executable.lastPathComponent == "brew" })
    }

    @Test("An item a rule leaves alone shows the rule and no command")
    func ruleLeavesItAlone() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "ignore"}}}"#)

        let run = try await harness.run(["explain", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Policy: Ignore · will not run"))
        #expect(run.standardOutput.contains("  Set by: a rule you set for this item (items.brew:mysql.policy)"))
        #expect(run.standardOutput.contains("What MacUp would run: nothing"))
        #expect(run.standardOutput.contains("`macup policy clear brew:mysql` removes the rule for this item."))
        #expect(!run.standardOutput.contains("Runs:"))
    }

    @Test("An update MacUp cannot plan says why, instead of showing a command")
    func cannotPlan() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "macos:macOS 27.2 Beta-26B5091g"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("MacUp cannot plan it."))
        #expect(run.standardOutput.contains("MacUp reports macOS updates but does not apply them."))
        #expect(!run.standardOutput.contains("Runs:"))
    }

    @Test("An installed item with no update is explained, and exits 0")
    func installedWithoutUpdate() async throws {
        let harness = try harness()
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(Self.onlyMysqlOutdated))

        let run = try await harness.run(["explain", "brew:git"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Installed: 2.43.0. Homebrew offers no update for it."))
        #expect(run.standardOutput.contains("No update is available, so there is nothing to decide yet."))
        #expect(run.standardOutput.contains("History: nothing recorded for this item."))
    }

    @Test("An item MacUp knows nothing about is a usage error that says where to look")
    func unknownItem() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "brew:ripgrep"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardOutput.isEmpty, "there is nothing to explain, so no explanation is printed")
        #expect(run.standardError.contains("error: Homebrew does not list brew:ripgrep as installed, and offers no update for it."))
        #expect(run.standardError.contains("`macup check --inventory` lists every item MacUp can see."))
    }

    @Test("An unknown item still mentions the rule MacUp holds for it")
    func unknownItemWithARule() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:postgresql": {"policy": "ignore"}}}"#)
        let run = try await harness.run(["explain", "brew:postgresql"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("MacUp still has a rule for it: Ignore (items.brew:postgresql.policy)."))
    }

    @Test("A turned-off provider is a usage error that says how to turn it back on, and runs nothing")
    func disabledProvider() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebrew": {"enabled": false}}}"#)
        let run = try await harness.run(["explain", "brew:git"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("turned off in MacUp's configuration"))
        #expect(run.standardError.contains("`macup provider enable homebrew`"))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("Something that is not a package ID stops the command before anything runs")
    func malformedID() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "git"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("is not a package ID"))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("A provider that fails part-way is exit 2, and the output says what failed")
    func providerFailure() async throws {
        let harness = try harness()
        harness.runner.register("brew", ["outdated", "--json=v2"], .exit(1, standardError: "Error: something broke\n"))
        let run = try await harness.run(["explain", "brew:git"])
        #expect(run.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(run.standardOutput.contains("MacUp could not find out whether Homebrew has an update for it."))
        #expect(run.standardOutput.contains("error (update check):"))
    }

    @Test("A configuration MacUp cannot read is exit 3, and the explanation says nothing may change")
    func unreadableConfiguration() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "global": {"defaultPolicy": "sometimes"}}"#)
        let run = try await harness.run(["explain", "brew:git"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardOutput.contains("could not read its configuration"))
        #expect(!run.standardOutput.contains("Runs:"))
    }

    @Test("explain --json is a versioned explain document that decodes back and encodes the same")
    func jsonRoundTrip() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "brew:git", "--json"])
        #expect(run.exitCode == nil)

        let data = Data(run.standardOutput.utf8)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == ItemExplanation.schemaVersion)
        #expect(object["kind"] as? String == "explain")
        #expect(object["status"] as? String == "updateAvailable")
        #expect(Set(object.keys) == [
            "schemaVersion", "kind", "macupVersion", "createdAt", "item", "status", "summary", "update",
            "versionDifference", "installed", "policy", "plan", "history", "providerReport", "configuration",
            "cancelled",
        ])

        let explanation = try JSONDecoder.plan.decode(ItemExplanation.self, from: data)
        #expect(explanation.item.rawValue == "brew:git")
        #expect(explanation.plan?.steps.first?.invocation.arguments == ["upgrade", "--formula", "--yes", "git"])
        #expect(explanation.policy.rule == "global.defaultPolicy")
        #expect(explanation.policy.decision?.action == .confirm)
        #expect(explanation.providerReport?.items == nil)
        // Nothing is lost on the way through: encoding what was decoded gives
        // back the document byte for byte.
        #expect(try JSONOutput.encode(explanation) + "\n" == run.standardOutput)
    }

    @Test("An unknown item in JSON is still a document, with the usage exit code")
    func jsonUnknownItem() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "brew:ripgrep", "--json"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        let explanation = try JSONDecoder.plan.decode(ItemExplanation.self, from: Data(run.standardOutput.utf8))
        #expect(explanation.status == .notFound)
        #expect(explanation.plan == nil && explanation.update == nil && explanation.installed == nil)
    }

    @Test("Output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try harness()
        let run = try await harness.run(["explain", "brew:git"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }

    @Test("On a terminal, only the styling differs: the words are the ones the app copies")
    func stylingKeepsTheWords() async throws {
        let plain = try await harness().run(["explain", "brew:git"]).standardOutput
        let terminal = try harness()
        terminal.isTerminal = true
        terminal.environment["TERM"] = "xterm-256color"
        let styled = try await terminal.run(["explain", "brew:git"]).standardOutput
        #expect(styled.contains("\u{1B}[1m"))
        let stripped = styled.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        #expect(stripped == plain)
    }
}
