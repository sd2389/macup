import Foundation
import MacUpCore
import Testing

@testable import macup

@Suite("macup provider scan")
struct ProviderScanCommandTests {
    /// The harness has Homebrew and softwareupdate; this adds two tools
    /// MacUp does not manage, one of which refuses to say its version.
    private func harness() throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.fileSystem
            .addExecutable("/opt/homebrew/bin/pipx")
            .addExecutable("/opt/homebrew/bin/cargo")
        harness.runner.register("pipx", ["--version"], .success("1.7.1\n"))
        harness.runner.register("cargo", ["--version"], .exit(1, standardError: "no toolchain\n"))
        return harness
    }

    @Test("It lists what MacUp manages and what it does not, and changes nothing")
    func lists() async throws {
        let harness = try harness()
        let run = try await harness.run(["provider", "scan"])

        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Managed by MacUp"))
        #expect(run.standardOutput.contains("Homebrew"))
        #expect(run.standardOutput.contains("Found, not managed by MacUp"))
        #expect(run.standardOutput.contains("pipx"))
        #expect(run.standardOutput.contains("1.7.1"))
        #expect(run.standardOutput.contains("Python applications"))
        #expect(run.standardOutput.contains("failed, so MacUp has no version"), "cargo is still listed")
        #expect(!run.standardOutput.contains("Looked for, not on this Mac"), "only with --all")
        #expect(harness.modifyingRequests.isEmpty)
        #expect(harness.runner.recordedRequests.allSatisfy { $0.arguments == ["--version"] })
    }

    @Test("--all also names what MacUp looked for and did not find")
    func all() async throws {
        let run = try await harness().run(["provider", "scan", "--all"])
        #expect(run.standardOutput.contains("Looked for, not on this Mac"))
        #expect(run.standardOutput.contains("MacPorts"))
    }

    @Test("--json is the toolScan document, with every tool flattened")
    func json() async throws {
        let run = try await harness().run(["provider", "scan", "--json"])
        let document = try JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any]
        let json = try #require(document)

        #expect(json["kind"] as? String == "toolScan")
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["macupVersion"] as? String == MacUp.version)
        let managed = try #require(json["managed"] as? [[String: Any]])
        #expect(managed.contains { $0["id"] as? String == "homebrew" && $0["managedBy"] as? String == "homebrew" })
        let unmanaged = try #require(json["unmanaged"] as? [[String: Any]])
        let pipx = try #require(unmanaged.first { $0["id"] as? String == "pipx" })
        #expect(pipx["version"] as? String == "1.7.1")
        #expect(pipx["managedBy"] == nil, "nothing claims to manage it")
        #expect(pipx["path"] as? String == "/opt/homebrew/bin/pipx")
        #expect((json["absent"] as? [String])?.contains("nix") == true)
    }
}
