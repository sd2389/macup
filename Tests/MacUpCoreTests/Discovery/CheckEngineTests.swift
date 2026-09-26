import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A pretend Mac with all four providers installed.
final class FakeMac: @unchecked Sendable {
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    var environment = [
        "HOME": "/Users/example",
        "PATH": "/opt/homebrew/bin:/Users/example/.local/bin:/usr/bin:/bin",
        "LANG": "en_US.UTF-8",
    ]

    init(installed: Bool = true) throws {
        guard installed else { return }
        fileSystem
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/opt/homebrew/bin/npm")
            .addExecutable("/opt/homebrew/bin/node")
            .addDirectory("/opt/homebrew/lib/node_modules")
            .addExecutable("/Users/example/.local/bin/mise")
            .addExecutable("/usr/sbin/softwareupdate")
        runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        runner.register("brew", ["outdated", "--json=v2"], .success(try Fixture.text("homebrew/outdated-formula.json")))
        runner.register("brew", ["info", "--json=v2", "--installed"], .success(try Fixture.text("homebrew/info-installed.json")))
        runner.register("npm", ["--version"], .success("11.17.0\n"))
        runner.register("node", ["--version"], .success("v24.19.0\n"))
        runner.register("npm", ["prefix", "-g"], .success("/opt/homebrew\n"))
        runner.register("npm", ["root", "-g"], .success("/opt/homebrew/lib/node_modules\n"))
        runner.register("npm", ["outdated", "-g", "--json"], .exit(1, standardOutput: try npmOutdated))
        runner.register("npm", ["ls", "-g", "--json", "--depth=0"], .success(try Fixture.text("npm/ls-global.json")))
        runner.register("mise", ["--version"], .success("2026.7.3 macos-arm64 (2026-07-08)\n"))
        runner.register("mise", ["outdated", "--json"], .success(try Fixture.text("mise/outdated-global-fuzzy.json")))
        runner.register("mise", ["ls", "--json"], .success(try Fixture.text("mise/ls.json")))
        runner.register("softwareupdate", ["--list", "--no-scan"], .success(try Fixture.text("macos/list-one-update.txt")))
    }

    private var npmOutdated: String {
        get throws {
            try Fixture.text("npm/outdated-global.json").replacingOccurrences(
                of: "/Users/example/.local/share/mise/installs/node/24.19.0/lib/node_modules",
                with: "/opt/homebrew/lib/node_modules"
            )
        }
    }

    var checkEnvironment: CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: environment,
            homeDirectory: "/Users/example",
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }
}

@Suite("Check engine", .timeLimit(.minutes(1)))
struct CheckEngineTests {
    let engine = CheckEngine.standard()
    let defaults = LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/Users/example/.config/macup/config.json")

    private func configuration(_ mutate: (inout MacUpConfiguration) -> Void) -> LoadedConfiguration {
        var configuration = MacUpConfiguration.defaults
        mutate(&configuration)
        return LoadedConfiguration(configuration: configuration, source: .file, path: "/Users/example/.config/macup/config.json")
    }

