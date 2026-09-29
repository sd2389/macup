import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

/// What `macup check` and `macup doctor` say about a Homebrew whose mysql
/// runs as a service, and about one whose mysql upgrade was cut short.
@Suite("macup check and doctor: Homebrew services and state")
struct HomebrewStateCommandTests {
    static let serviceInfo = """
        {"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.43.0", "installed_on_request": true}], "linked_keg": "2.43.0"},
                      {"name": "mysql", "full_name": "mysql", "installed": [{"version": "9.7.1", "installed_on_request": true}], "linked_keg": "9.7.1",
                       "service": {"run": ["/opt/homebrew/opt/mysql/bin/mysqld_safe"], "run_type": "immediate"}}],
         "casks": []}
        """

    @Test("A check flags an update that would change a running database, and the verbose view says what to do")
    func checkFlagsRunningDatabase() async throws {
        let harness = try CLIHarness()
        harness.fileSystem.addFile("/opt/homebrew/Library/Homebrew/cmd/services.rb")
        harness.runner.register("brew", ["info", "--json=v2", "--installed"], .success(Self.serviceInfo))
        harness.runner.register("brew", ["services", "list", "--json"], .success(#"[{"name": "mysql", "status": "started", "user": "example", "exit_code": null}]"#))

        let run = try await harness.run(["check", "--verbose", "--provider", "homebrew"])
        let row = try #require(run.standardOutput.components(separatedBy: "\n").first { $0.contains("brew:mysql") })
        #expect(row.contains("high risk · major · running as a service · may convert its data"))
        #expect(run.standardOutput.contains("mysql is running now as a Homebrew service."))
        #expect(run.standardOutput.contains("MacUp never restarts services. Restart it yourself when you are ready, with `brew services restart mysql`."))
        #expect(run.standardOutput.contains("Back up your data before you upgrade."))
        #expect(run.standardOutput.contains("/opt/homebrew/bin/brew services list --json"))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("Doctor explains an interrupted upgrade and lists the repair, one step per line, in order")
    func doctorExplainsInterruptedUpgrade() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        let rack = "/opt/homebrew/Cellar/mysql"
        for directory in ["/opt/homebrew/Cellar", "/opt/homebrew/opt", rack, rack + "/9.7.1", rack + "/26.7.0_2"] {
            harness.fileSystem.addDirectory(directory)
        }
        harness.fileSystem.addFile(rack + "/9.7.1/INSTALL_RECEIPT.json", contents: "{}")
        harness.fileSystem.addSymlink("/opt/homebrew/opt/mysql", to: "../Cellar/mysql/9.7.1")
        harness.runner.register("brew", ["info", "--json=v2", "--installed"], .success("""
            {"formulae": [{"name": "mysql", "full_name": "mysql", "installed": [{"version": "9.7.1", "installed_on_request": true}, {"version": "26.7.0_2", "installed_on_request": false}], "linked_keg": null, "keg_only": false}],
             "casks": []}
            """))

        let run = try await harness.run(["doctor"])
        #expect(run.exitCode == MacUpExitCode.attentionRequired.rawValue)
        let output = run.standardOutput
        #expect(output.contains("warning An install of mysql did not finish · Homebrew"))
        #expect(output.contains("        1. In Finder, choose Go > Go to Folder, enter /opt/homebrew/Cellar/mysql, and move the 26.7.0_2 folder to the Trash.\n"))
        #expect(output.contains("        2. Then run `brew link mysql`, which links 9.7.1 again and puts mysql's commands back on your PATH.\n"))
        #expect(output.contains("warning mysql is installed but not linked"))
        #expect(harness.modifyingRequests.isEmpty)
    }
}
