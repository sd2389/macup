import Foundation
import MacUpCore

/// A command runner that answers only commands a test registered.
///
/// An unregistered command throws immediately, so a test can never fall
/// through to a real provider binary. Every request is recorded for
/// assertions such as "only read-only commands were issued".
public final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    public struct Response: Sendable {
        public var exitStatus: Int32
        public var standardOutput: String
        public var standardError: String
        public var error: MacUpError?
        public var delay: Duration?
        /// Report the output as cut off at the runner's limit.
        public var truncated: Bool

        public init(
            exitStatus: Int32 = 0,
            standardOutput: String = "",
            standardError: String = "",
            error: MacUpError? = nil,
            delay: Duration? = nil,
            truncated: Bool = false
        ) {
            self.exitStatus = exitStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.error = error
            self.delay = delay
            self.truncated = truncated
        }

        public static func success(_ standardOutput: String = "", standardError: String = "") -> Response {
            Response(standardOutput: standardOutput, standardError: standardError)
        }

        public static func exit(_ status: Int32, standardOutput: String = "", standardError: String = "") -> Response {
            Response(exitStatus: status, standardOutput: standardOutput, standardError: standardError)
        }

        public static func throwing(_ error: MacUpError) -> Response {
            Response(error: error)
        }
    }

    private struct Key: Hashable {
        var executable: String
        var arguments: [String]
    }

    private let lock = NSLock()
    private var byPath: [Key: Response] = [:]
    private var byName: [Key: Response] = [:]
    private var requests: [CommandRequest] = []
    private var hooks: [Key: @Sendable () -> Void] = [:]

    public init() {}

    /// Runs `perform` each time a command with this file name and these
    /// arguments is answered: how a fake models a command that changes what
    /// a later read reports, such as an upgrade changing `brew info`.
    public func onRun(_ executableName: String, _ arguments: [String], perform: @escaping @Sendable () -> Void) {
        lock.withLock { hooks[Key(executable: executableName, arguments: arguments)] = perform }
    }

    /// Registers a response for an exact executable path and arguments.
    public func register(path: String, _ arguments: [String], _ response: Response) {
        lock.withLock { byPath[Key(executable: path, arguments: arguments)] = response }
    }

    /// Registers a response for any executable with this file name.
    public func register(_ executableName: String, _ arguments: [String], _ response: Response) {
        lock.withLock { byName[Key(executable: executableName, arguments: arguments)] = response }
    }

    public var recordedRequests: [CommandRequest] {
        lock.withLock { requests }
    }

    public var recordedInvocations: [CommandInvocation] {
        recordedRequests.map(\.invocation)
    }

    public func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        try request.validate()
        let (response, hook): (Response?, (@Sendable () -> Void)?) = lock.withLock {
            requests.append(request)
            let name = Key(executable: request.executable.lastPathComponent, arguments: request.arguments)
            return (
                byPath[Key(executable: request.executable.path, arguments: request.arguments)] ?? byName[name],
                hooks[name]
            )
        }
        hook?()
        guard let response else {
            throw MacUpError(
                .commandFailed,
                "FakeCommandRunner received an unexpected command.",
                command: request.invocation.displayString
            )
        }
        let startedAt = Date()
        if let delay = response.delay {
            if request.effect == .readOnly {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    throw MacUpError(.cancelled, "The command was cancelled.", command: request.invocation.displayString)
                }
            } else {
                // As the real runner does, a command that changes something
                // is left to finish even when its task is cancelled.
                let nanoseconds = UInt64(max(0, delay.components.seconds)) * 1_000_000_000
                    + UInt64(max(0, delay.components.attoseconds) / 1_000_000_000)
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
                        continuation.resume()
                    }
                }
            }
        }
        if let error = response.error { throw error }
        let stdout = Data(response.standardOutput.utf8)
        let stderr = Data(response.standardError.utf8)
        if let output {
            if !stdout.isEmpty { output(CommandOutputChunk(stream: .standardOutput, data: stdout)) }
            if !stderr.isEmpty { output(CommandOutputChunk(stream: .standardError, data: stderr)) }
        }
        return CommandResult(
            invocation: request.invocation,
            effect: request.effect,
            termination: .exited(response.exitStatus),
            standardOutput: stdout,
            standardError: stderr,
            outputTruncated: response.truncated,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }
}
