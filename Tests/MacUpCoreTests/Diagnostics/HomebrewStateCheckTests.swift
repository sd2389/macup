import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Doctor: Homebrew's own state")
struct HomebrewStateCheckTests {
    let check = HomebrewStateCheck()
    static let prefix = "/Users/example/.homebrew"

    private func scenario(_ items: [ManagedItem], prefix: String = Self.prefix, fileSystem: FakeFileSystem = FakeFileSystem()) -> DoctorDiagnosticScenario {
        var scenario = DoctorDiagnosticScenario()
        scenario.fileSystem = fileSystem
        scenario.add(.available(
            .homebrew,
            executable: prefix + "/bin/brew",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: prefix)],
            items: items
        ))
        return scenario
    }

    private func formula(
        _ name: String,
        installed: [String],
        linked: String? = nil,
        _ details: [String: String] = [:]
    ) -> ManagedItem {
        ManagedItem(
            id: try! PackageID(.brew, name), kind: .formula, displayName: name,
            installedVersions: installed.map { InstalledVersion($0) },
            activeVersion: linked.map { InstalledVersion($0) },
            details: details
        )
    }

    /// The owner's Mac: an upgrade of mysql stopped part-way, leaving an empty
    /// 26.7.0_2 folder, no linked version, and opt/mysql still at 9.7.1. Read
    /// through the real provider, so the finding is about what MacUp records.
    @Test("An interrupted upgrade: what happened, and the repair in the only safe order")
    func interruptedUpgrade() async throws {
        let harness = ProviderHarness(path: Self.prefix + "/bin:/usr/bin:/bin")
        let rack = Self.prefix + "/Cellar/mysql"
        harness.fileSystem.addExecutable(Self.prefix + "/bin/brew")
        for directory in [Self.prefix + "/Cellar", Self.prefix + "/opt", rack, rack + "/9.7.1", rack + "/26.7.0_2", Self.prefix + "/Cellar/jq", Self.prefix + "/Cellar/jq/1.8.1"] {
            harness.fileSystem.addDirectory(directory)
        }
        harness.fileSystem.addFile(rack + "/9.7.1/INSTALL_RECEIPT.json", contents: "{}")
        harness.fileSystem.addFile(Self.prefix + "/Cellar/jq/1.8.1/INSTALL_RECEIPT.json", contents: "{}")
        harness.fileSystem.addSymlink(Self.prefix + "/opt/mysql", to: "../Cellar/mysql/9.7.1")
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        harness.runner.register("brew", ["--prefix"], .success(Self.prefix + "\n"))
        harness.runner.register("brew", HomebrewProvider.installedInfoArguments, .success(try Fixture.text("homebrew/info-interrupted.json")))
        let items = try await HomebrewProvider().inventory(context: try await harness.detectedContext(HomebrewProvider())).elements

        let findings = await check.run(scenario(items, fileSystem: harness.fileSystem).input)
        #expect(findings.map(\.id) == ["homebrew.unfinishedInstall", "homebrew.notLinked", "homebrew.buildsFromSource"])

        let unfinished = findings[0]
        #expect(unfinished.severity == .warning)
        #expect(unfinished.title == "An install of mysql did not finish")
        #expect(unfinished.detail?.contains("~/.homebrew/Cellar/mysql/26.7.0_2 has none, so that install stopped part-way.") == true)
        #expect(unfinished.detail?.contains("The folder is empty.") == true)
        #expect(unfinished.detail?.contains("~/.homebrew/opt/mysql points at 9.7.1, whose install finished.") == true)
        let steps = try #require(unfinished.recommendation?.components(separatedBy: "\n"))
        #expect(steps.count == 4)
        #expect(steps[0] == "To repair it yourself:")
        #expect(steps[1] == "1. In Finder, choose Go > Go to Folder, enter ~/.homebrew/Cellar/mysql, and move the 26.7.0_2 folder to the Trash.")
        #expect(steps[2].hasPrefix("2. Then run `brew link mysql`, which links 9.7.1 again"))
        #expect(steps[3].contains("Run `brew link` first and Homebrew links the newest folder, which is the unfinished one, and points ~/.homebrew/opt/mysql at it"))
        #expect(!(unfinished.detail ?? "").contains("/Users/example"), "the home directory is shown as ~")

        let unlinked = findings[1]
        #expect(unlinked.severity == .warning)
        #expect(unlinked.title == "mysql is installed but not linked")
        #expect(unlinked.detail?.contains("its commands are not on your PATH") == true)
        #expect(unlinked.recommendation?.hasPrefix("Do not run `brew link` yet") == true)

        let source = findings[2]
        #expect(source.severity == .info)
        #expect(source.detail?.contains("This Homebrew is in ~/.homebrew.") == true)
        #expect(source.detail?.contains("made for /opt/homebrew") == true)
        #expect(source.detail?.hasSuffix("upgrades them: mysql.") == true, "jq's ready-made build pours anywhere")
        #expect(harness.requests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("A linked formula with a leftover unfinished folder needs only the folder moved")
    func linkedWithLeftover() async {
        let item = formula("wget", installed: ["1.24.5", "1.25.0"], linked: "1.24.5", ["incompleteVersions": "1.25.0", "optVersion": "1.24.5"])
        let findings = await check.run(scenario([item]).input)
        #expect(findings.map(\.id) == ["homebrew.unfinishedInstall"])
        #expect(findings[0].recommendation == "To repair it yourself: in Finder, choose Go > Go to Folder, enter ~/.homebrew/Cellar/wget, and move the 1.25.0 folder to the Trash.")
    }

    @Test("With no finished version left, the repair ends with installing it again")
    func nothingFinished() async {
        let item = formula("tool", installed: ["2.0"], ["incompleteVersions": "2.0"])
        let findings = await check.run(scenario([item]).input)
        #expect(findings.map(\.id) == ["homebrew.unfinishedInstall"], "nothing finished to link, so no second finding")
        #expect(findings[0].recommendation?.contains("2. No finished version of tool is left, so if you still want it, install it again with `brew install tool`.") == true)
    }

    @Test("A keg-only formula whose opt link points at the unfinished folder needs a finished version put back")
    func kegOnlyOptBroken() async {
        let item = formula("openssl@3", installed: ["3.6.3", "3.6.4"], ["incompleteVersions": "3.6.4", "optVersion": "3.6.4", "kegOnly": "true"])
        let findings = await check.run(scenario([item]).input)
        #expect(findings.map(\.id) == ["homebrew.unfinishedInstall"])
        #expect(findings[0].detail?.contains("points at the unfinished folder") == true)
        #expect(findings[0].recommendation?.contains("`brew reinstall openssl@3` installs one") == true)
    }

    @Test("Not linked, for three different reasons")
    func notLinked() async {
        let findings = await check.run(scenario([
            formula("jq", installed: ["1.8.1"], ["installedOnRequest": "true"]),
            formula("python@3.12", installed: ["3.12.8"], ["installedOnRequest": "true"]),
            formula("python@3.13", installed: ["3.13.1"], linked: "3.13.1"),
            formula("libyaml", installed: ["0.2.5"], ["installedOnRequest": "false"]),
            formula("readline", installed: ["8.3"], ["kegOnly": "true"]),
        ], prefix: "/opt/homebrew").input)
        let byTitle = Dictionary(uniqueKeysWithValues: findings.map { ($0.title, $0) })
        #expect(findings.count == 3, "keg-only formulae are never linked, on purpose")

        let jq = byTitle["jq is installed but not linked"]
        #expect(jq?.severity == .warning)
        #expect(jq?.recommendation == "If you did not unlink it on purpose, run `brew link jq` to put its commands back on your PATH.")

        let python = byTitle["python@3.12 is installed but not linked"]
        #expect(python?.severity == .info)
        #expect(python?.detail?.hasSuffix("python@3.13 is linked instead.") == true)
        #expect(python?.recommendation?.contains("run `brew unlink python@3.13` and then `brew link python@3.12`") == true)

        #expect(byTitle["libyaml is installed but not linked"]?.severity == .info, "a dependency is used through opt, not PATH")
    }

    @Test("A name a shell would read differently is never put in a command to copy")
    func unusualName() async {
        let findings = await check.run(scenario([formula("to;ol", installed: ["1.0"], ["installedOnRequest": "true"])]).input)
        #expect(findings.first?.recommendation == "If you did not unlink it on purpose, link it with Homebrew to put its commands back on your PATH.")
    }

    @Test("In Homebrew's usual location, or with no ready-made build at all, nothing is said about building from source")
    func sourceBuildsOnlyForTheLocation() async {
        let mysql = formula("mysql", installed: ["9.7.1"], linked: "9.7.1", ["buildsFromSource": "true", "bottleCellars": "/opt/homebrew/Cellar"])
        #expect(await check.run(scenario([mysql], prefix: "/opt/homebrew").input).isEmpty)
        let binaryOnly = formula("example/tap/tool", installed: ["1.0"], linked: "1.0", ["buildsFromSource": "true", "bottleCellars": ""])
        #expect(await check.run(scenario([binaryOnly]).input).isEmpty)
    }

    @Test("Nothing to say about a healthy Homebrew, or one that was not checked")
    func quietOtherwise() async {
        #expect(await check.run(scenario([formula("jq", installed: ["1.8.1"], linked: "1.8.1")]).input).isEmpty)
        var none = DoctorDiagnosticScenario()
        none.add(.notInstalled(.homebrew))
        #expect(await check.run(none.input).isEmpty)
    }

    @Test("Doctor runs this check")
    func registered() {
        #expect(DoctorEngine.standard().checks.contains { $0.id == "homebrew.state" })
    }
}
