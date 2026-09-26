import Foundation

/// What a command is allowed to change.
///
/// Every request declares its effect so read-only flows can enforce — and
/// tests can prove — that nothing modifying was issued.
public enum CommandEffect: String, Sendable, Hashable, Codable, CaseIterable {
    /// Reads local state or queries a registry. Never installs, upgrades,
    /// removes, cleans, prunes, or rewrites configuration.
    case readOnly
    /// Refreshes a package manager's own metadata (for example `brew update`).
    /// May update the package manager's data; never changes installed packages.
    case metadataRefresh
    /// Changes installed software or configuration. Requires an execution plan.
    case modifying
}

/// A fully specified external command.
///
/// There is intentionally no way to express a shell command line: MacUp
/// launches `executable` directly with `arguments` as separate elements.
public struct CommandRequest: Sendable, Hashable {
    /// Absolute path of the executable to launch.
    public var executable: URL
    public var arguments: [String]
    /// The complete environment for the child process. Nothing is inherited
    /// implicitly; build this with ``EnvironmentPolicy``.
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var timeout: Duration
    public var effect: CommandEffect
    /// Maximum bytes kept per output stream. Output beyond this is discarded
    /// and the result is marked truncated.
    public var outputLimit: Int

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(120),
        effect: CommandEffect,
        outputLimit: Int = 32 * 1024 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.effect = effect
        self.outputLimit = outputLimit
    }

    public var invocation: CommandInvocation {
        CommandInvocation(executable: executable.path, arguments: arguments)
    }

    /// Rejects requests that cannot be launched faithfully.
    public func validate() throws {
        let display = Redactor().redact(invocation.displayString)
        func refuse(_ reason: String) -> MacUpError {
            MacUpError(.commandFailed, "MacUp refused to launch a command: \(reason).", command: display)
        }
        guard executable.isFileURL, executable.path.hasPrefix("/") else {
            throw refuse("the executable path is not absolute")
        }
        if executable.path.contains("\0") || arguments.contains(where: { $0.contains("\0") }) {
            throw refuse("an argument contains a NUL byte")
        }
        for (name, value) in environment {
            if name.isEmpty || name.contains("=") || name.contains("\0") || value.contains("\0") {
                throw refuse("the environment contains an invalid entry")
            }
        }
        if let workingDirectory, !workingDirectory.path.hasPrefix("/") {
            throw refuse("the working directory is not absolute")
        }
        guard outputLimit > 0 else { throw refuse("the output limit must be positive") }
    }
}

/// How a finished command ended.
public enum CommandTermination: Sendable, Hashable {
    case exited(Int32)
    case signaled(Int32)
}

/// The captured outcome of a command that ran to completion.
///
/// A non-zero exit status is a normal result, not an error: some providers
/// (for example `npm outdated`) exit non-zero while producing valid output.
public struct CommandResult: Sendable, Hashable {
    public var invocation: CommandInvocation
    public var effect: CommandEffect
    public var termination: CommandTermination
    public var standardOutput: Data
    public var standardError: Data
    /// True when output exceeded the request's limit or could not be fully drained.
    public var outputTruncated: Bool
    public var startedAt: Date
    public var finishedAt: Date

    public init(
        invocation: CommandInvocation,
        effect: CommandEffect,
        termination: CommandTermination,
        standardOutput: Data = Data(),
        standardError: Data = Data(),
        outputTruncated: Bool = false,
        startedAt: Date,
        finishedAt: Date
    ) {
        self.invocation = invocation
        self.effect = effect
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.outputTruncated = outputTruncated
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var exitStatus: Int32? {
        if case .exited(let status) = termination { return status }
        return nil
    }

    public var succeeded: Bool { termination == .exited(0) }
    public var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
    public var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    public var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

public enum CommandOutputStream: String, Sendable, Hashable {
    case standardOutput
    case standardError
}

/// A piece of output delivered while a command is still running.
public struct CommandOutputChunk: Sendable, Hashable {
    public var stream: CommandOutputStream
    public var data: Data

    public init(stream: CommandOutputStream, data: Data) {
        self.stream = stream
        self.data = data
    }
}

/// Receives streamed output. Called from a background queue; chunks of one
/// stream arrive in order.
public typealias CommandOutputHandler = @Sendable (CommandOutputChunk) -> Void

/// The only normal path for launching external executables.
///
/// Implementations throw ``MacUpError`` with kind `.timeout`, `.cancelled`, or
/// `.commandFailed` (launch failures and refused requests). A command that
/// runs and exits non-zero is returned as a ``CommandResult``.
public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ request: CommandRequest) async throws -> CommandResult {
        try await run(request, output: nil)
    }
}
