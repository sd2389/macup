import ArgumentParser
import Foundation

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

extension CLIContext {
    static func testing(
        environment: [String: String] = [:],
        homeDirectory: String = "/Users/example",
        isTerminal: Bool = false
    ) -> (CLIContext, BufferedOutput, BufferedOutput) {
        let stdout = BufferedOutput()
        let stderr = BufferedOutput()
        let context = CLIContext(
            environment: environment,
            homeDirectory: homeDirectory,
            standardOutput: stdout,
            standardError: stderr,
            standardOutputIsTerminal: isTerminal
        )
        return (context, stdout, stderr)
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
