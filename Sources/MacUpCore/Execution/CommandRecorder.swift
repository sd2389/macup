import Foundation

/// A display-safe account of one command MacUp attempted.
public struct CommandRecord: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case exited
        case signaled
        case timedOut
        case cancelled
        case refused
        case failedToLaunch
    }

    /// Redacted, shell-quoted display form. Never executed.
    public var command: String
    public var effect: CommandEffect
    public var outcome: Outcome
    public var exitStatus: Int32?
    public var startedAt: Date
    public var durationSeconds: Double

    public init(
        command: String,
        effect: CommandEffect,
        outcome: Outcome,
        exitStatus: Int32?,
        startedAt: Date,
        durationSeconds: Double
    ) {
        self.command = command
        self.effect = effect
        self.outcome = outcome
        self.exitStatus = exitStatus
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }
}

/// Collects ``CommandRecord``s from concurrent commands.
public actor CommandLog {
    public private(set) var records: [CommandRecord] = []

    public init() {}

    func append(_ record: CommandRecord) {
        records.append(record)
    }
}

/// Records every command that passes through it, including refused ones.
public struct RecordingCommandRunner: CommandRunning {
    public var base: any CommandRunning
    public var log: CommandLog
    public var redactor: Redactor

    public init(base: any CommandRunning, log: CommandLog, redactor: Redactor = Redactor()) {
        self.base = base
        self.log = log
        self.redactor = redactor
    }

    public func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        let startedAt = Date()
        let command = redactor.redact(request.invocation.displayString)
        do {
            let result = try await base.run(request, output: output)
            let outcome: CommandRecord.Outcome
            switch result.termination {
            case .exited: outcome = .exited
            case .signaled: outcome = .signaled
            }
            await log.append(CommandRecord(
                command: command,
                effect: request.effect,
                outcome: outcome,
                exitStatus: result.exitStatus,
                startedAt: result.startedAt,
                durationSeconds: result.duration
            ))
            return result
        } catch {
            let outcome: CommandRecord.Outcome
            switch (error as? MacUpError)?.kind {
            case .timeout: outcome = .timedOut
            case .cancelled: outcome = .cancelled
            case .policyDenied: outcome = .refused
            default: outcome = .failedToLaunch
            }
            await log.append(CommandRecord(
                command: command,
                effect: request.effect,
                outcome: outcome,
                exitStatus: nil,
                startedAt: startedAt,
                durationSeconds: Date().timeIntervalSince(startedAt)
            ))
            throw error
        }
    }
}
