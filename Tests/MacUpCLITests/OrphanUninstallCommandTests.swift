import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

@Suite("macup uninstall --orphans")
struct OrphanUninstallCommandTests {
    /// A Mac where one app is installed and another has been removed, leaving
    /// its container, saved window state, and settings behind.
    private func mac() throws -> (CLIHarness, UninstallFixture) {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        let fixture = try UninstallFixture()
        try fixture.app("Chatter", identifier: "com.example.chatter", version: "2.1")
        try fixture.folder("home/Library/Caches/com.example.chatter")
        try fixture.folder("home/Library/Containers/com.example.gone")
        try fixture.folder("home/Library/Saved Application State/com.example.gone.savedState")
        try fixture.file("home/Library/Preferences/com.example.gone.plist")
        harness.uninstall = fixture.environment()
        harness.homeDirectory = fixture.home
        return (harness, fixture)
    }

    @Test("It lists what the app that is gone left, and never what an installed app owns")
    func lists() async throws {
        let (harness, fixture) = try mac()
        let run = try await harness.run(["uninstall", "--orphans"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("com.example.gone"))
        #expect(!run.standardOutput.contains("com.example.chatter"), "Chatter is still installed")
        #expect(run.standardOutput.contains("sandbox container"))
        #expect(run.standardOutput.contains("Nothing is ticked"))
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("A dry run for one group ticks nothing and removes nothing")
    func dryRun() async throws {
        let (harness, fixture) = try mac()
        let run = try await harness.run(["uninstall", "leftovers:com.example.gone", "--dry-run"])

        #expect(run.standardOutput.contains("Left behind"))
        #expect(run.standardOutput.contains("[ ] "))
        #expect(!run.standardOutput.contains("[x] "), "nothing is ticked for the user")
        #expect(fixture.backend.trashed.isEmpty && fixture.backend.deleted.isEmpty)
    }

    @Test("With --all and a confirmation, the files go to the Trash")
    func removesWhatWasAskedFor() async throws {
        let (harness, fixture) = try mac()
        let run = try await harness.run([
            "uninstall", "leftovers:com.example.gone", "--all", "--mode", "trash", "--yes",
        ])

        #expect(run.exitCode == nil)
        #expect(fixture.backend.trashed.contains { $0.hasSuffix("Preferences/com.example.gone.plist") })
        #expect(fixture.backend.deleted.isEmpty)
        #expect(!fixture.exists(fixture.home + "/Library/Preferences/com.example.gone.plist"))
        #expect(fixture.exists(fixture.home + "/Library/Caches/com.example.chatter"), "the installed app is untouched")
    }

    @Test("A group that no scan found cannot be uninstalled by naming it")
    func unknownGroup() async throws {
        let (harness, _) = try mac()
        let run = try await harness.run(["uninstall", "leftovers:com.example.never", "--dry-run"])

        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardError.contains("--orphans"))
    }

    @Test("--orphans and a target together are refused, and so are --list and --orphans")
    func validation() async throws {
        let (harness, _) = try mac()
        #expect(try await harness.run(["uninstall", "--orphans", "Chatter"]).exitCode != nil)
        #expect(try await harness.run(["uninstall", "--orphans", "--list"]).exitCode != nil)
    }
}
