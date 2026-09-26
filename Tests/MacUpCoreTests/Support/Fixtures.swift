import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// Loads files from Tests/MacUpCoreTests/Fixtures.
enum Fixture {
    static func url(_ path: String) throws -> URL {
        let name = (path as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        let resource = (name as NSString).lastPathComponent
        let directory = "Fixtures/" + (name as NSString).deletingLastPathComponent
        return try #require(
            Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: directory),
            "Missing fixture \(path)"
        )
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }
}

/// A pretend Mac for provider tests: a fake runner (which refuses anything
/// unregistered), a fake file system, and a fixed environment. Commands go
/// through the same read-only guard and allowlist as a real check, so every
/// provider test also proves its commands are allowlisted.
final class ProviderHarness: @unchecked Sendable {
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    var environment: [String: String]
    var settings = MacUpConfiguration.ProviderSettings()
    var refreshMetadata = false
    var system = SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
    let homeDirectory = "/Users/example"

    init(path: String = "/opt/homebrew/bin:/usr/bin:/bin") {
        environment = [
            "HOME": "/Users/example",
            "USER": "example",
            "PATH": path,
            "LANG": "en_US.UTF-8",
            "TERM": "xterm-256color",
            "GITHUB_TOKEN": "ghp_testtokentesttokentesttoken00",
            "AWS_SECRET_ACCESS_KEY": "not-for-providers",
            "NODE_OPTIONS": "--require /tmp/evil.js",
        ]
    }

    func context(installation: ProviderInstallation? = nil) -> ProviderContext {
        ProviderContext(
            runner: ReadOnlyCommandGuard(
                base: runner,
                rules: CommandAllowlist.readOnlyCheck,
                allowsMetadataRefresh: refreshMetadata
            ),
            fileSystem: fileSystem,
            environment: environment,
            homeDirectory: homeDirectory,
            searchPath: SearchPath.parse(environment["PATH"]),
            settings: settings,
            refreshMetadata: refreshMetadata,
            system: system,
            installation: installation
        )
    }

    /// Detects the provider and returns a context bound to that installation,
    /// as the check engine does.
    func detectedContext(_ provider: some UpdateProvider) async throws -> ProviderContext {
        let status = await provider.detect(context: context())
        let installation = try #require(status.installation, "detection failed: \(String(describing: status.error))")
        return context(installation: installation)
    }

    var requests: [CommandRequest] { runner.recordedRequests }

    func arguments(for executableName: String) -> [[String]] {
        requests.filter { $0.executable.lastPathComponent == executableName }.map(\.arguments)
    }
}

extension CommandResult {
    /// A synthetic result, for testing parsers that look at exit status.
    static func fixture(_ stdout: String, stderr: String = "", exitStatus: Int32 = 0, arguments: [String] = []) -> CommandResult {
        CommandResult(
            invocation: CommandInvocation(executable: "/usr/local/bin/tool", arguments: arguments),
            effect: .readOnly,
            termination: .exited(exitStatus),
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8),
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
