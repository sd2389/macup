import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup policy skip, unskip, and note")
struct PolicySkipAndNoteCommandTests {
    private func item(_ harness: CLIHarness, _ id: String) throws -> [String: Any]? {
        let items = try harness.readConfig()["items"] as? [String: Any]
        return items?[id] as? [String: Any]
    }

    private func configExists(_ harness: CLIHarness) -> Bool {
        FileManager.default.fileExists(atPath: harness.configDirectory.appending("config.json").path)
    }

    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        return harness
    }

    // MARK: skip

    @Test("skip with no version skips the one a read-only check finds on offer")
    func skipFindsTheOfferedVersion() async throws {
        let harness = try harness()

        let run = try await harness.run(["policy", "skip", "brew:mysql"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        #expect(run.standardError.contains("Checking Homebrew for the version of brew:mysql on offer"))
        #expect(run.standardOutput.contains("brew:mysql now skips 26.7.0_2."))
        #expect(try item(harness, "brew:mysql")?["skipVersion"] as? String == "26.7.0_2")
        #expect(try item(harness, "brew:mysql")?["policy"] as? String == "inherit")

        // Finding the version read, and read only the item's own provider.
        #expect(harness.modifyingRequests.isEmpty)
        #expect(harness.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
        #expect(!harness.runner.recordedRequests.contains { $0.executable.lastPathComponent == "softwareupdate" })
    }

    @Test("skip with --version stores that version and runs nothing at all")
    func skipWithAVersionRunsNothing() async throws {
        let harness = try harness()

        let run = try await harness.run(["policy", "skip", "npm:typescript", "--version", "6.0.0"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("npm:typescript now skips 6.0.0."))
        #expect(try item(harness, "npm:typescript")?["skipVersion"] as? String == "6.0.0")
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("skip with nothing on offer fails clearly and writes nothing")
    func skipWithNoUpdateFails() async throws {
        let harness = try harness()

        let run = try await harness.run(["policy", "skip", "brew:wget"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("No update is available for brew:wget"))
        #expect(run.standardError.contains("--version"))
        #expect(!configExists(harness))
    }

    @Test("skip explains a provider that is off, and one that could not be checked")
    func skipExplainsWhyNothingWasFound() async throws {
        let disabled = try harness()
        try disabled.writeConfig(#"{"schemaVersion": 1, "providers": {"homebrew": {"enabled": false}}}"#)
        let before = try disabled.readConfig()
        let off = try await disabled.run(["policy", "skip", "brew:mysql"])
        #expect(off.exitCode == MacUpExitCode.usage.rawValue)
        #expect(off.standardError.contains("Homebrew is turned off in MacUp"))
        #expect(off.standardError.contains("macup provider enable homebrew"))
        #expect(NSDictionary(dictionary: try disabled.readConfig()) == NSDictionary(dictionary: before))

        let failing = try harness()
        failing.runner.register("brew", ["outdated", "--json=v2"], .exit(1, standardError: "Error: no network"))
        let failed = try await failing.run(["policy", "skip", "brew:mysql"])
        #expect(failed.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(failed.standardError.contains("could not finish checking Homebrew"))
        #expect(!configExists(failing))
    }

    @Test("skip refuses before checking anything when the configuration cannot be read")
    func skipRefusesAnUnreadableConfiguration() async throws {
        let harness = try harness()
        let text = #"{"schemaVersion": 1, "items": {"brew:mysql": {"policy": "ignore", "note": 7}}}"#
        try harness.writeConfig(text)

        let run = try await harness.run(["policy", "skip", "brew:mysql"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("will not change a configuration it cannot read"))
        #expect(harness.runner.recordedRequests.isEmpty)
        #expect(try String(contentsOf: harness.configDirectory.appending("config.json"), encoding: .utf8) == text)
    }

    @Test(
        "skip takes one item and a usable version, or it is a usage error",
        arguments: [
            (["policy", "skip", "homebrew"], "is not a package ID"),
            (["policy", "skip", "default"], "is not a package ID"),
            (["policy", "skip", "brew:mysql", "--version", " 26.7.0_2"], "leading or trailing whitespace"),
            (["policy", "skip", "brew:mysql", "--version", ""], "is empty"),
            (["policy", "unskip", "homebrew"], "is not a package ID"),
        ]
    )
    func skipUsageErrors(arguments: [String], phrase: String) async throws {
        let harness = try harness()
        let run = try await harness.run(arguments)
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains(phrase), "\(run.standardError)")
        #expect(!configExists(harness))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("unskip removes the skip and says so; with nothing skipped it says that")
    func unskip() async throws {
        let harness = try harness()
        _ = try await harness.run(["policy", "skip", "brew:mysql", "--version", "26.7.0_2"])

        let run = try await harness.run(["policy", "unskip", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("brew:mysql no longer skips 26.7.0_2"))
        #expect(try item(harness, "brew:mysql") == nil, "an entry left saying only inherit is removed")

        let again = try await harness.run(["policy", "unskip", "brew:mysql"])
        #expect(again.standardOutput.contains("there was nothing to stop skipping"))
    }

    @Test("skip --json is a PolicyChange for the skipVersion setting")
    func skipJSON() async throws {
        let harness = try harness()
        let run = try await harness.run(["policy", "skip", "brew:mysql", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "policyChange")
        let changes = try #require(object["changes"] as? [[String: Any]])
        #expect(changes.first?["setting"] as? String == "skipVersion")
        #expect(changes.first?["newValue"] as? String == "26.7.0_2")
        #expect(changes.first?["path"] as? String == "items.brew:mysql.skipVersion")
        #expect(!run.standardOutput.contains("Checking Homebrew"), "progress never goes into a JSON document")
    }

    @Test("A refused approval skips nothing, and the prompt names the version")
    func skipNeedsApproval() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "security": {"requireApproval": true}}"#)
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        let run = try await harness.run(["policy", "skip", "brew:mysql"])
        #expect(run.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(harness.authorizer.requestedReasons == ["skip brew:mysql 26.7.0_2"])
        #expect(try item(harness, "brew:mysql") == nil)

        let note = try await harness.run(["policy", "note", "brew:mysql", "later"])
        #expect(note.exitCode == MacUpExitCode.notApproved.rawValue)
        #expect(harness.authorizer.requestedReasons.last == "change the note on brew:mysql")
        #expect(try item(harness, "brew:mysql") == nil)
    }

    // MARK: note

    @Test("note stores the text exactly, and --clear removes it")
    func noteSetAndClear() async throws {
        let harness = try harness()
        try harness.writeConfig(#"{"schemaVersion": 1, "items": {"brew:php": {"policy": "pin"}}}"#)

        let set = try await harness.run(["policy", "note", "brew:php", "waiting for PHP 8.4 support"])
        #expect(set.exitCode == nil)
        #expect(set.standardOutput.contains(#"brew:php now has a note: "waiting for PHP 8.4 support"."#))
        #expect(!set.standardOutput.contains("macup plan"), "a note changes nothing a plan decides")
        #expect(try item(harness, "brew:php")?["note"] as? String == "waiting for PHP 8.4 support")
        #expect(try item(harness, "brew:php")?["policy"] as? String == "pin", "the rule is kept")

        let clear = try await harness.run(["policy", "note", "brew:php", "--clear"])
        #expect(clear.exitCode == nil)
        #expect(clear.standardOutput.contains("brew:php no longer has a note."))
        #expect(try item(harness, "brew:php")?["note"] == nil)
        #expect(try item(harness, "brew:php")?["policy"] as? String == "pin")
    }

    @Test("A note that says pin is a note, not a rule")
    func noteIsNeverARule() async throws {
        let harness = try harness()
        let run = try await harness.run(["policy", "note", "brew:git", "pin"])
        #expect(run.exitCode == nil)
        #expect(!run.standardOutput.contains("Pin is MacUp's own hold"))
        #expect(try item(harness, "brew:git")?["policy"] as? String == "inherit")
    }

    @Test(
        "note refuses what it could not store, before touching anything",
        arguments: [
            (["policy", "note", "brew:php", String(repeating: "x", count: 201)], "at most 200 characters; this one has 201"),
            (["policy", "note", "brew:php", "one\ntwo"], "one line"),
            (["policy", "note", "brew:php", "  "], "cannot be empty"),
            (["policy", "note", "brew:php"], "or --clear"),
            (["policy", "note", "brew:php", "text", "--clear"], "not both"),
            (["policy", "note", "mise", "text"], "is not a package ID"),
        ]
    )
    func noteUsageErrors(arguments: [String], phrase: String) async throws {
        let harness = try harness()
        let run = try await harness.run(arguments)
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains(phrase), "\(run.standardError)")
        #expect(!configExists(harness))
    }

    // MARK: Where they are shown

    private func withSkipAndNote() async throws -> CLIHarness {
        let harness = try harness()
        _ = try await harness.run(["policy", "set", "brew:mysql", "auto"])
        _ = try await harness.run(["policy", "skip", "brew:mysql"])
        _ = try await harness.run(["policy", "note", "brew:mysql", "waiting for PHP 8.4 support"])
        return harness
    }

    @Test("policy list shows the skipped version and the note under the item")
    func listShowsBoth() async throws {
        let harness = try await withSkipAndNote()

        let run = try await harness.run(["policy", "list"])
        #expect(run.standardOutput.contains("brew:mysql  Auto Update  items.brew:mysql.policy"))
        #expect(run.standardOutput.contains("Skips 26.7.0_2  items.brew:mysql.skipVersion"))
        #expect(run.standardOutput.contains("Note: waiting for PHP 8.4 support"))

        let json = try await harness.run(["policy", "list", "--json"])
        let listing = try JSONDecoder.plan.decode(PolicyListing.self, from: Data(json.standardOutput.utf8))
        let rule = try #require(listing.items.first)
        #expect(rule.skipVersion == "26.7.0_2")
        #expect(rule.note == "waiting for PHP 8.4 support")
    }

    @Test("check marks the skipped version and shows the note")
    func checkShowsBoth() async throws {
        let harness = try await withSkipAndNote()

        let run = try await harness.run(["check"])
        let line = try #require(run.standardOutput.split(separator: "\n").first { $0.contains("brew:mysql") })
        #expect(line.contains("you skipped this version"))
        #expect(run.standardOutput.contains("Note: waiting for PHP 8.4 support"))
        // Only the skipped item is marked.
        let git = try #require(run.standardOutput.split(separator: "\n").first { $0.contains("brew:git") })
        #expect(!git.contains("skipped"))
    }

    @Test("check says when a skip no longer applies because a different version is on offer")
    func checkExplainsAStaleSkip() async throws {
        let harness = try harness()
        _ = try await harness.run(["policy", "skip", "brew:mysql", "--version", "26.7.0_1"])

        let run = try await harness.run(["check"])
        #expect(!run.standardOutput.contains("you skipped this version"))
        #expect(run.standardOutput.contains("You skipped 26.7.0_1; 26.7.0_2 is a different version, so the skip no longer applies."))
    }

    @Test("plan leaves the skipped version out, with the reason and the note")
    func planShowsBoth() async throws {
        let harness = try await withSkipAndNote()

        let run = try await harness.run(["plan"])
        #expect(run.standardOutput.contains("You skipped mysql 26.7.0_2. MacUp will offer the next version."))
        #expect(run.standardOutput.contains("Note: waiting for PHP 8.4 support"))

        let json = try await harness.run(["plan", "--json"])
        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(json.standardOutput.utf8))
        #expect(!report.planned.contains { $0.item.rawValue == "brew:mysql" })
        let skipped = try #require(report.skipped.first { $0.item.rawValue == "brew:mysql" })
        #expect(skipped.decision?.source == .skippedVersion)
        #expect(skipped.decision?.note == "waiting for PHP 8.4 support")
    }

    @Test("update never runs a skipped version, even named, confirmed, and set to Auto Update")
    func updateNeverRunsASkippedVersion() async throws {
        let harness = try await withSkipAndNote()
        harness.allowBrewUpgrade("mysql", readingBack: "26.7.0_2")

        let run = try await harness.run(["update", "brew:mysql", "--yes"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        #expect(run.standardError.contains("Nothing was changed."))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("Once a different version is on offer, the item follows its rule again with nothing to undo")
    func aNewVersionComesBack() async throws {
        let harness = try await withSkipAndNote()
        harness.runner.register("brew", ["outdated", "--json=v2"], .success("""
            {"formulae": [{"name": "mysql", "installed_versions": ["9.7.1"], "current_version": "26.8.0", "pinned": false, "pinned_version": null}],
             "casks": []}
            """))

        let run = try await harness.run(["plan", "--json"])
        let report = try JSONDecoder.plan.decode(PlanReport.self, from: Data(run.standardOutput.utf8))
        let planned = try #require(report.planned.first { $0.item.rawValue == "brew:mysql" })
        #expect(planned.plan.proposedVersion.raw == "26.8.0")
        #expect(planned.decision.source != .skippedVersion)
        // The skip is still in the file, and still harmless.
        #expect(try item(harness, "brew:mysql")?["skipVersion"] as? String == "26.7.0_2")
    }
}
