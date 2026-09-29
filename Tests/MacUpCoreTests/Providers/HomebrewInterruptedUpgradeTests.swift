import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A Homebrew installed outside the standard prefix, with an upgrade of mysql
/// that was stopped part-way: the new version's folder is empty, the old one
/// is no longer linked, and `opt/mysql` still points at the old one. This is
/// what a stopped `brew upgrade` leaves behind, and MacUp must neither call it
/// the new version nor upgrade on top of it.
@Suite("Homebrew after an interrupted upgrade")
struct HomebrewInterruptedUpgradeTests {
    let provider = HomebrewProvider()
    static let prefix = "/Users/example/.homebrew"

    private func harness(receiptFor versions: [String] = ["9.7.1"]) -> ProviderHarness {
        let harness = ProviderHarness(path: Self.prefix + "/bin:/usr/bin:/bin")
        harness.fileSystem.addExecutable(Self.prefix + "/bin/brew")
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        harness.runner.register("brew", ["--prefix"], .success(Self.prefix + "\n"))
        let rack = Self.prefix + "/Cellar/mysql"
        for directory in [Self.prefix, Self.prefix + "/Cellar", Self.prefix + "/opt", rack, Self.prefix + "/Cellar/jq"] {
            harness.fileSystem.addDirectory(directory)
        }
        harness.fileSystem.addDirectory(rack + "/9.7.1")
        harness.fileSystem.addDirectory(rack + "/26.7.0_2")
        for version in versions {
            harness.fileSystem.addFile(rack + "/" + version + "/INSTALL_RECEIPT.json", contents: "{}")
        }
        harness.fileSystem.addSymlink(Self.prefix + "/opt/mysql", to: "../Cellar/mysql/9.7.1")
        harness.fileSystem.addDirectory(Self.prefix + "/Cellar/jq/1.8.1")
        harness.fileSystem.addFile(Self.prefix + "/Cellar/jq/1.8.1/INSTALL_RECEIPT.json", contents: "{}")
        harness.runner.register("brew", HomebrewProvider.installedInfoArguments, .success(try! Fixture.text("homebrew/info-interrupted.json")))
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(try! Fixture.text("homebrew/outdated-interrupted.json")))
        return harness
    }

    private func refinedMysql(_ harness: ProviderHarness) async throws -> UpdateCandidate {
        let context = try await harness.detectedContext(provider)
        let inventory = try await provider.inventory(context: context).elements
        let candidates = try await provider.outdated(context: context).elements
        return try #require(provider.refine(candidates, using: inventory).first { $0.id.rawValue == "brew:mysql" })
    }

    @Test("The inventory reads which version opt points at, which install never finished, and that it would compile")
    func inventoryFacts() async throws {
        let harness = harness()
        let context = try await harness.detectedContext(provider)
        let items = try await provider.inventory(context: context).elements
        let mysql = try #require(items.first { $0.id.rawValue == "brew:mysql" })
        #expect(mysql.details["optVersion"] == "9.7.1")
        #expect(mysql.details["incompleteVersions"] == "26.7.0_2")
        #expect(mysql.details["buildsFromSource"] == "true", "its only ready-made build is for /opt/homebrew")

        let jq = try #require(items.first { $0.id.rawValue == "brew:jq" })
        #expect(jq.details["incompleteVersions"] == nil)
        #expect(jq.details["buildsFromSource"] == nil, "a :any build pours anywhere")
    }

    @Test("The update shows the version in use, not the empty folder, and says what happened")
    func candidateShowsTheTruth() async throws {
        let mysql = try await refinedMysql(harness())
        #expect(mysql.installedVersion == "9.7.1")
        #expect(mysql.availableVersion == "26.7.0_2")
        #expect(mysql.versionChange == .major)
        #expect(mysql.signals.contains(.installationIncomplete))
        #expect(mysql.signals.contains(.buildsFromSource))
        #expect(mysql.risk.level == .high)
        #expect(mysql.notes.contains { $0.contains("did not finish") })
        #expect(mysql.notes.contains { $0.contains("not on your PATH") })
        #expect(mysql.notes.contains { $0.contains("compile mysql from source") })
        #expect(!mysql.signals.contains(.mayAffectDependents), "the unfinished folder's record is not the formula's")
    }

    @Test("MacUp will not start another upgrade on top of an unfinished one")
    func planIsRefused() async throws {
        let harness = harness()
        let mysql = try await refinedMysql(harness)
        let context = try await harness.detectedContext(provider)
        let error = await #expect(throws: MacUpError.self) {
            try await provider.makePlan(for: mysql, context: context)
        }
        #expect(error?.message.contains("did not finish") == true)
        #expect(error?.detail?.contains("26.7.0_2") == true)
    }

    @Test("A build from source is planned with a longer limit and says it must be left to finish")
    func sourceBuildPlan() async throws {
        // Both installs finished this time; only the source build remains.
        let harness = harness(receiptFor: ["9.7.1", "26.7.0_2"])
        var mysql = try await refinedMysql(harness)
        #expect(!mysql.signals.contains(.installationIncomplete))
        mysql = mysql.replacingInstalledVersion("9.7.1", scheme: .standard)
        let plan = try await provider.makePlan(for: mysql, context: try await harness.detectedContext(provider))
        #expect(plan.rationale.contains("compile mysql from source"))
        #expect(plan.rationale.contains("never stops it part-way"))
        #expect(try plan.onlyStep.timeoutSeconds == 4 * 3600)
    }

    @Test("An empty folder named after the target never verifies the upgrade")
    func emptyFolderIsNotSuccess() async throws {
        let harness = harness()
        let context = try await harness.detectedContext(provider)
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "brew:mysql"), kind: .formula, displayName: "mysql",
            installedVersion: "9.7.1", availableVersion: "26.7.0_2"
        )
        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .targetNotReached)
        #expect(result.observedVersion == "9.7.1")
        // What the stopped upgrade left, which is what history records.
        #expect(result.observedState == "No version of mysql is linked, so its commands are not on your PATH. "
            + "The mysql 26.7.0_2 install did not finish.")
    }

    @Test("A read-back says nothing more when there is nothing more to say")
    func observedStateOnlyWhenNoteworthy() {
        let linked = ManagedItem(
            id: try! PackageID(.brew, "jq"), kind: .formula, displayName: "jq",
            installedVersions: ["1.8.1"], activeVersion: "1.8.1"
        )
        #expect(HomebrewProvider.observedState(of: linked) == nil)

        // Keg-only formulae are never linked on purpose.
        var kegOnly = linked
        kegOnly.activeVersion = nil
        kegOnly.details["kegOnly"] = "true"
        #expect(HomebrewProvider.observedState(of: kegOnly) == nil)

        var unlinked = linked
        unlinked.activeVersion = nil
        #expect(HomebrewProvider.observedState(of: unlinked) == "No version of jq is linked, so its commands are not on your PATH.")

        var unfinished = linked
        unfinished.installedVersions = ["1.8.1", "1.9.0", "1.9.1"]
        unfinished.details["incompleteVersions"] = "1.9.0, 1.9.1"
        #expect(HomebrewProvider.observedState(of: unfinished) == "The jq 1.9.0, 1.9.1 installs did not finish.")

        let cask = ManagedItem(
            id: try! PackageID(.brewCask, "firefox"), kind: .cask, displayName: "firefox",
            installedVersions: ["143.0"]
        )
        #expect(HomebrewProvider.observedState(of: cask) == nil, "a cask has no links or receipts to speak of")
    }

    @Test("A Homebrew in the standard prefix pours the same build, so nothing is said about compiling")
    func standardPrefixPours() {
        let item = ManagedItem(
            id: try! PackageID(.brew, "mysql"), kind: .formula, displayName: "mysql",
            installedVersions: ["9.7.1"], activeVersion: "9.7.1",
            details: ["bottleCellars": "/opt/homebrew/Cellar"]
        )
        let annotated = HomebrewProvider.annotate([item], prefix: "/opt/homebrew", fileSystem: FakeFileSystem())
        #expect(annotated.first?.details["buildsFromSource"] == nil)
        let elsewhere = HomebrewProvider.annotate([item], prefix: Self.prefix, fileSystem: FakeFileSystem())
        #expect(elsewhere.first?.details["buildsFromSource"] == "true")
        let noBottle = ManagedItem(
            id: try! PackageID(.brew, "odd"), kind: .formula, displayName: "odd",
            installedVersions: ["1.0"], details: ["bottleCellars": ""]
        )
        #expect(HomebrewProvider.annotate([noBottle], prefix: "/opt/homebrew", fileSystem: FakeFileSystem()).first?.details["buildsFromSource"] == "true")
    }
}
