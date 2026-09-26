import ArgumentParser
import Foundation
import MacUpCore
import MacUpTestSupport

@testable import macup

/// Captures command output for assertions.
final class BufferedOutput: TextOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func write(_ text: String) {
        lock.withLock { buffer += text }
    }

    var text: String { lock.withLock { buffer } }
}

struct CLIRun {
    var standardOutput: String
    var standardError: String
    /// `nil` when the command returned normally.
    var exitCode: Int32?
}

/// A pretend Mac for CLI tests: Homebrew and macOS updates by default, a
/// temporary configuration directory, and a fake runner that refuses
/// anything unregistered.
final class CLIHarness: @unchecked Sendable {
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    let configDirectory: TemporaryDirectory
    var environment: [String: String]
    var homeDirectory = "/Users/example"
    var isTerminal = false

    static let brewOutdated = """
        {"formulae": [{"name": "git", "installed_versions": ["2.43.0"], "current_version": "2.44.0", "pinned": false, "pinned_version": null},
                      {"name": "mysql", "installed_versions": ["9.7.1"], "current_version": "26.7.0_2", "pinned": false, "pinned_version": null}],
         "casks": []}
        """
    static let brewInfo = """
        {"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "2.43.0", "installed_on_request": true}], "linked_keg": "2.43.0", "pinned": false},
                      {"name": "mysql", "full_name": "mysql", "installed": [{"version": "9.7.1", "installed_on_request": true}], "linked_keg": "9.7.1", "pinned": false}],
         "casks": []}
        """
    static let softwareUpdate = """
        Software Update Tool

        Software Update found the following new or updated software:
        * Label: macOS 27.2 Beta-26B5091g
        \tTitle: macOS 27.2 Beta, Version: 27.2, Size: 5935245KiB, Recommended: YES, Action: restart,\u{20}

        """

    init() throws {
        configDirectory = try TemporaryDirectory(prefix: "macup-cli-config")
        environment = [
            "HOME": "/Users/example",
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "MACUP_CONFIG_DIR": configDirectory.path,
        ]
        fileSystem
            .addExecutable("/opt/homebrew/bin/brew")
            .addExecutable("/usr/sbin/softwareupdate")
        runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        runner.register("brew", ["outdated", "--json=v2"], .success(Self.brewOutdated))
        runner.register("brew", ["info", "--json=v2", "--installed"], .success(Self.brewInfo))
        runner.register("softwareupdate", ["--list", "--no-scan"], .success(Self.softwareUpdate))
    }

    /// Adds npm with the given `npm outdated -g --json` output.
    func addNpm(outdated: String) {
        fileSystem
            .addExecutable("/opt/homebrew/bin/npm")
            .addExecutable("/opt/homebrew/bin/node")
            .addDirectory("/opt/homebrew/lib/node_modules")
        runner.register("npm", ["--version"], .success("11.17.0\n"))
        runner.register("node", ["--version"], .success("v24.19.0\n"))
        runner.register("npm", ["prefix", "-g"], .success("/opt/homebrew\n"))
        runner.register("npm", ["root", "-g"], .success("/opt/homebrew/lib/node_modules\n"))
        runner.register("npm", ["outdated", "-g", "--json"], .exit(1, standardOutput: outdated))
        runner.register("npm", ["ls", "-g", "--json", "--depth=0"], .success(#"{"name": "lib", "dependencies": {}}"#))
    }

    func writeConfig(_ json: String) throws {
        try json.write(to: configDirectory.appending("config.json"), atomically: true, encoding: .utf8)
    }

    func run(_ arguments: [String]) async throws -> CLIRun {
        let stdout = BufferedOutput()
        let stderr = BufferedOutput()
        let context = CLIContext(
            environment: environment,
            homeDirectory: homeDirectory,
            standardOutput: stdout,
            standardError: stderr,
            standardOutputIsTerminal: isTerminal,
            engine: .standard(),
            checkEnvironment: CheckEnvironment(
                runner: runner,
                fileSystem: fileSystem,
                processEnvironment: environment,
                homeDirectory: homeDirectory,
                system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
            ),
            handlesInterrupts: false
        )
        return try await runCLI(arguments, context: context, stdout: stdout, stderr: stderr)
    }
}

/// Parses and runs a command the way `macup` would, inside `context`.
func runCLI(_ arguments: [String], context: CLIContext, stdout: BufferedOutput, stderr: BufferedOutput) async throws -> CLIRun {
    var command = try MacUpCommand.parseAsRoot(arguments)
    var exitCode: Int32?
    do {
        try await CLIContext.$current.withValue(context) {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
    } catch let error as ExitCode {
        exitCode = error.rawValue
    }
    return CLIRun(standardOutput: stdout.text, standardError: stderr.text, exitCode: exitCode)
}
