import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup self-update")
struct SelfUpdateCommandTests {
    /// A Mac where Homebrew installed the `macup` command, with `newer` in
    /// Homebrew's outdated list when a test asks for one.
    private func brewInstalled(update newer: String?) throws -> CLIHarness {
        let harness = try CLIHarness()
        let cellar = "/opt/homebrew/Cellar/macup/0.4.0/bin/macup"
        harness.executablePath = cellar
        harness.fileSystem.addExecutable(cellar)
        let outdated = newer.map {
            """
            {"formulae": [{"name": "sd2389/macup/macup", "installed_versions": ["0.4.0"], "current_version": "\($0)", "pinned": false}],
             "casks": []}
            """
        } ?? #"{"formulae": [], "casks": []}"#
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(outdated))
        harness.runner.register("brew", ["info", "--json=v2", "--installed"], .success("""
            {"formulae": [{"name": "sd2389/macup/macup", "full_name": "sd2389/macup/macup", "installed": [{"version": "0.4.0", "installed_on_request": true}], "linked_keg": "0.4.0", "pinned": false}],
             "casks": []}
            """))
        return harness
    }

    @Test("A copy you downloaded is not updated: MacUp says so and prints where the releases are")
    func downloadedCopy() async throws {
        let harness = try CLIHarness()
        harness.executablePath = "/Users/example/.local/bin/macup"

        let run = try await harness.run(["self-update"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("was not installed by a package manager"))
        #expect(run.standardOutput.contains("https://github.com/sd2389/macup/releases"))
        #expect(run.standardOutput.contains("never downloads or replaces itself"))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("With Homebrew and nothing newer, it says so and runs nothing")
    func upToDate() async throws {
        let harness = try brewInstalled(update: nil)
        let run = try await harness.run(["self-update"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("is up to date, according to Homebrew"))
        #expect(run.standardOutput.contains("The macup command, installed by Homebrew"))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("An update is an ordinary Homebrew update, shown with its exact command, and --dry-run runs nothing")
    func dryRun() async throws {
        let harness = try brewInstalled(update: "0.5.0")
        let run = try await harness.run(["self-update", "--dry-run"])

        #expect(run.standardOutput.contains("can be updated to 0.5.0"))
        #expect(run.standardOutput.contains("brew upgrade --formula --yes sd2389/macup/macup"))
        #expect(harness.modifyingRequests.isEmpty, "a dry run launches nothing")
    }

    @Test("It updates MacUp and nothing else, even when other items are outdated too")
    func updatesOnlyMacUp() async throws {
        let harness = try CLIHarness()
        let cellar = "/opt/homebrew/Cellar/macup/0.4.0/bin/macup"
        harness.executablePath = cellar
        harness.fileSystem.addExecutable(cellar)
        harness.runner.register("brew", ["outdated", "--json=v2"], .success("""
            {"formulae": [{"name": "macup", "installed_versions": ["0.4.0"], "current_version": "0.5.0", "pinned": false},
                          {"name": "git", "installed_versions": ["2.43.0"], "current_version": "2.44.0", "pinned": false}],
             "casks": []}
            """))
        harness.runner.register("brew", ["info", "--json=v2", "--installed"], .success("""
            {"formulae": [{"name": "macup", "full_name": "macup", "installed": [{"version": "0.4.0", "installed_on_request": true}], "linked_keg": "0.4.0", "pinned": false},
                          {"name": "git", "full_name": "git", "installed": [{"version": "2.43.0", "installed_on_request": true}], "linked_keg": "2.43.0", "pinned": false}],
             "casks": []}
            """))

        let run = try await harness.run(["self-update", "--dry-run"])

        #expect(run.standardOutput.contains("macup"))
        #expect(!run.standardOutput.contains("brew upgrade --formula --yes git"), "git is not part of updating MacUp")
    }

    @Test("--json says where MacUp came from and whether Homebrew has anything newer")
    func json() async throws {
        let harness = try brewInstalled(update: nil)
        let run = try await harness.run(["self-update", "--json"])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])

        #expect(json["kind"] as? String == "selfUpdate")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["managedByHomebrew"] as? Bool == true)
        #expect(json["updateAvailable"] as? Bool == false)
        #expect(json["releasesURL"] as? String == "https://github.com/sd2389/macup/releases")
        let installations = try #require(json["installations"] as? [[String: Any]])
        #expect(installations.first?["kind"] as? String == "homebrewFormula")
    }

    @Test("A rule that ignores MacUp's own item stops the self-update, and says how to change it")
    func respectsPolicy() async throws {
        let harness = try brewInstalled(update: "0.5.0")
        _ = try await harness.run(["policy", "set", "brew:sd2389/macup/macup", "ignore"])

        let run = try await harness.run(["self-update", "--dry-run"])

        #expect(run.standardOutput.contains("will not update itself"))
        #expect(run.standardOutput.contains("macup policy set"))
        #expect(harness.modifyingRequests.isEmpty)
    }
}
