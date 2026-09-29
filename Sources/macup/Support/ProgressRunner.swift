import Foundation
import MacUpCore

/// Narrates a change while it is happening, so a slow update is not a silent
/// wait.
///
/// The execution engine reports once the whole run is over, which on a large
/// upgrade leaves the terminal blank for minutes. Wrapping the runner is how
/// the CLI narrates without the engine needing to know that a terminal exists:
/// every command the engine launches passes through here on its way to the
/// real runner. Only modifying commands are announced, because somebody
/// watching an update wants to see the upgrade, not the version lookups
/// around it.
///
/// This changes nothing about what runs. It forwards the request untouched and
/// returns the real runner's answer, including its errors.
struct ProgressRunner: CommandRunning {
    var base: any CommandRunning
    /// Receives one already-redacted, terminal-safe line at a time.
    var report: @Sendable (String) -> Void

    func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        guard request.effect == .modifying else { return try await base.run(request, output: output) }

        let redactor = Redactor()
        let command = TerminalText.sanitize(redactor.redact(request.invocation.displayString))
        report("  Running: " + command)

        let clock = ContinuousClock()
        let started = clock.now
        func elapsed() -> String {
            let duration = clock.now - started
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return String(format: "%.1fs", seconds)
        }

        // The package manager's own words, a line at a time, so a long
        // install reads as work in progress rather than as a hang.
        let lines = OutputLines(limit: 1)
        let report = report
        let streaming: CommandOutputHandler = { chunk in
            for line in lines.append(chunk) { report("    " + line) }
            output?(chunk)
        }

        do {
            let result = try await base.run(request, output: streaming)
            if result.succeeded {
                report("  Finished in \(elapsed()).")
            } else {
                let status = result.exitStatus.map { "exit status \($0)" } ?? "a signal"
                report("  Ended with \(status) after \(elapsed()).")
            }
            return result
        } catch {
            let failure = MacUpError.wrapping(error, context: "Running \(command)")
            report("  Stopped after \(elapsed()): " + TerminalText.sanitize(failure.message))
            throw error
        }
    }
}
