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
    /// The diagnostics `macup doctor` runs. Injectable for the same reason as
    /// `engine`: one of them starts the user's login shell, and a test should
    /// describe a Mac rather than run anything on the host.
    var doctorEngine: DoctorEngine
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
    /// Reads one line of the user's answer to a question MacUp asked.
    /// Returns `nil` when there is nobody to read from, which every caller
    /// treats as "no" rather than as consent.
    var readLine: @Sendable () -> String?
    /// Where a relative path on the command line starts from, and where
    /// `macup diagnostics export` writes by default. Injectable so a test
    /// never writes into whatever directory the test runner is in.
    var currentDirectory = FileManager.default.currentDirectoryPath

    /// Asks the device owner to approve a change, when the configuration says
    /// to. Returns the outcome; the caller refuses the change unless it allows
    /// one, and explains why.
    func approval(_ action: String, _ configuration: MacUpConfiguration, paths: MacUpPaths) async -> ApprovalOutcome {
        await ApprovalGate(
            settings: configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(configuration, paths: paths)
        ).approve(action)
    }

    /// MacUp's own camera face match, when the configuration asks for it.
    /// `nil` otherwise, so the camera is never opened for someone who did not
    /// turn it on.
    func faceUnlock(_ configuration: MacUpConfiguration, paths: MacUpPaths) -> FaceUnlockService? {
        guard configuration.security.faceUnlock else { return nil }
        return FaceUnlockService(
            store: FaceEnrollmentStore(paths: paths),
            comparator: FaceComparator(threshold: Float(configuration.security.faceMatchThreshold))
        )
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
            doctorEngine: .standard(),
            checkEnvironment: .live(processEnvironment: environment, homeDirectory: home),
            handlesInterrupts: true,
            executablePath: currentExecutablePath(),
            userID: getuid(),
            schedulerRunner: ProcessCommandRunner(),
            schedulerFileSystem: LocalFileSystem(),
            authorizer: LocalAuthenticator(),
            readLine: { Swift.readLine(strippingNewline: true) }
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

    /// Stops a command that would write to a configuration MacUp could not
    /// read, and says which lines it could not read.
    ///
    /// Saving re-encodes what MacUp understood, so writing a file it misread
    /// could drop the very exclusions the user is relying on. Refusing is the
    /// fail-closed answer (CLAUDE.md §2.23).
    func requireReadableConfiguration(_ loaded: LoadedConfiguration) throws {
        guard loaded.hasErrors else { return }
        printError("error: MacUp will not change a configuration it cannot read.")
        for issue in loaded.issues where issue.severity == .error {
            let location = issue.path.isEmpty ? "" : TerminalText.sanitize(issue.path) + ": "
            printError("  \(location)\(TerminalText.sanitize(issue.message))")
        }
        printError("Fix \(PathDisplay.abbreviatingHome(loaded.path, homeDirectory: homeDirectory)) and try again.")
        throw MacUpExitCode.configurationInvalid.exitCode
    }

    /// Asks the device owner to approve a change and stops the command when
    /// the answer is anything but yes.
    func requireApproval(_ action: String, _ configuration: MacUpConfiguration, paths: MacUpPaths) async throws {
        let approval = await approval(action, configuration, paths: paths)
        guard approval.allowsChange else {
            printError("error: \(TerminalText.sanitize(approval.explanation ?? "MacUp did not get your approval."))")
            printError("Nothing was changed.")
            throw MacUpExitCode.notApproved.exitCode
        }
    }

    /// Asks a yes-or-no question and returns true only for an explicit yes.
    ///
    /// Anything else — no answer at all, a closed input, a word MacUp does not
    /// recognize — is a no, because a change nobody agreed to must not happen.
    func askToProceed(_ question: String) -> Bool {
        standardOutput.write(question + " [y/N] ")
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
            print("")
            return false
        }
        return answer == "y" || answer == "yes"
    }
}
