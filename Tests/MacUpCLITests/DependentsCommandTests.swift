import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import macup

@Suite("macup dependents")
struct DependentsCommandTests {
    private func harness(formulae: FakeCommandRunner.Response = .success("aws-c-auth\nkrb5\n"), casks: FakeCommandRunner.Response = .success()) throws -> CLIHarness {
        let harness = try CLIHarness()
        harness.runner.register("brew", ["uses", "--installed", "--formula", "mysql"], formulae)
        harness.runner.register("brew", ["uses", "--installed", "--cask", "mysql"], casks)
        return harness
    }

    @Test("Lists what needs the formula, says what an upgrade does to them, and changes nothing")
    func lists() async throws {
        let harness = try harness(casks: .success("mysql-workbench\n"))
        let run = try await harness.run(["dependents", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("MacUp dependents · read-only · nothing was changed"))
        #expect(run.standardOutput.contains("3 installed items need mysql, directly or through another formula:"))
        #expect(run.standardOutput.contains("  brew-cask:mysql-workbench\n  brew:aws-c-auth\n  brew:krb5"))
        #expect(run.standardOutput.contains("it asks Homebrew to leave these alone rather than upgrade or rebuild them"))
        #expect(harness.modifyingRequests.isEmpty)
    }

    @Test("Nothing depends on it, said plainly")
    func nothing() async throws {
        let run = try await harness(formulae: .success()).run(["dependents", "brew:mysql"])
        #expect(run.exitCode == nil)
        #expect(run.standardOutput.contains("Nothing installed with Homebrew needs mysql."))
    }

    @Test("--json is a versioned report")
    func json() async throws {
        let run = try await harness().run(["dependents", "brew:mysql", "--json"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(run.standardOutput.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["kind"] as? String == "dependents")
        #expect(object["outcome"] as? String == "listed")
        #expect(object["dependents"] as? [String] == ["brew:aws-c-auth", "brew:krb5"])
    }

    @Test("--verbose shows every command, all read-only")
    func verbose() async throws {
        let run = try await harness().run(["dependents", "brew:mysql", "--verbose"])
        #expect(run.standardOutput.contains("Commands MacUp ran (all read-only):"))
        #expect(run.standardOutput.contains("/opt/homebrew/bin/brew uses --installed --formula mysql"))
    }

    @Test(
        "Something MacUp cannot ask about is a usage error that says why",
        arguments: [
            ("npm:typescript", "can only ask what depends on a Homebrew formula"),
            ("brew:wget", "does not list brew:wget as installed"),
        ]
    )
    func usageErrors(item: String, message: String) async throws {
        let harness = try harness()
        let run = try await harness.run(["dependents", item])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(run.standardOutput.contains(message))
        #expect(!harness.runner.recordedRequests.contains { $0.arguments.first == "uses" })
    }

    @Test("Not a package ID at all is refused before anything runs")
    func notAnID() async throws {
        let harness = try harness()
        let run = try await harness.run(["dependents", "mysql"])
        #expect(run.exitCode == MacUpExitCode.usage.rawValue)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("When Homebrew cannot answer, MacUp says so and exits 2, never claiming nothing depends on it")
    func failure() async throws {
        let run = try await harness(formulae: .exit(1, standardError: "Error: broken\n")).run(["dependents", "brew:mysql"])
        #expect(run.exitCode == MacUpExitCode.providerErrors.rawValue)
        #expect(run.standardOutput.contains("error: `brew uses` failed"))
        #expect(!run.standardOutput.contains("Nothing installed"))
    }

    @Test("A normal check never asks what depends on anything")
    func checkNeverAsks() async throws {
        let harness = try harness()
        _ = try await harness.run(["check", "--verbose"])
        #expect(!harness.runner.recordedRequests.contains { $0.arguments.first == "uses" })
    }
}
