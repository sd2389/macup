import ArgumentParser
import Darwin
import Foundation
import MacUpCore

/// What `macup ai`, `macup ask`, and `macup insight` need from outside: the
/// TypeSafe connection, the Keychain, and a way to read a key without it
/// appearing on screen. Tests replace all three, so no test reaches the
/// network, the real Keychain, or a terminal.
struct CLIAIServices: Sendable {
    var service: AIService
    /// Reads one secret line. At a terminal, with echo off; otherwise one
    /// line from standard input, so a key can be piped in. `nil` when there
    /// is nothing to read.
    var readSecret: @Sendable (_ prompt: String) -> String?

    static func live() -> CLIAIServices {
        CLIAIServices(service: .live(), readSecret: readSecretLine)
    }

    /// Sends nothing and stores nothing: what a context has unless it is
    /// wired to the real ones.
    static let unavailable = CLIAIServices(service: .unavailable, readSecret: { _ in nil })

    private static func readSecretLine(_ prompt: String) -> String? {
        guard isatty(STDIN_FILENO) == 1 else { return Swift.readLine(strippingNewline: true) }
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        guard let line = readpassphrase(prompt, &buffer, buffer.count, Int32(RPP_REQUIRE_TTY)) else { return nil }
        return String(cString: line)
    }
}

extension CLIContext {
    /// The report with the cautions of saved AI estimates added, while AI
    /// help is on. Reads one local file and sends nothing. A saved estimate
    /// MacUp could not read is said on standard error, never guessed at.
    func aiCautioned(_ report: CheckReport, configuration: LoadedConfiguration) -> CheckReport {
        guard ai.service.appliesEstimates(configuration),
              let paths = try? MacUpPaths.resolve(homeDirectory: homeDirectory, environment: environment)
        else { return report }
        let (cautioned, problem) = ai.service.cautioned(report, configuration: configuration, paths: paths)
        if let problem { printError("warning: \(TerminalText.sanitize(problem))") }
        return cautioned
    }

    /// Reports an AI error the way every MacUp command reports an error, and
    /// stops the command. Nothing was changed by the time any of these happen.
    func fail(_ error: AIError) -> ExitCode {
        printError("error: \(TerminalText.sanitize(error.message))")
        if let detail = error.detail {
            printError("  " + TerminalText.sanitize(detail))
        }
        if let suggestion = error.recoverySuggestion {
            printError(TerminalText.sanitize(suggestion))
        }
        switch error.kind {
        case .configurationUnreadable: return MacUpExitCode.configurationInvalid.exitCode
        case .cancelled: return MacUpExitCode.cancelled.exitCode
        default: return MacUpExitCode.failure.exitCode
        }
    }
}
