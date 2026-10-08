import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

/// `macup uninstall` and `macup self-uninstall` over a pretend Mac in a
/// temporary folder, with a fake Trash: no test ever removes a real file.
@Suite("macup uninstall")
struct UninstallCommandTests {
    /// A Mac with one downloaded app, a cache and preferences that belong to
    /// it, and its data, which is left in place unless asked for.
    private func mac() throws -> (CLIHarness, UninstallFixture, app: String, cache: String, preferences: String, data: String) {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let fixture = try UninstallFixture()
        let app = try fixture.app("Chatter", identifier: "com.example.chatter", version: "2.1")
        let cache = try fixture.folder("home/Library/Caches/com.example.chatter")
        let preferences = try fixture.file("home/Library/Preferences/com.example.chatter.plist")
        let data = try fixture.folder("home/Library/Application Support/com.example.chatter")
        _ = try fixture.file("home/Library/Application Support/com.example.chatter/chats.db")
        harness.uninstall = fixture.environment()
        return (harness, fixture, app, cache, preferences, data)
    }

    @Test("--list names each app with its version and where it came from, and reads only")
    func list() async throws {
        let (harness, fixture, _, _, _, _) = try mac()
        let run = try await harness.run(["uninstall", "--list"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Chatter"))
        #expect(run.standardOutput.contains("2.1 · Downloaded"))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("A dry run shows what belongs to the app ticked and its data unticked, and removes nothing")
    func dryRun() async throws {
        let (harness, fixture, app, cache, _, data) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--dry-run"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.contains("[x] " + app))
        #expect(output.contains("[x] " + cache))
        #expect(output.contains("[ ] " + data))
        #expect(output.contains("Your chats, saved games, and settings in this app."))
        #expect(output.contains("Nothing was removed."))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("Without a terminal it will not choose how to remove, or confirm, for you")
    func notATerminal() async throws {
        let (harness, fixture, _, _, _, _) = try mac()
        let noMode = try await harness.run(["uninstall", "Chatter", "--yes"])
        #expect(noMode.exitCode == MacUpExitCode.usage.rawValue)
        #expect(noMode.standardError.contains("--mode trash or --mode delete"))
        let noYes = try await harness.run(["uninstall", "Chatter", "--mode", "trash"])
        #expect(noYes.exitCode == MacUpExitCode.usage.rawValue)
        #expect(noYes.standardError.contains("pass --yes"))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("Move to Trash removes what was ticked, keeps the data, says so, and is recorded in history")
    func trash() async throws {
        let (harness, fixture, app, cache, preferences, data) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--mode", "trash", "--yes"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        #expect(Set(fixture.backend.trashed).isSuperset(of: [app, cache, preferences]))
        #expect(!fixture.backend.trashed.contains(data), "data stays unless it is ticked")
        #expect(fixture.backend.deleted.isEmpty)
        #expect(run.standardOutput.contains("Uninstalled Chatter"))
        #expect(run.standardOutput.contains("Moved to the Trash:"))
        #expect(run.standardOutput.contains("Left in place, as you chose:"))
        #expect(try harness.historyStore.load().contains { $0.uninstall?.name == "Chatter" })
    }

    @Test("Delete permanently with --include-data removes the data too, and lists every path it deleted")
    func deleteWithData() async throws {
        let (harness, fixture, app, _, _, data) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--mode", "delete", "--include-data", "--yes"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        #expect(Set(fixture.backend.deleted).isSuperset(of: [app, data]))
        #expect(fixture.backend.trashed.isEmpty)
        #expect(run.standardOutput.contains("Deleted permanently:"))
        #expect(run.standardOutput.contains(data))
    }

    @Test("At a terminal it asks how to remove each time, then asks to confirm; no means nothing is removed")
    func terminalQuestions() async throws {
        let (harness, fixture, app, _, _, _) = try mac()
        harness.isTerminal = true
        harness.answers = ["", "n"]
        let declined = try await harness.run(["uninstall", "Chatter"])
        #expect(declined.standardOutput.contains("Move to Trash or delete permanently?"))
        #expect(declined.standardOutput.contains("move 5 items") || declined.standardOutput.contains("to the Trash?"))
        #expect(declined.standardOutput.contains("Nothing was removed."))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)

        harness.answers = ["d", "y"]
        let deleted = try await harness.run(["uninstall", "Chatter"])
        #expect(deleted.standardOutput.contains("permanently? This cannot be undone."))
        #expect(fixture.backend.deleted.contains(app))
    }

    @Test("A name MacUp cannot find, or a path the plan does not list, is refused before anything happens")
    func refusals() async throws {
        let (harness, fixture, _, _, _, _) = try mac()
        let unknown = try await harness.run(["uninstall", "Nothing Like It", "--mode", "trash", "--yes"])
        #expect(unknown.exitCode == MacUpExitCode.usage.rawValue)
        #expect(unknown.standardError.contains("macup uninstall --list"))
        let outside = try await harness.run(["uninstall", "Chatter", "--include", "/etc/hosts", "--mode", "trash", "--yes"])
        #expect(outside.exitCode == MacUpExitCode.usage.rawValue)
        #expect(outside.standardError.contains("MacUp removes only what its plan lists"))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("An app that is open is not uninstalled; MacUp says to quit it first")
    func runningApp() async throws {
        let (harness, fixture, app, _, _, _) = try mac()
        fixture.running.open("com.example.chatter", name: "Chatter")
        let run = try await harness.run(["uninstall", "Chatter", "--mode", "trash", "--yes"])
        #expect(run.exitCode == MacUpExitCode.failure.rawValue)
        #expect(run.standardOutput.lowercased().contains("quit"))
        #expect(!fixture.backend.trashed.contains(app))
    }

    @Test("--json with --dry-run is the plan, with its kind")
    func jsonPlan() async throws {
        // The fixture is kept to the end: releasing it deletes the pretend Mac.
        let (harness, fixture, _, _, _, _) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--dry-run", "--json"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(document["kind"] as? String == "uninstallPlan")
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("self-uninstall lists MacUp's own files and nothing else, in a dry run")
    func selfUninstallDryRun() async throws {
        let (harness, fixture, app, _, _, _) = try mac()
        try harness.writeConfig(#"{"schemaVersion": 1}"#)
        let run = try await harness.run(["self-uninstall", "--dry-run"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        #expect(run.standardOutput.contains("MacUp self-uninstall · dry run"))
        #expect(run.standardOutput.contains(harness.configDirectory.path), "MacUp's own settings, wherever they are")
        #expect(!run.standardOutput.contains(app), "nothing MacUp did not put there")
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }
}

/// `macup uninstall <target> --admin-script`: the written-down version of
/// what MacUp refuses to do itself. It writes one file of MacUp's own and
/// changes nothing else, and it never runs the file.
@Suite("macup uninstall --admin-script")
struct AdminScriptCommandTests {
    private func mac() throws -> (CLIHarness, UninstallFixture) {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let fixture = try UninstallFixture()
        _ = try fixture.app("Chatter", identifier: "com.example.chatter", version: "2.1")
        _ = try fixture.folder("SystemLibrary/Application Support/com.example.chatter")
        _ = try fixture.launchAgent(
            fixture.root + "/SystemLibrary/LaunchDaemons/com.example.chatter.Helper.plist",
            label: "com.example.chatter.Helper",
            program: fixture.root + "/Applications/Chatter.app/Contents/MacOS/Chatter"
        )
        harness.uninstall = fixture.environment()
        return (harness, fixture)
    }

    @Test("It writes the script, prints what to run, and removes nothing")
    func writesTheScript() async throws {
        let (harness, fixture) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--admin-script"])
        #expect(run.exitCode == nil)
        let output = run.standardOutput
        #expect(output.contains("Wrote the administrator-only part of this uninstall"))
        #expect(output.contains("admin-removal.sh"))
        #expect(output.contains("sudo bash "))
        #expect(output.contains("Root does not use the Trash"))

        let path = harness.stateDirectory.path + "/admin-removal.sh"
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("rm '-rf' '--' '" + fixture.root + "/SystemLibrary/Application Support/com.example.chatter'"))
        #expect(text.contains(#"if [[ "$(id -u)" != 0 ]]; then"#))
        // Nothing was removed and nothing was run: MacUp wrote a file.
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("With nothing for an administrator it writes no script and says why")
    func nothingToScript() async throws {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let fixture = try UninstallFixture()
        _ = try fixture.app("Chatter", identifier: "com.example.chatter")
        harness.uninstall = fixture.environment()

        let run = try await harness.run(["uninstall", "Chatter", "--admin-script"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("nothing in this uninstall needs an administrator"))
        #expect(!FileManager.default.fileExists(atPath: harness.stateDirectory.path + "/admin-removal.sh"))
    }

    @Test("--json names the script, the items, and what was left out of it")
    func jsonDocument() async throws {
        // The fixture is held to the end: releasing it deletes the pretend Mac.
        let (harness, fixture) = try mac()
        let run = try await harness.run(["uninstall", "Chatter", "--admin-script", "--json"])
        #expect(run.exitCode == nil, "\(run.standardError)")
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any]
        )
        #expect(json["kind"] as? String == "adminRemovalScript")
        #expect((json["command"] as? String)?.hasPrefix("sudo bash ") == true)
        #expect((json["items"] as? [String])?.isEmpty == false)
        #expect(json["refused"] != nil)
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }
}
