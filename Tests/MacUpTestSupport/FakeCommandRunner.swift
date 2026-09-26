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

        public init(
            exitStatus: Int32 = 0,
            standardOutput: String = "",
            standardError: String = "",
            error: MacUpError? = nil,
            delay: Duration? = nil
        ) {
            self.exitStatus = exitStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.error = error
            self.delay = delay
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

    public init() {}

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
        let response: Response? = lock.withLock {
            requests.append(request)
            return byPath[Key(executable: request.executable.path, arguments: request.arguments)]
                ?? byName[Key(executable: request.executable.lastPathComponent, arguments: request.arguments)]
        }
        guard let response else {
            throw MacUpError(
                .commandFailed,
                "FakeCommandRunner received an unexpected command.",
                command: request.invocation.displayString
            )
        }
        let startedAt = Date()
        if let delay = response.delay {
            do {
                try await Task.sleep(for: delay)
            } catch {
                throw MacUpError(.cancelled, "The command was cancelled.", command: request.invocation.displayString)
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
            startedAt: startedAt,
            finishedAt: Date()
        )
    }
}
