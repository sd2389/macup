import ArgumentParser
import Foundation
import Testing
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

/// Answers MacUp's yes-or-no questions in order, standing in for someone at a
/// terminal. An empty script means nobody is there, which every prompt in the
/// CLI treats as "no".
final class ScriptedAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String]

    init(_ answers: [String]) {
        pending = answers
    }

    func next() -> String? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }
}

/// A pretend Mac for CLI tests: Homebrew and macOS updates by default, a
/// temporary configuration directory, and a fake runner that refuses
/// anything unregistered.
final class CLIHarness: @unchecked Sendable {
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    let configDirectory: TemporaryDirectory
    /// Scheduling writes real files, so it gets real temporary directories.
    /// `launchctl` is faked, so no test ever installs an agent on the host.
    let stateDirectory: TemporaryDirectory
    let launchAgentsDirectory: TemporaryDirectory
    let binDirectory: TemporaryDirectory
    /// The directory a command runs in, so a default output location is a
    /// throwaway one rather than wherever the test runner was started.
    let workingDirectory: TemporaryDirectory
    let schedulerRunner = FakeCommandRunner()
    let authorizer = FakeBiometricAuthorizer()
    var schedulerFileSystem: any FileSystem = LocalFileSystem()
    var executablePath: String
    var userID: uid_t = 501
    var environment: [String: String]
    var homeDirectory = "/Users/example"
    var isTerminal = false
    /// What someone at a terminal types when MacUp asks. Empty means nobody
    /// answers, so nothing that needs confirmation runs.
    var answers: [String] = []

    static let brewOutdated = """
        {"formulae": [{"name": "git", "installed_versions": ["2.43.0"], "current_version": "2.44.0", "pinned": false, "pinned_version": null},
                      {"name": "mysql", "installed_versions": ["9.7.1"], "current_version": "26.7.0_2", "pinned": false, "pinned_version": null}],
         "casks": []}
        """

    /// `brew outdated --json=v2` with git held back by Homebrew itself, so a
    /// test can prove MacUp never plans an upgrade for a pinned formula.
    static let brewOutdatedPinned = """
        {"formulae": [{"name": "git", "installed_versions": ["2.43.0"], "current_version": "2.44.0", "pinned": true, "pinned_version": "2.43.0"}],
         "casks": []}
        """

    /// `brew info --json=v2 --installed`. MacUp reads this to count installed
    /// items and, after an upgrade, to confirm the new version, so a test that
    /// upgrades git re-registers it with the version it expects to see.
    static func brewInfo(git: String = "2.43.0", mysql: String = "9.7.1") -> String {
        """
        {"formulae": [{"name": "git", "full_name": "git", "installed": [{"version": "\(git)", "installed_on_request": true}], "linked_keg": "\(git)", "pinned": false},
                      {"name": "mysql", "full_name": "mysql", "installed": [{"version": "\(mysql)", "installed_on_request": true}], "linked_keg": "\(mysql)", "pinned": false}],
         "casks": []}
        """
    }
    static let softwareUpdate = """
        Software Update Tool

        Software Update found the following new or updated software:
        * Label: macOS 27.2 Beta-26B5091g
        \tTitle: macOS 27.2 Beta, Version: 27.2, Size: 5935245KiB, Recommended: YES, Action: restart,\u{20}

        """

    init() throws {
        configDirectory = try TemporaryDirectory(prefix: "macup-cli-config")
        stateDirectory = try TemporaryDirectory(prefix: "macup-cli-state")
        launchAgentsDirectory = try TemporaryDirectory(prefix: "macup-cli-agents")
        binDirectory = try TemporaryDirectory(prefix: "macup-cli-bin")
        workingDirectory = try TemporaryDirectory(prefix: "macup-cli-cwd")
        executablePath = try binDirectory.makeScript("macup", "exit 0").path
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
        runner.register("brew", ["info", "--json=v2", "--installed"], .success(Self.brewInfo()))
        runner.register("softwareupdate", ["--list", "--no-scan"], .success(Self.softwareUpdate))
    }

    /// Lets `macup update` upgrade one Homebrew formula, and makes the version
    /// MacUp reads back afterwards the upgraded one.
    ///
    /// The runner is fake, so registering this launches nothing: it only means
    /// the fake stops refusing that exact executable and argument list.
    func allowBrewUpgrade(
        _ formula: String,
        readingBack version: String,
        _ response: FakeCommandRunner.Response = .success("Upgrading git\n")
    ) {
        runner.register("brew", ["upgrade", "--formula", "--yes", formula], response)
        // Homebrew reports the new version only once the upgrade has run.
        runner.onRun("brew", ["upgrade", "--formula", "--yes", formula]) { [runner] in
            runner.register("brew", ["info", "--json=v2", "--installed"], .success(Self.brewInfo(git: version)))
        }
    }

