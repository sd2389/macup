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

    @Test("--help describes the tool")
    func help() {
        let help = MacUpCommand.helpMessage()
        #expect(help.contains("USAGE: macup"))
        #expect(help.contains("config"))
    }

    @Test("config path prints the canonical locations")
    func humanOutput() async throws {
        let (context, stdout, stderr) = CLIContext.testing()
        let run = try await runCLI(["config", "path"], context: context, stdout: stdout, stderr: stderr)
        #expect(run.exitCode == nil)
        #expect(run.standardOutput == """
            Configuration file: /Users/example/.config/macup/config.json
            State directory:    /Users/example/.local/state/macup

            """)
    }

    @Test("config path --json is versioned and machine-readable")
    func jsonOutput() async throws {
        let (context, stdout, stderr) = CLIContext.testing(environment: ["MACUP_STATE_DIR": "/tmp/state"])
        let run = try await runCLI(["config", "path", "--json"], context: context, stdout: stdout, stderr: stderr)
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
        let (context, stdout, stderr) = CLIContext.testing(environment: ["MACUP_CONFIG_DIR": "relative"])
        let run = try await runCLI(["config", "path"], context: context, stdout: stdout, stderr: stderr)
        #expect(run.exitCode == MacUpExitCode.configurationInvalid.rawValue)
        #expect(run.standardError.contains("MACUP_CONFIG_DIR must be an absolute path"))
        #expect(run.standardOutput.isEmpty)
    }
}
