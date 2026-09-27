import ArgumentParser
import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup check")
struct CheckCommandTests {
    @Test("`macup` with no subcommand is the read-only check")
    func defaultSubcommand() throws {
        #expect(try MacUpCommand.parseAsRoot([]) is CheckCommand)
        let check = try #require(try MacUpCommand.parseAsRoot(["check", "--json", "--provider", "npm", "--provider", "mise"]) as? CheckCommand)
        #expect(check.json)
        #expect(check.providers == ["npm", "mise"])
    }

    @Test("Unknown providers are a usage error")
    func unknownProvider() {
        do {
            _ = try MacUpCommand.parseAsRoot(["check", "--provider", "pip"])
            Issue.record("expected a validation error")
        } catch {
            #expect(MacUpCommand.exitCode(for: error).rawValue == MacUpExitCode.usage.rawValue)
            #expect(MacUpCommand.message(for: error).contains("Unknown provider 'pip'"))
        }
    }

    @Test("Human output: what was found, and that nothing was changed")
    func humanOutput() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.hasPrefix("MacUp check · read-only · nothing was changed\n"))
        #expect(output.contains("Homebrew 7.0.6 · /opt/homebrew/bin/brew"))
        #expect(output.contains("  2 installed · 2 updates"))
        #expect(output.contains("brew:git"))
        #expect(output.contains("2.43.0 → 2.44.0"))
        #expect(output.contains("moderate risk · minor"))
        #expect(output.contains("brew:mysql"))
        #expect(output.contains("high risk · major"))
        #expect(output.contains("npm · not found"))
        #expect(output.contains("mise · not found"))
        #expect(output.contains("macos:macOS 27.2 Beta-26B5091g"))
        #expect(output.contains("restart required"))
        #expect(output.contains("Review and install macOS updates in System Settings"))
        #expect(output.contains("3 updates available (Homebrew 2, macOS 1)."))
        #expect(output.contains("For details on each update, run `macup check --verbose`."))
        #expect(output.contains("\nNothing was changed.\n"))
        #expect(!output.contains("\u{1B}"), "no ANSI when stdout is not a terminal")
        #expect(run.standardError.isEmpty)
    }

    @Test("--verbose lists every command MacUp ran")
    func verbose() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check", "--verbose"])
        #expect(run.standardOutput.contains("Commands MacUp ran (all read-only):"))
        #expect(run.standardOutput.contains("/opt/homebrew/bin/brew outdated --json=v2"))
        #expect(run.standardOutput.contains("/usr/sbin/softwareupdate --list --no-scan"))
        #expect(run.standardOutput.contains("Managed by: Homebrew"))
        #expect(run.standardOutput.contains("Risk: Major version change"))
        #expect(!run.standardOutput.contains("For details on each update"), "no hint when details are already shown")
    }

    @Test("Styling only on a terminal, and never with NO_COLOR")
    func styling() async throws {
        let harness = try CLIHarness()
        harness.isTerminal = true
        let styled = try await harness.run(["check"]).standardOutput
        #expect(styled.contains("\u{1B}[1m"))
        #expect(styled.contains("\u{1B}[31mhigh risk\u{1B}[0m"), "risk is colored, and still spelled out")
        #expect(styled.contains("\u{1B}[33mmoderate risk\u{1B}[0m"))
        harness.environment["NO_COLOR"] = "1"
        #expect(!(try await harness.run(["check"]).standardOutput.contains("\u{1B}")))
    }

    @Test("Hostile provider output cannot reach the terminal raw")
    func hostileOutputIsSanitized() async throws {
        let harness = try CLIHarness()
        harness.isTerminal = true
        let root = "/opt/homebrew/lib/node_modules/"
        let outdated: [String: [String: String]] = [
            "evil\u{1B}]0;pwned\u{7}": ["current": "1.0.0", "latest": "1.0.1", "location": root + "evil"],
            "\u{202E}txt.exe": ["current": "1.0.0", "latest": "1.0.1", "location": root + "x"],
            "fine; rm -rf ~": ["current": "1.0.0", "latest": "1.0.1", "location": root + "fine; rm -rf ~"],
        ]
        harness.addNpm(outdated: String(decoding: try JSONSerialization.data(withJSONObject: outdated), as: UTF8.self))
        let run = try await harness.run(["check"])
        // Remove exactly the styling codes MacUp itself emits; anything left is a leak.
        let text = ["[0m", "[1m", "[2m", "[31m", "[32m", "[33m"].reduce(run.standardOutput) { text, code in
            text.replacingOccurrences(of: "\u{1B}" + code, with: "")
        }
        for line in text.split(separator: "\n") {
            #expect(!line.unicodeScalars.contains(where: TerminalText.isUnsafe), "only MacUp's own styling may be raw: \(line.debugDescription)")
        }
        #expect(text.contains("npm:fine; rm -rf ~"))
        #expect(text.contains("Skipped an item with a name MacUp will not handle"))
    }

    @Test("JSON output is versioned and complete")
    func jsonOutput() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check", "--json"])
        #expect(run.exitCode == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(Set(object.keys) == [
            "schemaVersion", "kind", "macupVersion", "mode", "startedAt", "finishedAt", "cancelled",
            "configuration", "providers", "updates", "summary", "commands",
        ])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "check")
        #expect(object["mode"] as? String == "readOnly")
        let updates = try #require(object["updates"] as? [[String: Any]])
        #expect(updates.compactMap { $0["id"] as? String } == ["brew:git", "brew:mysql", "macos:macOS 27.2 Beta-26B5091g"])
        let commands = try #require(object["commands"] as? [[String: Any]])
        #expect(!commands.isEmpty)
        #expect(commands.allSatisfy { $0["effect"] as? String == "readOnly" })

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(CheckReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.summary.updatesAvailable == 3)
    }

    @Test("A provider failure exits 2 and explains what ran")
    func providerFailureExitCode() async throws {
        let harness = try CLIHarness()
        harness.runner.register("brew", ["outdated", "--json=v2"], .exit(1, standardError: "Error: Something went wrong.\n"))
        let run = try await harness.run(["check"])
        #expect(run.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(run.standardOutput.contains("error (update check): `brew outdated` failed."))
        #expect(run.standardOutput.contains("Ran: /opt/homebrew/bin/brew outdated --json=v2 (exit status 1)"))
        #expect(run.standardOutput.contains("1 provider reported errors; results are incomplete."))
    }

    @Test("Updates MacUp could not read make the check incomplete, never \"up to date\"")
    func unreadableUpdatesAreIncomplete() async throws {
        let harness = try CLIHarness()
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(#"{"formulae": [], "casks": []}"#))
        harness.runner.register("softwareupdate", ["--list", "--no-scan"], .success("""
            Software Update found the following new or updated software:
            * Label: Mystery Update-1.0
            * Label: macOS 27.2-26C100
            \tTitle: macOS 27.2, Version: 27.2, Size: 5000000KiB, Recommended: YES, Action: restart,

            """))
        let run = try await harness.run(["check"])
        #expect(run.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(run.standardOutput.contains("1 update · 1 more could not be read"))
        #expect(run.standardOutput.contains("1 provider left some updates out; results are incomplete."))

        harness.runner.register("softwareupdate", ["--list", "--no-scan"], .success(
            "Software Update found the following new or updated software:\n* Label: Mystery Update-1.0\n"
        ))
        let onlyUnreadable = try await harness.run(["check", "--provider", "macos"])
        #expect(onlyUnreadable.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(!onlyUnreadable.standardOutput.contains("up to date"))
        #expect(onlyUnreadable.standardOutput.contains("listed none MacUp could read"))
    }

    @Test("An invalid configuration still checks, disables automatic modification, and exits 3")
    func invalidConfiguration() async throws {
        let harness = try CLIHarness()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebrew": {"enabeld": false}}}"#)
        let run = try await harness.run(["check"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardOutput.contains("brew:git"))
        #expect(run.standardOutput.contains("has 1 error; automatic modifications stay disabled until it is fixed"))
    }

    @Test("Disabled providers are shown and not run")
    func disabledProvider() async throws {
        let harness = try CLIHarness()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebrew": {"enabled": false}}}"#)
        let run = try await harness.run(["check"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Homebrew · disabled in configuration; not checked"))
        #expect(!harness.runner.recordedRequests.contains { $0.executable.lastPathComponent == "brew" })
    }

    @Test("--provider limits the check")
    func providerFilter() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["check", "--provider", "macos", "--json"])
        let report = try JSONDecoder.iso8601.decode(CheckReport.self, from: Data(run.standardOutput.utf8))
        #expect(report.providers.map(\.provider) == [.macos])
        #expect(harness.runner.recordedRequests.allSatisfy { $0.executable.lastPathComponent == "softwareupdate" })
    }

    @Test("--refresh announces itself on stderr and runs the refresh commands")
    func refresh() async throws {
        let harness = try CLIHarness()
        harness.runner.register("brew", ["update"], .success())
        harness.runner.register("softwareupdate", ["--list"], .success(CLIHarness.softwareUpdate))
        let run = try await harness.run(["check", "--refresh"])
        #expect(run.standardError.contains("No packages will be changed."))
        #expect(run.standardOutput.hasPrefix("MacUp check · metadata refreshed · no packages were changed"))
        #expect(harness.runner.recordedRequests.contains { $0.arguments == ["update"] && $0.effect == .metadataRefresh })
    }
}

@Suite("macup provider list and config show")
struct ProviderAndConfigCommandTests {
    @Test("provider list shows the exact installation of each provider")
    func providerList() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["provider", "list"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Homebrew  found"))
        #expect(run.standardOutput.contains("/opt/homebrew/bin/brew"))
        #expect(run.standardOutput.contains("npm       not found"))
        #expect(run.standardOutput.contains("macOS     found"))
        #expect(!harness.runner.recordedRequests.contains { $0.arguments.first == "outdated" })
    }

    @Test("`macup providers` and `macup provider` list providers directly")
    func providerShortcuts() async throws {
        for arguments in [["providers"], ["provider"]] {
            let harness = try CLIHarness()
            let run = try await harness.run(arguments)
            #expect(run.exitCode == nil)
            #expect(run.standardOutput.contains("Homebrew  found"), "\(arguments)")
        }
    }

    @Test("`macup config` shows the configuration directly")
    func configShortcut() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["config"])
        #expect(run.standardOutput.contains("No configuration file; using built-in defaults."))
    }

    @Test("provider list --json")
    func providerListJSON() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["provider", "list", "--json"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "providerList")
        #expect((object["providers"] as? [Any])?.count == 4)
    }

    @Test("config show without a file explains the defaults and creates nothing")
    func configShowDefaults() async throws {
        let harness = try CLIHarness()
        let run = try await harness.run(["config", "show"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("No configuration file; using built-in defaults."))
        #expect(run.standardOutput.contains(#""defaultPolicy" : "ask""#))
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.configDirectory.path).isEmpty)
    }

    @Test("config show lists every problem and exits 3")
    func configShowInvalid() async throws {
        let harness = try CLIHarness()
        try harness.writeConfig(#"{"schemaVersion": 1, "providers": {"homebew": {}}, "schedule": {"time": "25:00"}}"#)
        let run = try await harness.run(["config", "show"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardOutput.contains("error: providers.homebew: Unknown provider 'homebew'."))
        #expect(run.standardOutput.contains("error: schedule.time:"))
        #expect(run.standardOutput.contains("Automatic changes: disabled until the errors below are fixed."))

        let json = try await harness.run(["config", "show", "--json"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.standardOutput.utf8)) as? [String: Any])
        #expect(object["kind"] as? String == "configuration")
        #expect(object["valid"] as? Bool == false)
        #expect(object["automaticModificationsAllowed"] as? Bool == false)
        #expect((object["issues"] as? [Any])?.count == 2)
    }

    @Test("config show says a configured schedule does not run yet")
    func configShowInertSchedule() async throws {
        let harness = try CLIHarness()
        try harness.writeConfig(#"{"schemaVersion": 1, "schedule": {"enabled": true, "frequency": "daily", "time": "23:00"}}"#)
        let run = try await harness.run(["config", "show"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Scheduling: set in the file, but this version of MacUp runs no scheduled checks."))

        try harness.writeConfig(#"{"schemaVersion": 1, "schedule": {"enabled": false}}"#)
        let off = try await harness.run(["config", "show"])
        #expect(!off.standardOutput.contains("Scheduling:"))
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