    /// Every modifying command the fake runner was asked for. A read-only
    /// command never appears here, so a dry run should leave it empty.
    var modifyingRequests: [CommandInvocation] {
        runner.recordedRequests.filter { $0.effect == .modifying }.map(\.invocation)
    }

    var historyStore: HistoryStore {
        HistoryStore(fileURL: stateDirectory.appending("history.jsonl"))
    }

    /// The diagnostics `macup doctor` runs. Replaced so no test starts a
    /// login shell on the machine running the tests.
    lazy var doctorEngine: DoctorEngine = matchingShellDoctor()

    /// Doctor with the login-shell probe answered from this harness, so the
    /// Mac under test is one whose terminal PATH is the one MacUp already
    /// has. Every other check is the shipping one.
    private func matchingShellDoctor() -> DoctorEngine {
        let standard = DoctorEngine.standard()
        let path = environment["PATH"] ?? ""
        return DoctorEngine(
            providers: standard.providers,
            checks: standard.checks.map { check in
                guard check is ShellEnvironmentCheck else { return check }
                return ShellEnvironmentCheck(read: { _ in ("/bin/zsh", ["PATH": path]) })
            }
        )
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

    /// Points MacUp's state and LaunchAgents directories at this harness's
    /// temporary ones. Opt-in, so tests of the default paths keep seeing them.
    func useTemporaryDirectories() {
        environment[MacUpPaths.stateDirectoryVariable] = stateDirectory.path
        environment[MacUpPaths.launchAgentsDirectoryVariable] = launchAgentsDirectory.path
    }

    var agentPath: String { launchAgentsDirectory.path + "/" + LaunchAgent.fileName }
    var serviceTarget: String { "gui/\(userID)/\(LaunchAgent.label)" }

    /// Answers the launchctl calls `macup schedule` makes.
    func expectLaunchctl(bootstrap: FakeCommandRunner.Response = .success(), loaded: Bool = true) {
        schedulerRunner.register(path: Scheduler.launchctlPath, ["bootout", serviceTarget], .success())
        schedulerRunner.register(path: Scheduler.launchctlPath, ["bootstrap", "gui/\(userID)", agentPath], bootstrap)
        schedulerRunner.register(
            path: Scheduler.launchctlPath,
            ["print", serviceTarget],
            loaded ? .success() : .exit(113, standardError: "Could not find service")
        )
    }

    func readConfig() throws -> [String: Any] {
        let data = try Data(contentsOf: configDirectory.appending("config.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func writeConfig(_ json: String) throws {
        try json.write(to: configDirectory.appending("config.json"), atomically: true, encoding: .utf8)
    }

    func run(_ arguments: [String]) async throws -> CLIRun {
        let stdout = BufferedOutput()
        let stderr = BufferedOutput()
        let scripted = ScriptedAnswers(answers)
        let context = CLIContext(
            environment: environment,
            homeDirectory: homeDirectory,
            standardOutput: stdout,
            standardError: stderr,
            standardOutputIsTerminal: isTerminal,
            engine: .standard(),
            doctorEngine: doctorEngine,
            checkEnvironment: CheckEnvironment(
                runner: runner,
                fileSystem: fileSystem,
                processEnvironment: environment,
                homeDirectory: homeDirectory,
                system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
            ),
            handlesInterrupts: false,
            executablePath: executablePath,
            userID: userID,
            schedulerRunner: schedulerRunner,
            schedulerFileSystem: schedulerFileSystem,
            authorizer: authorizer,
            readLine: { scripted.next() },
            currentDirectory: workingDirectory.path
        )
        return try await runCLI(arguments, context: context, stdout: stdout, stderr: stderr)
    }
}

/// Parses and runs a command the way `macup` would, inside `context`.
///
/// A command line MacUp rejects is reported the way the real binary reports
/// it — the usage message on standard error and exit status 64 — rather than
/// as a thrown test failure, so a test can assert on what the user is told.
func runCLI(_ arguments: [String], context: CLIContext, stdout: BufferedOutput, stderr: BufferedOutput) async throws -> CLIRun {
    var command: any ParsableCommand
    do {
        command = try MacUpCommand.parseAsRoot(arguments)
    } catch {
        stderr.write(MacUpCommand.fullMessage(for: error) + "\n")
        return CLIRun(
            standardOutput: stdout.text,
            standardError: stderr.text,
            exitCode: MacUpCommand.exitCode(for: error).rawValue
        )
    }
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
