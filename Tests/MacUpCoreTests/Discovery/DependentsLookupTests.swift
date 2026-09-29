import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Dependents lookup")
struct DependentsLookupTests {
    static let info = """
        {"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.43.0", "installed_on_request": true}], "linked_keg": "2.43.0"},
                      {"name": "openssl@3", "full_name": "openssl@3", "installed": [{"version": "3.6.3", "installed_on_request": false}], "linked_keg": "3.6.3"}],
         "casks": []}
        """
    static let outdated = """
        {"formulae": [{"name": "openssl@3", "installed_versions": ["3.6.3"], "current_version": "3.6.4", "pinned": false}], "casks": []}
        """
    let openssl = try! PackageID(.brew, "openssl@3")
    let lookup = DependentsLookup(providers: [HomebrewProvider(), NpmProvider()])

    private func machine(uses: FakeCommandRunner.Response = .success("git\n")) -> (runner: FakeCommandRunner, environment: CheckEnvironment) {
        let runner = FakeCommandRunner()
        let fileSystem = FakeFileSystem()
        fileSystem.addExecutable("/opt/homebrew/bin/brew")
        runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        runner.register("brew", HomebrewProvider.installedInfoArguments, .success(Self.info))
        runner.register("brew", ["outdated", "--json=v2"], .success(Self.outdated))
        for casks in [false, true] {
            runner.register("brew", HomebrewProvider.dependentsArguments(of: "openssl@3", casks: casks), casks ? .success() : uses)
        }
        let environment = CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": "/Users/example"],
            homeDirectory: "/Users/example",
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
        )
        return (runner, environment)
    }

    private var defaults: LoadedConfiguration {
        LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/Users/example/.config/macup/config.json")
    }

    @Test("On its own it finds Homebrew, confirms the formula is installed, and asks, all read-only")
    func standalone() async throws {
        let (runner, environment) = machine()
        let report = await lookup.run(openssl, configuration: defaults, environment: environment)
        #expect(report.outcome == .listed)
        #expect(report.dependents == [try PackageID(.brew, "git")])
        #expect(report.kind == "dependents")
        #expect(report.schemaVersion == 1)
        #expect(runner.recordedInvocations.map(\.arguments).contains(HomebrewProvider.installedInfoArguments))
        #expect(report.commands.allSatisfy { $0.effect == .readOnly && $0.outcome == .exited })
    }

    @Test("After a check it reuses what the check found, and detects nothing again")
    func afterCheck() async throws {
        let (runner, environment) = machine()
        let check = await CheckEngine(providers: [HomebrewProvider()]).run(configuration: defaults, environment: environment)
        #expect(!runner.recordedRequests.contains { $0.arguments.first == "uses" }, "a check never asks what depends on anything")
        let before = runner.recordedRequests.count

        let report = await lookup.run(openssl, configuration: defaults, environment: environment, after: check)
        #expect(report.outcome == .listed)
        #expect(runner.recordedRequests.dropFirst(before).map(\.arguments).allSatisfy { $0.first == "uses" })
    }

    @Test("A formula Homebrew does not list as installed is not asked about")
    func notInstalled() async throws {
        let (runner, environment) = machine()
        let report = await lookup.run(try PackageID(.brew, "wget"), configuration: defaults, environment: environment)
        #expect(report.outcome == .notInstalled)
        #expect(report.dependents == nil)
        #expect(report.error?.message.contains("does not list brew:wget as installed") == true)
        #expect(!runner.recordedRequests.contains { $0.arguments.first == "uses" })
    }

    @Test("Something other than a formula is refused before anything runs", arguments: ["npm:typescript", "brew-cask:firefox", "mise:node"])
    func unsupported(id: String) async throws {
        let (runner, environment) = machine()
        let report = await lookup.run(try PackageID(parsing: id), configuration: defaults, environment: environment)
        #expect(report.outcome == .unsupported)
        #expect(report.error?.kind == .unsupported)
        #expect(runner.recordedRequests.isEmpty)
        #expect(!lookup.canList(try PackageID(parsing: id)))
    }

    @Test("Homebrew turned off in MacUp is not asked")
    func disabledProvider() async throws {
        let (runner, environment) = machine()
        var configuration = MacUpConfiguration.defaults
        configuration.providers["homebrew"] = MacUpConfiguration.ProviderSettings(enabled: false)
        let loaded = LoadedConfiguration(configuration: configuration, source: .file, path: "/Users/example/.config/macup/config.json")
        let report = await lookup.run(openssl, configuration: loaded, environment: environment)
        #expect(report.outcome == .failed)
        #expect(report.error?.message.contains("turned off") == true)
        #expect(runner.recordedRequests.isEmpty)
    }

    @Test("A failed answer is a failure with the reason, never an empty list")
    func failed() async throws {
        let (_, environment) = machine(uses: .exit(1, standardError: "Error: broken\n"))
        let report = await lookup.run(openssl, configuration: defaults, environment: environment)
        #expect(report.outcome == .failed)
        #expect(report.dependents == nil)
        #expect(report.error?.kind == .commandFailed)
    }

    @Test("Cancelling stops the question and says so")
    func cancelled() async throws {
        let (runner, environment) = machine(uses: FakeCommandRunner.Response(standardOutput: "git\n", delay: .seconds(30)))
        let lookup = lookup
        let openssl = openssl
        let defaults = defaults
        let task = Task { await lookup.run(openssl, configuration: defaults, environment: environment) }
        while !runner.recordedRequests.contains(where: { $0.arguments.first == "uses" }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let report = await task.value
        #expect(report.outcome == .cancelled)
        #expect(report.dependents == nil)
    }

    @Test("The report encodes with a versioned kind and package IDs as strings")
    func encoding() async throws {
        let (_, environment) = machine()
        let report = await lookup.run(openssl, configuration: defaults, environment: environment)
        let object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["kind"] as? String == "dependents")
        #expect(object["item"] as? String == "brew:openssl@3")
        #expect(object["dependents"] as? [String] == ["brew:git"])
        #expect(object["outcome"] as? String == "listed")
    }
}
