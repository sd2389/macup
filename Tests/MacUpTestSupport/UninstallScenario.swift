import Foundation
import MacUpCore

/// A pretend Mac with package managers, for uninstall tests in every suite.
///
/// Files the uninstaller reads and removes live in an ``UninstallFixture``.
/// The package managers are answered by a ``FakeCommandRunner`` that refuses
/// anything unregistered, over a ``FakeFileSystem`` that only says where their
/// executables are. No test built on this can run a real `brew`, `npm`, or
/// `mise`, or remove anything outside its temporary folder.
public final class UninstallScenario: @unchecked Sendable {
    public let fixture: UninstallFixture
    public let runner = FakeCommandRunner()
    public let fileSystem = FakeFileSystem()
    public var processEnvironment: [String: String]

    public init() throws {
        fixture = try UninstallFixture()
        processEnvironment = [
            "HOME": fixture.home,
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "HOMEBREW_CACHE": fixture.home + "/Library/Caches/Homebrew",
        ]
    }

    /// Homebrew's prefix, a real folder inside the fixture so `var` and
    /// `etc` can hold real files.
    public var brewPrefix: String { fixture.root + "/homebrew" }
    public static let brew = "/opt/homebrew/bin/brew"
    public static let npm = "/opt/homebrew/bin/npm"
    public var mise: String { fixture.home + "/.local/bin/mise" }

    public var checkEnvironment: CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: processEnvironment,
            homeDirectory: fixture.home,
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    /// Homebrew with `brew info --json=v2 --installed` answering `info`, and
    /// `brew services list --json` answering `services`.
    public func withHomebrew(info: String, services: String = "[]") throws {
        try FileManager.default.createDirectory(atPath: brewPrefix + "/var", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: brewPrefix + "/etc", withIntermediateDirectories: true)
        fileSystem
            .addExecutable(Self.brew)
            .addFile("/opt/homebrew/Library/Homebrew/cmd/services.rb")
        runner.register("brew", ["--version"], .success("Homebrew 7.0.7\n"))
        runner.register("brew", ["--prefix"], .success(brewPrefix + "\n"))
        runner.register("brew", ["info", "--json=v2", "--installed"], .success(info))
        runner.register("brew", ["services", "list", "--json"], .success(services))
    }

    /// Answers `brew uses --installed` for one formula.
    public func dependents(of formula: String, formulae: String = "", casks: String = "") {
        runner.register("brew", ["uses", "--installed", "--formula", formula], .success(formulae))
        runner.register("brew", ["uses", "--installed", "--cask", formula], .success(casks))
    }

    /// npm with these global packages, as `npm ls -g --json --depth=0` lists them.
    public func withNpm(packages: [String: String]) {
        let root = "/opt/homebrew/lib/node_modules"
        fileSystem.addExecutable(Self.npm).addExecutable("/opt/homebrew/bin/node").addDirectory(root)
        runner.register("npm", ["--version"], .success("10.9.8\n"))
        runner.register("node", ["--version"], .success("v24.19.0\n"))
        runner.register("npm", ["prefix", "-g"], .success("/opt/homebrew\n"))
        runner.register("npm", ["root", "-g"], .success(root + "\n"))
        let dependencies = packages.map { "\"\($0.key)\": {\"version\": \"\($0.value)\"}" }.sorted().joined(separator: ", ")
        runner.register("npm", ["ls", "-g", "--json", "--depth=0"], .success("{\"name\": \"lib\", \"dependencies\": {\(dependencies)}}"))
    }

    /// mise with `mise ls --json` answering `list`.
    public func withMise(list: String) {
        fileSystem.addExecutable(mise)
        runner.register("mise", ["--version"], .success("2026.7.3 macos-arm64 (2026-07-08)\n"))
        runner.register("mise", ["ls", "--json"], .success(list))
    }

    public var configuration: LoadedConfiguration {
        LoadedConfiguration(configuration: .defaults, source: .defaults, path: fixture.home + "/.config/macup/config.json")
    }

    public func catalog(
        configuration: LoadedConfiguration? = nil,
        environment: UninstallEnvironment? = nil
    ) async -> UninstallCatalog {
        await UninstallScanner().catalog(
            configuration: configuration ?? self.configuration,
            environment: checkEnvironment,
            uninstall: environment ?? fixture.environment()
        )
    }

    /// Resolves `target` and plans it, the way both surfaces do.
    public func plan(
        _ target: String,
        configuration: LoadedConfiguration? = nil,
        environment: UninstallEnvironment? = nil
    ) async throws -> UninstallPlan {
        let uninstall = environment ?? fixture.environment()
        let catalog = await catalog(configuration: configuration, environment: uninstall)
        let resolved = try UninstallTargetResolver.resolve(target, in: catalog, homeDirectory: fixture.home).get()
        return await UninstallPlanner().plan(
            resolved,
            catalog: catalog,
            configuration: configuration ?? self.configuration,
            environment: checkEnvironment,
            uninstall: uninstall,
            paths: fixture.paths
        )
    }

    /// Every modifying command the fake runner was asked for.
    public var modifyingRequests: [CommandInvocation] {
        runner.recordedRequests.filter { $0.effect == .modifying }.map(\.invocation)
    }
}

extension UninstallTargetError: LocalizedError {
    public var errorDescription: String? { message }
}
