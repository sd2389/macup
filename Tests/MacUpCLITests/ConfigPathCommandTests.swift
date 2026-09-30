import ArgumentParser
import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("CLI basics and config path")
struct ConfigPathCommandTests {
    @Test("--version prints the MacUp version")
    func version() {
        do {
            _ = try MacUpCommand.parseAsRoot(["--version"])
            Issue.record("--version should exit")
        } catch {
            #expect(MacUpCommand.message(for: error) == MacUp.version)
        }
    }

    @Test("--help describes the tool and its commands")
    func help() {
        let help = MacUpCommand.helpMessage()
        #expect(help.contains("USAGE: macup"))
        #expect(help.contains("Examples:"))
        #expect(help.contains("macup update --dry-run"))
        for subcommand in ["check", "provider", "config"] {
            #expect(help.contains(subcommand))
        }
    }

    /// Help text is wrapped to the terminal width, so a phrase is matched
    /// against it with the line breaks and indentation collapsed away.
    private func unwrapped(_ command: any ParsableCommand.Type) -> String {
        MacUpCommand.helpMessage(for: command).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test("--help says plainly which commands change things and which only read")
    func helpIsHonestAboutWhatChanges() {
        let help = MacUpCommand.helpMessage()
        let prose = unwrapped(MacUpCommand.self)
        #expect(prose.contains("Two commands change what is installed: `macup update`, and `macup uninstall`"))
        #expect(prose.contains("Each shows its plan first, asks before it changes anything, and records what happened."))
        #expect(prose.contains("Everything else — including plain `macup` — only reads."))
        for subcommand in ["plan", "update", "uninstall", "self-uninstall", "policy", "exclude", "doctor", "history"] {
            #expect(help.contains(subcommand))
        }
        #expect(unwrapped(CheckCommand.self).contains("without changing anything"))
        #expect(unwrapped(PlanCommand.self).contains("change nothing"))
        #expect(unwrapped(UpdateCommand.self).contains("With `macup uninstall`, the only commands that change packages"))
        #expect(unwrapped(UpdateCommand.self).contains("Naming an item is a request, not a confirmation"))
        #expect(unwrapped(DoctorCommand.self).contains("read-only"))
        #expect(unwrapped(HistoryCommand.self).contains("read-only"))
        #expect(unwrapped(PolicyListCommand.self).contains("read-only"))
    }

    @Test("Every command's help says what it does to the machine, including its exit codes")
    func helpDocumentsExitStatus() {
        for command in [PlanCommand.self, UpdateCommand.self, DoctorCommand.self, HistoryCommand.self]
            as [any ParsableCommand.Type]
        {
            #expect(unwrapped(command).contains("Exit status:"))
        }
    }

    @Test("config path prints the canonical locations")
    func humanOutput() async throws {
        let harness = try CLIHarness()
        harness.environment.removeValue(forKey: "MACUP_CONFIG_DIR")
        let run = try await harness.run(["config", "path"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput == """
            Configuration file: /Users/example/.config/macup/config.json
            State directory:    /Users/example/.local/state/macup

            """)
    }

    @Test("config path --json is versioned and machine-readable")
    func jsonOutput() async throws {
        let harness = try CLIHarness()
        harness.environment.removeValue(forKey: "MACUP_CONFIG_DIR")
        harness.environment["MACUP_STATE_DIR"] = "/tmp/state"
        let run = try await harness.run(["config", "path", "--json"])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "configPaths")
        #expect(object["configFile"] as? String == "/Users/example/.config/macup/config.json")
        #expect(object["stateDirectory"] as? String == "/tmp/state")
        #expect(object["stateDirectorySource"] as? String == "environment")
    }

    @Test("A relative MACUP_CONFIG_DIR is an invalid configuration (exit 3)")
    func relativeOverride() async throws {
        let harness = try CLIHarness()
        harness.environment["MACUP_CONFIG_DIR"] = "relative"
        let run = try await harness.run(["config", "path"])
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("MACUP_CONFIG_DIR must be an absolute path"))
        #expect(run.standardOutput.isEmpty)
    }
}
