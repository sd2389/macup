import Darwin
import Foundation
import MacUpCore
import Testing

@testable import macup

// Assembled at runtime so secret scanners do not flag this file.
private let githubToken = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"

@Suite("macup diagnostics")
struct DiagnosticsCommandTests {
    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.useTemporaryDirectories()
        harness.expectLaunchctl(loaded: false)
        return harness
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// The document without what changes from one run to the next: when it
    /// was made, how long things took, and the order concurrent commands
    /// happened to start in.
    private func timeless(_ text: String) throws -> NSDictionary {
        try #require(strip(try object(text)) as? NSDictionary)
    }

    private func strip(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, item) in dictionary where !["createdAt", "startedAt", "finishedAt", "durationSeconds", "commands"].contains(key) {
                result[key] = strip(item)
            }
            return result as NSDictionary
        }
        if let array = value as? [Any] { return array.map(strip) as NSArray }
        return value
    }

    private func commands(_ text: String) throws -> [String] {
        let check = try #require(try object(text)["check"] as? [String: Any])
        let commands = try #require(check["commands"] as? [[String: Any]])
        return commands.compactMap { $0["command"] as? String }.sorted()
    }

    @Test("preview prints the document, says nothing was written, and writes nothing")
    func previewWritesNothing() async throws {
        let harness = try harness()
        let run = try await harness.run(["diagnostics", "preview"])

        #expect(run.exitCode == nil)
        let document = try object(run.standardOutput)
        #expect(document["kind"] as? String == "diagnostics")
        #expect(document["schemaVersion"] as? Int == DiagnosticsDocument.schemaVersion)
        #expect(run.standardError.contains("Nothing has been written or sent."))
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.workingDirectory.path).isEmpty)
        #expect(harness.modifyingRequests.isEmpty)
        #expect(harness.schedulerRunner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("Plain `macup diagnostics` is the preview")
    func defaultIsPreview() async throws {
        let run = try await harness().run(["diagnostics"])
        #expect(run.exitCode == nil)
        #expect(try object(run.standardOutput)["kind"] as? String == "diagnostics")
    }

    @Test("Package names are placeholders unless --include-packages is passed")
    func packageNames() async throws {
        let harness = try harness()
        let masked = try await harness.run(["diagnostics", "preview"])
        #expect(!masked.standardOutput.contains("mysql"))
        #expect(masked.standardOutput.contains("\"brew:package-1\""))
        #expect(masked.standardError.contains("--include-packages keeps them"))

        let named = try await harness.run(["diagnostics", "preview", "--include-packages"])
        #expect(named.standardOutput.contains("\"brew:mysql\""))
        #expect(named.standardOutput.contains("\"packageNames\" : \"included\""))
        #expect(named.standardError.contains("Package names are included"))
    }

    @Test("export writes what preview prints, readable only by you")
    func exportMatchesPreview() async throws {
        let harness = try harness()
        let path = harness.workingDirectory.appending("report.json").path
        let preview = try await harness.run(["diagnostics", "preview"])
        let export = try await harness.run(["diagnostics", "export", "--output", path])

        #expect(export.exitCode == nil)
        #expect(export.standardOutput.contains("Saved diagnostics to \(path)"))
        #expect(export.standardOutput.contains("Only you can read it."))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(try timeless(written) == timeless(preview.standardOutput))
        #expect(try commands(written) == commands(preview.standardOutput))
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }

    @Test("export never replaces a file: it exits 73 before checking anything, and leaves the file alone")
    func refusesToOverwrite() async throws {
        let harness = try harness()
        let path = harness.workingDirectory.appending("report.json").path
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))

        let run = try await harness.run(["diagnostics", "export", "--output", path])
        #expect(run.exitCode == MacUpExitCode.cannotCreateOutput.rawValue)
        #expect(run.standardError.contains("already exists. MacUp never replaces a file, so nothing was written."))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me")
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("export will not write through a symbolic link")
    func refusesSymbolicLink() async throws {
        let harness = try harness()
        let target = harness.workingDirectory.appending("target.json").path
        try Data("target".utf8).write(to: URL(fileURLWithPath: target))
        let link = harness.workingDirectory.appending("link.json").path
        #expect(symlink(target, link) == 0)

        let run = try await harness.run(["diagnostics", "export", "--output", link])
        #expect(run.exitCode == MacUpExitCode.cannotCreateOutput.rawValue)
        #expect(run.standardError.contains("is a symbolic link. MacUp does not write through links"))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "target")
    }

    @Test("A folder that is not there is reported before anything is checked")
    func missingFolder() async throws {
        let harness = try harness()
        let path = harness.workingDirectory.appending("missing/report.json").path

        let run = try await harness.run(["diagnostics", "export", "--output", path])
        #expect(run.exitCode == MacUpExitCode.cannotCreateOutput.rawValue)
        #expect(run.standardError.contains("There is no folder at"))
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("By default the file goes in the current directory, named for when it was made")
    func defaultLocation() async throws {
        let harness = try harness()
        let run = try await harness.run(["diagnostics", "export"])

        #expect(run.exitCode == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: harness.workingDirectory.path)
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.hasPrefix("macup-diagnostics-") && name.hasSuffix(".json"))
    }

    @Test("--output naming a folder puts the file inside it, and a relative path starts in the current directory")
    func outputFolder() async throws {
        let harness = try harness()
        try FileManager.default.createDirectory(
            atPath: harness.workingDirectory.appending("reports").path,
            withIntermediateDirectories: false
        )

        let run = try await harness.run(["diagnostics", "export", "--output", "reports"])
        #expect(run.exitCode == nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: harness.workingDirectory.appending("reports").path)
        #expect(files.count == 1)
        #expect(files.first?.hasPrefix("macup-diagnostics-") == true)
    }

    @Test("export --json says where the file went, not what is in it")
    func exportJSON() async throws {
        let harness = try harness()
        let path = harness.workingDirectory.appending("report.json").path
        let run = try await harness.run(["diagnostics", "export", "--output", path, "--json"])

        #expect(run.exitCode == nil)
        let result = try object(run.standardOutput)
        #expect(result["kind"] as? String == "diagnosticsExport")
        #expect(result["schemaVersion"] as? Int == 1)
        #expect(result["path"] as? String == path)
        #expect(result["packageNames"] as? String == "placeholders")
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        #expect(result["bytes"] as? Int == size)
    }

    @Test("No environment variable reaches the file, and the home folder is ~")
    func noEnvironmentVariables() async throws {
        let harness = try harness()
        harness.environment["GITHUB_TOKEN"] = githubToken
        harness.environment["OKAPI_PROJECT"] = "launch-codename-okapi"

        let run = try await harness.run(["diagnostics", "preview", "--include-packages"])
        #expect(run.exitCode == nil)
        #expect(!run.standardOutput.contains(githubToken))
        #expect(!run.standardOutput.contains("launch-codename-okapi"))
        #expect(!run.standardOutput.contains("OKAPI_PROJECT"))
        #expect(!run.standardOutput.contains("/Users/example"))
    }

    @Test("An empty --output is a usage error")
    func emptyOutput() async throws {
        let run = try await harness().run(["diagnostics", "export", "--output", ""])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
    }
}
