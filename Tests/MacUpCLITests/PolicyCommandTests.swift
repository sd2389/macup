import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup policy and macup provider")
struct PolicyCommandTests {
    private func itemPolicy(_ harness: CLIHarness, _ id: String) throws -> String? {
        let items = try harness.readConfig()["items"] as? [String: Any]
        return (items?[id] as? [String: Any])?["policy"] as? String
    }

    private func providerSettings(_ harness: CLIHarness, _ id: String) throws -> [String: Any]? {
        let providers = try harness.readConfig()["providers"] as? [String: Any]
        return providers?[id] as? [String: Any]
    }

    // MARK: list

    @Test("policy list shows the default, every provider, and where each rule lives")
    func listShowsEverything() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig("""
            {"schemaVersion": 1,
             "providers": {"npm": {"enabled": false, "policy": "auto"}},
             "items": {"brew:postgresql": {"policy": "ignore"}}}
            """)

        let run = try await harness.run(["policy", "list"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Default: Ask First"))
        #expect(run.standardOutput.contains("global.defaultPolicy"))
        #expect(run.standardOutput.contains("npm       disabled  Auto Update"))
        #expect(run.standardOutput.contains("providers.npm"))
        #expect(run.standardOutput.contains("Homebrew  enabled   Inherit → Ask First"))
        #expect(run.standardOutput.contains("brew:postgresql  Ignore"))
        #expect(run.standardOutput.contains("items.brew:postgresql.policy"))
    }

    @Test("policy set pin says the hold is MacUp's own, not the package manager's")
    func pinSaysItIsMacUpsOwnHold() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "set", "brew:git", "pin"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Pin is MacUp's own hold"))

        // Setting it again changes nothing, so there is nothing to explain.
        let again = try await harness.run(["policy", "set", "brew:git", "pin"])
        #expect(!again.standardOutput.contains("Pin is MacUp's own hold"))
    }

