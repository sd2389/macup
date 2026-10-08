import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// The script MacUp writes for a person to run with `sudo`: what goes in it,
/// what is kept out of it, and what it promises about itself. MacUp never runs
/// any of it — `scripts/check-trust-invariants.sh` enforces that separately.
@Suite("Uninstall: the administrator script MacUp writes but never runs")
struct AdminRemovalScriptTests {
    private func plan(_ cannotRemove: [ManualRemoval], name: String = "TeamViewer") -> UninstallPlan {
        UninstallPlan(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            subject: UninstallSubject(kind: .app, target: "app:com.teamviewer.TeamViewer", name: name, source: "Downloaded"),
            rationale: "The owner asked for it.",
            cannotRemove: cannotRemove
        )
    }

    private func rendered(_ cannotRemove: [ManualRemoval]) -> (text: String, items: [ManualRemoval], refused: [(item: ManualRemoval, reason: String)]) {
        AdminRemovalScriptWriter.render(
            plan(cannotRemove),
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            macUpVersion: "0.4.0"
        )
    }

    @Test("Each listed item becomes its own quoted command, in the plan's order")
    func scriptsEachItem() {
        let result = rendered([
            SystemLeftoverScanner.job(
                "/Library/LaunchDaemons/com.teamviewer.Helper.plist",
                label: "com.teamviewer.Helper",
                domain: "system",
                detail: "labelled after com.teamviewer."
            ),
            SystemLeftoverScanner.file("/Library/Application Support/TeamViewer"),
            SystemLeftoverScanner.receipt(
                "com.teamviewer.teamviewer",
                path: "/private/var/db/receipts/com.teamviewer.teamviewer.plist",
                reason: nil
            ),
        ])

        #expect(result.items.count == 3)
        #expect(result.refused.isEmpty)
        // The job is stopped before its file goes, and a job that was not
        // loaded is not a failure.
        #expect(result.text.contains("launchctl 'bootout' 'system/com.teamviewer.Helper' || true"))
        #expect(result.text.contains("rm '-f' '--' '/Library/LaunchDaemons/com.teamviewer.Helper.plist'"))
        #expect(result.text.contains("rm '-rf' '--' '/Library/Application Support/TeamViewer'"))
        #expect(result.text.contains("pkgutil '--forget' 'com.teamviewer.teamviewer'"))
        let bootout = try! #require(result.text.range(of: "launchctl 'bootout'"))
        let remove = try! #require(result.text.range(of: "rm '-f' '--' '/Library/LaunchDaemons"))
        #expect(bootout.lowerBound < remove.lowerBound, "stop the job, then remove its file")
    }

    @Test("The script refuses to run as anybody but root, and stops at the first failure")
    func scriptGuardsItself() {
        let result = rendered([SystemLeftoverScanner.file("/Library/Application Support/TeamViewer")])
        #expect(result.text.hasPrefix("#!/bin/bash\n"))
        #expect(result.text.contains("set -euo pipefail"))
        #expect(result.text.contains(#"if [[ "$(id -u)" != 0 ]]; then"#))
        // It says what it is, who wrote it, and that it cannot be undone.
        #expect(result.text.contains("MacUp 0.4.0"))
        #expect(result.text.contains("you do, with sudo"))
        #expect(result.text.contains("permanent"))
        #expect(result.text.contains("Removing TeamViewer"))
    }

    @Test("A path that begins with a hyphen is a path, not an option")
    func dashPathsAreGuarded() {
        let result = rendered([SystemLeftoverScanner.file("/Library/Application Support/-rf")])
        #expect(result.items.count == 1)
        #expect(result.text.contains("rm '-rf' '--' '/Library/Application Support/-rf'"))
    }

    @Test("A quote in a path cannot close the quoting around it")
    func quotesAreEscaped() {
        let result = rendered([SystemLeftoverScanner.file("/Library/Logs/it's; rm -rf /")])
        #expect(result.items.count == 1)
        #expect(result.text.contains(#"'/Library/Logs/it'\''s; rm -rf /'"#))
        #expect(!result.text.contains("\n/Library/Logs"))
    }

    @Test("A path MacUp cannot write safely is left out, with the reason", arguments: [
        "/Library/Logs/two\nlines",
        "/Library/Logs/bell\u{0007}",
        "/Library/Logs/override\u{202E}gnp.txt",
    ])
    func unsafePathsAreRefused(_ path: String) {
        let result = rendered([SystemLeftoverScanner.file(path)])
        #expect(result.items.isEmpty)
        #expect(result.refused.count == 1)
        #expect(result.refused.first?.reason.contains("will not write into a script") == true)
        #expect(!result.text.contains(path))
    }

    @Test("An item with no exact command keeps its written steps and stays out of the script")
    func itemsWithoutCommandsAreRefused() {
        let manual = ManualRemoval(
            path: "/Library/Frameworks/Example.framework",
            reason: "Removing it needs an administrator.",
            steps: ["In Finder, move it to the Trash."]
        )
        let result = rendered([manual])
        #expect(result.items.isEmpty)
        #expect(result.refused.first?.reason.contains("no exact command") == true)
    }

