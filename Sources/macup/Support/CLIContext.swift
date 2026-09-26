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
            handlesInterrupts: true
        )
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