    @Test("With nothing customized, policy list says so")
    func listSaysWhenNothingIsCustomized() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy"])
        #expect(run.standardOutput.contains("Nothing is customized"))
        #expect(run.standardOutput.contains("Items · no rules of their own"))
    }

    @Test("policy list --json is a PolicyListing that decodes back")
    func listJSONDecodes() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:postgresql": {"policy": "ignore"}}}"#)

        let run = try await harness.run(["policy", "list", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "policyList")

        let listing = try JSONDecoder.plan.decode(PolicyListing.self, from: Data(run.standardOutput.utf8))
        #expect(listing.defaultPolicy == .ask)
        #expect(listing.items.map(\.item.rawValue) == ["brew:postgresql"])
        #expect(listing.items.first?.path == "items.brew:postgresql.policy")
        #expect(listing.providers.count == ProviderID.known.count)
    }

    @Test("policy list reads and never writes the configuration file")
    func listCreatesNoFile() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        _ = try await harness.run(["policy", "list"])
        #expect(!FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path))
    }

    // MARK: set and clear

    @Test("Setting a policy reports what it was and what it is now")
    func setReportsBothValues() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "ask"}}}"#)

        let run = try await harness.run(["policy", "set", "brew:git", "auto"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("brew:git: Ask First → Auto Update."))
        #expect(run.standardOutput.contains("Saved to"))
        #expect(try itemPolicy(harness, "brew:git") == "auto")
    }

    @Test("Setting what is already set says nothing changed, rather than claiming a change")
    func settingTheSameValueChangesNothing() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "ignore"}}}"#)
        let before = try Data(contentsOf: harness.configDirectory.appending("config.json"))

        let run = try await harness.run(["policy", "set", "brew:git", "ignore"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("already Ignore; nothing was changed."))
        #expect(!run.standardOutput.contains("Saved to"))
        #expect(try Data(contentsOf: harness.configDirectory.appending("config.json")) == before)
    }

    @Test("A rule can be set for a provider, and for the default")
    func setAcceptsProvidersAndTheDefault() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let provider = try await harness.run(["policy", "set", "homebrew", "auto"])
        #expect(provider.standardOutput.contains("Homebrew: Inherit → Auto Update."))
        #expect(try providerSettings(harness, "homebrew")?["policy"] as? String == "auto")

        let global = try await harness.run(["policy", "set", "default", "auto"])
        #expect(global.standardOutput.contains("The default policy: Ask First → Auto Update."))
        let settings = try #require(try harness.readConfig()["global"] as? [String: Any])
        #expect(settings["defaultPolicy"] as? String == "auto")
    }

    @Test("Clearing an item rule makes it inherit again")
    func clearRemovesTheRule() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "ignore"}}}"#)

        let run = try await harness.run(["policy", "clear", "brew:git"])
        #expect(run.standardOutput.contains("no longer has a rule of its own and inherits again"))
        #expect(try itemPolicy(harness, "brew:git") == nil)
    }

    @Test("Clearing a rule that was never set says there was nothing to clear")
    func clearingNothingSaysSo() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "clear", "brew:git"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("there was nothing to clear"))
    }

    @Test("The default policy cannot be cleared, and MacUp says what to do instead")
    func clearingTheDefaultIsRefused() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "clear", "default"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("macup policy set default ask"))
    }

    @Test("policy set --json is a PolicyChange that decodes back")
    func setJSONDecodes() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "set", "brew:git", "ignore", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "policyChange")

        let changes = try #require(object["changes"])
        let decoded = try JSONDecoder.plan.decode(
            [PolicyChange].self,
            from: try JSONSerialization.data(withJSONObject: changes)
        )
        #expect(decoded.count == 1)
        #expect(decoded[0].changed)
        #expect(decoded[0].previousValue == nil)
        #expect(decoded[0].newValue == "ignore")
        #expect(decoded[0].path == "items.brew:git.policy")
    }

    // MARK: exclude

    @Test("exclude writes the same rule as policy set ignore")
    func excludeIsTheSameRule() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["exclude", "brew:postgresql", "npm:@scope/name"])
        #expect(run.exitCode == nil)
        #expect(try itemPolicy(harness, "brew:postgresql") == "ignore")
        #expect(try itemPolicy(harness, "npm:@scope/name") == "ignore")
        #expect(run.standardOutput.contains("brew:postgresql is now Ignore."))
    }

    @Test("An excluded item never reaches a plan")
    func excludedItemsLeaveThePlan() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        _ = try await harness.run(["exclude", "brew:git"])

        let run = try await harness.run(["plan", "--json"])
        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(run.standardOutput.utf8))
        #expect(!report.planned.contains { $0.item.rawValue == "brew:git" })
        #expect(report.skipped.contains { $0.item.rawValue == "brew:git" && $0.decision?.action == .deny })
    }

    // MARK: providers

    @Test("Turning a provider off and on again reports both changes")
    func providerSwitchReportsBothValues() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let off = try await harness.run(["provider", "disable", "mise"])
        #expect(off.exitCode == nil)
        #expect(off.standardOutput.contains("mise: enabled → disabled."))
        #expect(try providerSettings(harness, "mise")?["enabled"] as? Bool == false)

        let on = try await harness.run(["provider", "enable", "mise"])
        #expect(on.standardOutput.contains("mise: disabled → enabled."))
        #expect(try providerSettings(harness, "mise")?["enabled"] as? Bool == true)

        let again = try await harness.run(["provider", "enable", "mise"])
        #expect(again.standardOutput.contains("already enabled; nothing was changed."))
    }

    @Test("A disabled provider is not checked")
    func disabledProviderIsNotChecked() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        _ = try await harness.run(["provider", "disable", "homebrew"])

        let run = try await harness.run(["check"])
        #expect(run.standardOutput.contains("disabled in configuration; not checked"))
    }

    @Test("An unknown provider is a usage error and writes nothing")
    func unknownProviderIsAUsageError() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["provider", "disable", "cargo"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("Unknown provider 'cargo'"))
        #expect(!FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path))
    }

    @Test("An unknown policy target is a usage error")
    func unknownTargetIsAUsageError() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "set", "cargo", "auto"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("is not a package ID, a provider, or default"))

        let badID = try await harness.run(["policy", "set", "pip:requests", "auto"])
        #expect(badID.exitCode == MacUpExitCode.usage.rawValue)
        #expect(badID.standardError.contains("Unknown package namespace 'pip'"))

        let badPolicy = try await harness.run(["policy", "set", "brew:git", "maybe"])
        #expect(badPolicy.exitCode == MacUpExitCode.usage.rawValue)
    }

    // MARK: Refusals

    @Test("MacUp will not write a configuration it could not read")
    func refusesToWriteAnUnreadableConfiguration() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let text = #"{"schemaVersion": 1, "global": {"defaultPolicy": "sometimes"}}"#
        try harness.writeConfig(text)

        let run = try await harness.run(["policy", "set", "brew:git", "ignore"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("will not change a configuration it cannot read"))
        #expect(try String(contentsOf: harness.configDirectory.appending("config.json"), encoding: .utf8) == text)
    }

    @Test("MacUp refuses an edit whose result it would not accept")
    func refusesAnEditThatWouldBreakTheConfiguration() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()

        let run = try await harness.run(["policy", "set", "homebrew", "pin"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("refuses to use"))
        #expect(!FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path))
    }

    @Test("A refused approval leaves the policy file untouched and exits 77")
    func refusedApprovalChangesNoPolicy() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        let run = try await harness.run(["policy", "set", "brew:git", "ignore"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(run.standardError.contains("Nothing was changed."))
        #expect(try itemPolicy(harness, "brew:git") == nil)

        let provider = try await harness.run(["provider", "disable", "npm"])
        #expect(provider.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(try providerSettings(harness, "npm") == nil)
    }

    @Test("Policy output carries no ANSI escapes when stdout is not a terminal")
    func noStylingWithoutATerminal() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:git": {"policy": "ignore"}}}"#)

        let run = try await harness.run(["policy", "list"])
        #expect(!run.standardOutput.contains("\u{1B}["))
    }
}
