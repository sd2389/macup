import Darwin
import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Export Diagnostics in the app")
@MainActor
struct AppModelDiagnosticsTests {
    /// Opens the sheet and waits for what goes in it.
    private func gathered(_ harness: AppModelHarness) async throws -> DiagnosticsExport {
        harness.model.beginDiagnosticsExport()
        let export = try #require(harness.model.diagnosticsExport)
        await export.waitUntilGathered()
        return export
    }

    @Test("Opening the sheet gathers a preview, with package names as placeholders")
    func previewMasksNames() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["secret-tool"]))
        let export = try await gathered(harness)

        #expect(!export.isGathering)
        #expect(export.packageNames == .placeholders)
        #expect(export.preview.contains("\"brew:package-1\""))
        #expect(!export.preview.contains("secret-tool"))
        #expect(export.leftOut == DiagnosticsDocument.leftOut(packageNames: .placeholders))
        #expect(export.included == DiagnosticsDocument.included(packageNames: .placeholders))
        #expect(export.suggestedFileName.hasPrefix("macup-diagnostics-"))
    }

    @Test("Include package names shows them and hides them again, without checking the Mac twice")
    func togglingNames() async throws {
        let provider = StubCheckProvider(updateNames: ["secret-tool"])
        let harness = try AppModelHarness(provider: provider)
        let export = try await gathered(harness)
        let detections = provider.detections

        export.setIncludesPackageNames(true)
        #expect(export.preview.contains("\"brew:secret-tool\""))
        #expect(export.leftOut == DiagnosticsDocument.leftOut(packageNames: .included))
        export.setIncludesPackageNames(false)
        #expect(!export.preview.contains("secret-tool"))
        #expect(provider.detections == detections)
    }

    @Test("Save writes exactly the text the preview shows, readable only by its owner")
    func saveWritesThePreview() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["secret-tool"]))
        let export = try await gathered(harness)
        let url = harness.home.url.appendingPathComponent("diagnostics.json")

        #expect(export.save(to: url))
        #expect(try Data(contentsOf: url) == export.content)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == export.preview)
        var info = stat()
        #expect(lstat(url.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(export.savedPath == url.path)
        #expect(export.problem == nil)
    }

    @Test("Save never replaces a file, and says why")
    func saveRefusesToOverwrite() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["secret-tool"]))
        let export = try await gathered(harness)
        let url = harness.home.url.appendingPathComponent("diagnostics.json")
        try Data("keep me".utf8).write(to: url)

        #expect(!export.save(to: url))
        #expect(export.problem?.contains("already exists. MacUp never replaces a file") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "keep me")
        #expect(export.savedPath == nil)
    }

    @Test("Save will not write through a symbolic link")
    func saveRefusesSymbolicLink() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["secret-tool"]))
        let export = try await gathered(harness)
        let target = harness.home.url.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: target)
        let link = harness.home.url.appendingPathComponent("link.json")
        #expect(symlink(target.path, link.path) == 0)

        #expect(!export.save(to: link))
        #expect(export.problem?.contains("is a symbolic link") == true)
        #expect(try String(contentsOf: target, encoding: .utf8) == "target")
    }

    @Test("Closing the sheet while it gathers stops it, and nothing gathered is shown")
    func closingWhileGathering() async throws {
        let provider = StubCheckProvider(updateNames: ["secret-tool"])
        let rendezvous = Rendezvous()
        provider.detectRendezvous = rendezvous
        let harness = try AppModelHarness(provider: provider)

        harness.model.beginDiagnosticsExport()
        let export = try #require(harness.model.diagnosticsExport)
        await rendezvous.waitUntilReached()
        #expect(export.isGathering)
        harness.model.endDiagnosticsExport()
        rendezvous.open()
        await export.waitUntilGathered()

        #expect(harness.model.diagnosticsExport == nil)
        #expect(export.snapshot == nil)
        #expect(export.content == nil)
    }

    @Test("Gathering runs nothing that changes the Mac")
    func gatheringOnlyReads() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["secret-tool"]))
        _ = try await gathered(harness)

        #expect(harness.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
        let attempted = Set(harness.launchedExecutables.map { ($0 as NSString).lastPathComponent })
        #expect(attempted.subtracting(["zsh", "bash", "sh", "fish"]).isEmpty)
    }

    @Test("The shell's environment never reaches the file, and the home folder is ~")
    func noEnvironmentVariables() async throws {
        // Assembled at runtime so secret scanners do not flag this file.
        let token = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        let harness = try AppModelHarness(
            provider: StubCheckProvider(updateNames: ["secret-tool"]),
            loginShell: FakeLoginShell(result: [
                "PATH": "/usr/bin:/bin",
                "GITHUB_TOKEN": token,
                "OKAPI_PROJECT": "launch-codename-okapi",
            ])
        )
        let export = try await gathered(harness)
        export.setIncludesPackageNames(true)

        #expect(!export.preview.contains(token))
        #expect(!export.preview.contains("launch-codename-okapi"))
        #expect(!export.preview.contains("OKAPI_PROJECT"))
        #expect(!export.preview.contains(harness.home.canonicalPath))
        #expect(export.preview.contains("~/.config/macup/config.json"))
    }
}
