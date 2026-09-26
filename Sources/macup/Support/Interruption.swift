import Dispatch
import Foundation

/// Runs work that Ctrl+C should cancel cleanly.
///
/// The first Ctrl+C cancels the task; providers' commands receive SIGTERM
/// through the command runner and the command finishes with a partial,
/// clearly marked result. A second Ctrl+C exits immediately.
enum Interruption {
    static func run<Value: Sendable>(
        handlingInterrupts: Bool,
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let task = Task { await operation() }
        guard handlingInterrupts else { return await task.value }

        let state = InterruptState()
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            if state.markInterrupted() {
                FileHandle.standardError.write(Data("\nCancelling… (press Ctrl+C again to quit immediately)\n".utf8))
                task.cancel()
            } else {
                exit(MacUpExitCode.cancelled.rawValue)
            }
        }
        source.resume()
        defer {
            source.cancel()
            signal(SIGINT, SIG_DFL)
        }
        return await task.value
    }
}

private final class InterruptState: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false

    /// Returns true the first time.
    func markInterrupted() -> Bool {
        lock.withLock {
            defer { interrupted = true }
            return !interrupted
        }
    }
}