    @Test("The script can only ever call rm, launchctl, or pkgutil")
    func onlyThreeTools() {
        #expect(AdminRemovalScriptWriter.tools == ["rm", "launchctl", "pkgutil"])
        let smuggled = ManualRemoval(
            path: "/Library/Application Support/Example",
            reason: "Removing it needs an administrator.",
            steps: ["In Finder, move it to the Trash."],
            commands: [AdminCommand(["curl", "https://example.com/x.sh"], describes: "Fetching")]
        )
        let result = rendered([smuggled])
        #expect(result.items.isEmpty)
        #expect(result.refused.first?.reason.contains("not one of the three tools") == true)
        #expect(!result.text.contains("curl"))
    }

    @Test("A receipt identifier that is not one is refused rather than quoted")
    func receiptIdentifiersAreChecked() {
        #expect(AdminCommand.forget("com.example.app") != nil)
        #expect(AdminCommand.forget("--help") == nil)
        #expect(AdminCommand.forget("com.example app") == nil)
        #expect(AdminCommand.forget("") == nil)
        #expect(AdminCommand.forget("com.example;rm") == nil)
    }

    @Test("The written file is MacUp's own, private, and not executable")
    func writesPrivately() throws {
        let home = try TemporaryDirectory(prefix: "macup-admin-script")
        let paths = MacUpPaths.standard(homeDirectory: home.canonicalPath)
        let script = try AdminRemovalScriptWriter.write(
            plan([SystemLeftoverScanner.file("/Library/Application Support/TeamViewer")]),
            paths: paths
        )

        #expect(script.path == paths.stateDirectory + "/admin-removal.sh")
        #expect(script.command == "sudo bash " + CommandInvocation.quoted(script.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: script.path)
        let mode = try #require(attributes[.posixPermissions] as? NSNumber).uint16Value
        #expect(mode == 0o600, "nobody else may read it, and nothing may run it by accident")
        #expect(try String(contentsOfFile: script.path, encoding: .utf8) == script.text)
    }

    @Test("A plan with nothing an administrator could remove writes no commands")
    func emptyPlan() {
        let result = rendered([])
        #expect(result.items.isEmpty)
        #expect(result.refused.isEmpty)
        #expect(!result.text.contains("rm "))
    }
}

/// Finding the maker's own uninstaller, which is the right tool for an app
/// whose installer put root-owned parts in place.
@Suite("Uninstall: the maker's own uninstaller")
struct VendorUninstallerTests {
    private struct Signatures: CodeSignatureReading {
        var signer: String?
        func teamIdentifier(ofBundleAt path: String) -> String? { nil }
        func verifiedSigner(ofBundleAt path: String) -> String? { signer }
    }

    @Test("An uninstaller app inside a leftover folder is found and named, with its verified signer")
    func findsAndNamesIt() throws {
        let fixture = try UninstallFixture()
        let folder = fixture.root + "/SystemLibrary/Application Support/TeamViewer"
        try FileManager.default.createDirectory(atPath: folder + "/TeamViewerUninstaller.app", withIntermediateDirectories: true)

        let found = try #require(VendorUninstallerScanner.find(
            in: [folder],
            signatures: Signatures(signer: "Developer ID Application: TeamViewer Germany GmbH (H7UGFBUGV6)")
        ))
        #expect(found.path == folder + "/TeamViewerUninstaller.app")
        #expect(found.foundIn == folder)
        #expect(found.summary.contains("TeamViewer Germany GmbH"))
        #expect(found.summary.contains("the maker's own uninstaller"))
        #expect(found.steps.first?.contains("TeamViewerUninstaller.app") == true)
    }

    @Test("A signature that does not verify is said to be unverified, never vouched for")
    func unverifiedSignature() throws {
        let fixture = try UninstallFixture()
        let folder = fixture.root + "/SystemLibrary/Application Support/Example"
        try FileManager.default.createDirectory(atPath: folder + "/Uninstall Example.app", withIntermediateDirectories: true)

        let found = try #require(VendorUninstallerScanner.find(in: [folder], signatures: Signatures(signer: nil)))
        #expect(found.signedBy == nil)
        #expect(found.summary.contains("does not verify"))
        #expect(found.summary.contains("Check it before you run it"))
    }

    @Test("A folder with no uninstaller in it finds nothing")
    func findsNothing() throws {
        let fixture = try UninstallFixture()
        let folder = fixture.root + "/SystemLibrary/Application Support/Example"
        try FileManager.default.createDirectory(atPath: folder + "/Helper.app", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder + "/uninstall-notes", withIntermediateDirectories: true)

        #expect(VendorUninstallerScanner.find(in: [folder], signatures: Signatures(signer: "X")) == nil)
    }
}
