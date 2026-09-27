import Foundation
import MacUpCore

/// Somewhere to write text (stdout, stderr, or a test buffer).
protocol TextOutput: Sendable {
    func write(_ text: String)
}

struct FileHandleOutput: TextOutput {
    let handle: FileHandle

    func write(_ text: String) {
        handle.write(Data(text.utf8))
    }
}

/// Everything a command needs from the outside world. Commands read
/// `CLIContext.current`; tests bind a context made of fakes, so the CLI can be
/// exercised end to end without running anything on the host.
struct CLIContext: Sendable {
    var environment: [String: String]
    var homeDirectory: String
    var standardOutput: any TextOutput
    var standardError: any TextOutput
    var standardOutputIsTerminal: Bool
    var engine: CheckEngine
    var checkEnvironment: CheckEnvironment
    /// Ctrl+C handling is process-wide; tests turn it off.
    var handlesInterrupts: Bool
    /// Absolute path of this `macup` binary, which is what a scheduled check
    /// runs. Not symlink-resolved: scheduling `/opt/homebrew/bin/macup`
    /// keeps working when Homebrew moves the version behind it.
    var executablePath: String
    var userID: uid_t
    /// Scheduling talks to launchctl and the file system directly; tests
    /// replace both so no agent is ever installed on the host.
    var schedulerRunner: any CommandRunning
    var schedulerFileSystem: any FileSystem
    /// macOS authentication, replaced in tests so no test shows a prompt.
    var authorizer: any BiometricAuthorizing

    /// Asks the device owner to approve a change, when the configuration says
    /// to. Returns the outcome; the caller refuses the change unless it allows
    /// one, and explains why.
    func approval(_ action: String, _ configuration: MacUpConfiguration) async -> ApprovalOutcome {
        await ApprovalGate(settings: configuration.security, authorizer: authorizer).approve(action)
    }

    func scheduler(paths: MacUpPaths) -> Scheduler {
        Scheduler(
            paths: paths,
            executable: executablePath,
            userID: userID,
            fileSystem: schedulerFileSystem,
            runner: schedulerRunner,
            processEnvironment: environment
        )
    }

    @TaskLocal static var current = CLIContext.live()

    static func live() -> CLIContext {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return CLIContext(
            environment: environment,
            homeDirectory: home,
            standardOutput: FileHandleOutput(handle: .standardOutput),
            standardError: FileHandleOutput(handle: .standardError),
            standardOutputIsTerminal: isatty(STDOUT_FILENO) == 1,
            engine: .standard(),
            checkEnvironment: .live(processEnvironment: environment, homeDirectory: home),
            handlesInterrupts: true,
            executablePath: currentExecutablePath(),
            userID: getuid(),
            schedulerRunner: ProcessCommandRunner(),
            schedulerFileSystem: LocalFileSystem(),
            authorizer: LocalAuthenticator()
        )
    }

    /// Where this binary lives. An answer that is not an absolute path is
    /// returned as-is; scheduling then refuses and says why, rather than
    /// installing an agent that points at nothing.
    static func currentExecutablePath() -> String {
        if let path = Bundle.main.executablePath, path.hasPrefix("/") { return path }
        let argument = CommandLine.arguments.first ?? "macup"
        if argument.hasPrefix("/") { return argument }
        if argument.contains("/") {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argument).standardizedFileURL.path
        }
        return argument
    }

    /// Whether human output may use ANSI styling: only on a terminal, and
    /// never when `NO_COLOR` is set or `TERM` is `dumb`.
    var allowsStyling: Bool {
        standardOutputIsTerminal
            && environment["NO_COLOR"].map(\.isEmpty) != false
            && environment["TERM"] != "dumb"
    }

    func print(_ text: String = "") {
        standardOutput.write(text + "\n")
    }

    func printError(_ text: String) {
        standardError.write(text + "\n")
    }

    /// Resolves MacUp's paths, reporting an invalid override as exit code 3.
    func resolvePaths() throws -> MacUpPaths {
        do {
            return try MacUpPaths.resolve(homeDirectory: homeDirectory, environment: environment)
        } catch let error as MacUpError {
            printError("error: \(TerminalText.sanitize(error.message))")
            throw MacUpExitCode.configurationInvalid.exitCode
        }
    }
}