    @Test("A full read-only check across all providers")
    func fullCheck() async throws {
        let mac = try FakeMac()
        let report = await engine.run(configuration: defaults, environment: mac.checkEnvironment)

        #expect(report.schemaVersion == 1)
        #expect(report.kind == "check")
        #expect(report.mode == .readOnly)
        #expect(!report.cancelled)
        #expect(report.providers.map(\.provider) == [.homebrew, .npm, .mise, .macos])
        #expect(report.providers.allSatisfy { $0.availability == .available && $0.errors.isEmpty })
        #expect(report.providers.map(\.installedCount) == [6, 3, 3, nil])
        #expect(report.providers.map(\.updateCount) == [2, 3, 2, 1])
        #expect(report.updates.map(\.id.rawValue) == [
            "brew:git", "brew:mysql",
            "npm:@anthropic-ai/claude-code", "npm:corepack", "npm:npm",
            "mise:node", "mise:python",
            "macos:macOS 27.2 Beta-26B5091g",
        ])
        #expect(report.summary.updatesAvailable == 8)
        #expect(report.summary.providersChecked == 4)
        #expect(!report.hasProviderErrors)
        #expect(report.providers.allSatisfy { $0.items == nil }, "items only when requested")

        // Read-only, provably: every command was allowlisted and read-only.
        #expect(report.commands.count == mac.runner.recordedRequests.count)
        #expect(report.commands.allSatisfy { $0.effect == .readOnly && $0.outcome == .exited })
        for request in mac.runner.recordedRequests {
            #expect(CommandAllowlist.readOnlyCheck.contains { $0.matches(request) })
        }
    }

    @Test("Disabled providers are reported and never run")
    func disabledProvider() async throws {
        let mac = try FakeMac()
        let report = await engine.run(
            configuration: configuration { $0.providers["mise"] = .init(enabled: false) },
            environment: mac.checkEnvironment
        )
        let mise = try #require(report.providers.first { $0.provider == .mise })
        #expect(mise.availability == .disabled)
        #expect(report.summary.providersDisabled == 1)
        #expect(!mac.runner.recordedRequests.contains { $0.executable.lastPathComponent == "mise" })
    }

    @Test("A provider filter limits the check")
    func providerFilter() async throws {
        let mac = try FakeMac()
        let report = await engine.run(configuration: defaults, options: CheckOptions(providers: [.npm]), environment: mac.checkEnvironment)
        #expect(report.providers.map(\.provider) == [.npm])
        #expect(mac.runner.recordedRequests.allSatisfy { ["npm", "node"].contains($0.executable.lastPathComponent) })
    }

    @Test("Absent providers are handled cleanly: unavailable, not errors")
    func absentProviders() async throws {
        let mac = try FakeMac(installed: false)
        let report = await engine.run(configuration: defaults, environment: mac.checkEnvironment)
        #expect(report.providers.allSatisfy { $0.availability == .unavailable })
        #expect(report.providers.allSatisfy { $0.errors.isEmpty })
        #expect(!report.hasProviderErrors)
        #expect(report.updates.isEmpty)
        #expect(report.commands.isEmpty)
        #expect(report.summary.providersUnavailable == 4)
    }

    @Test("One provider failing does not affect the others")
    func partialFailure() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], .exit(1, standardError: "Error: something broke\n"))
        let report = await engine.run(configuration: defaults, environment: mac.checkEnvironment)
        let homebrew = report.providers[0]
        #expect(homebrew.errors.map(\.operation) == [.outdated])
        #expect(homebrew.updateCount == nil)
        #expect(homebrew.installedCount == 6)
        #expect(report.hasProviderErrors)
        #expect(report.summary.providersWithErrors == 1)
        #expect(report.updates.count == 6)
    }

    @Test("--refresh refreshes Homebrew first and scans for macOS updates")
    func refresh() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["update"], .success("Already up-to-date.\n"))
        mac.runner.register("softwareupdate", ["--list"], .success(try Fixture.text("macos/list-scan-one-update.txt")))
        let report = await engine.run(configuration: defaults, options: CheckOptions(refreshMetadata: true), environment: mac.checkEnvironment)

        #expect(report.mode == .metadataRefresh)
        let brew = mac.runner.recordedRequests.filter { $0.executable.lastPathComponent == "brew" }.map(\.arguments)
        let update = try #require(brew.firstIndex(of: ["update"]))
        let outdated = try #require(brew.firstIndex(of: ["outdated", "--json=v2"]))
        #expect(update < outdated)
        #expect(Set(report.commands.filter { $0.effect == .metadataRefresh }.map(\.command))
            == ["/opt/homebrew/bin/brew update", "/usr/sbin/softwareupdate --list"])
        #expect(mac.runner.recordedRequests.contains { $0.arguments == ["--list"] })
    }

    @Test("A failed refresh is reported and the check continues with local metadata")
    func refreshFailure() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["update"], .exit(1, standardError: "fatal: unable to access GitHub\n"))
        mac.runner.register("softwareupdate", ["--list"], .success(try Fixture.text("macos/list-one-update.txt")))
        let report = await engine.run(configuration: defaults, options: CheckOptions(refreshMetadata: true), environment: mac.checkEnvironment)
        #expect(report.providers[0].errors.map(\.operation) == [.refreshMetadata])
        #expect(report.providers[0].updateCount == 2)
    }

    @Test("Installed items are included only when requested")
    func inventoryItems() async throws {
        let mac = try FakeMac()
        let report = await engine.run(
            configuration: defaults,
            options: CheckOptions(includeInventoryItems: true),
            environment: mac.checkEnvironment
        )
        #expect(report.providers[0].items?.count == 6)
        #expect(report.providers[3].items == nil)
    }

    @Test("Even a misbehaving provider cannot run a modifying command during a check")
    func guardStopsRogueProvider() async throws {
        let mac = try FakeMac()
        let report = await CheckEngine(providers: [RogueProvider()]).run(configuration: defaults, environment: mac.checkEnvironment)
        let errors = report.providers[0].errors
        #expect(errors.map(\.operation) == [.outdated])
        #expect(errors.first?.error.kind == .policyDenied)
        #expect(report.commands.map(\.outcome) == [.refused])
        #expect(report.commands.map(\.command) == ["/opt/homebrew/bin/brew upgrade git"])
        #expect(mac.runner.recordedRequests.isEmpty, "the command never reached the runner")
    }

    @Test("Results keep provider order however long each provider takes")
    func deterministicOrder() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], FakeCommandRunner.Response(
            standardOutput: try Fixture.text("homebrew/outdated-formula.json"),
            delay: .milliseconds(200)
        ))
        let report = await engine.run(configuration: defaults, environment: mac.checkEnvironment)
        #expect(report.providers.map(\.provider) == [.homebrew, .npm, .mise, .macos])
        #expect(report.updates.first?.id.rawValue == "brew:git")
    }

    @Test("Cancelling a check stops in-flight commands and marks the report")
    func cancellation() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], FakeCommandRunner.Response(delay: .seconds(30)))
        let engine = engine
        let defaults = defaults
        let environment = mac.checkEnvironment
        let task = Task { await engine.run(configuration: defaults, environment: environment) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.providers[0].errors.first?.error.kind == .cancelled)
    }

    @Test("Detection-only listing for `macup provider list`")
    func detectOnly() async throws {
        let mac = try FakeMac()
        let result = await engine.detect(
            configuration: configuration { $0.providers["macos"] = .init(enabled: false) },
            environment: mac.checkEnvironment
        )
        #expect(result.providers.map(\.availability) == [.available, .available, .available, .disabled])
        #expect(result.providers[0].version == "7.0.6")
        #expect(!mac.runner.recordedRequests.contains { $0.arguments.first == "outdated" || $0.arguments.first == "ls" })
    }
}

/// A provider that tries to upgrade something while "checking".
private struct RogueProvider: UpdateProvider {
    let id = ProviderID.homebrew
    let capabilities: Set<ProviderCapability> = [.detect, .outdated]

    func detect(context: ProviderContext) async -> ProviderStatus {
        ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(
                executable: ResolvedExecutable(path: "/opt/homebrew/bin/brew", canonicalPath: "/opt/homebrew/bin/brew", source: .searchPath),
                version: "7.0.6"
            )
        )
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> { ProviderListing() }

    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        _ = try await context.runner.run(CommandRequest(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["upgrade", "git"],
            effect: .readOnly
        ))
        return ProviderListing()
    }
}
