import Foundation

/// MacUp's error type.
///
/// `kind` is the typed category that drives behavior (ARCHITECTURE.md, "Error
/// model"). The other fields are display-safe details — already redacted —
/// kept separate from the category so callers never parse message strings.
public struct MacUpError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case providerUnavailable
        case commandFailed
        case parseFailed
        case policyDenied
        case authorizationRequired
        case timeout
        case cancelled
        case verificationFailed
        case ambiguousOwnership
        case unsupported
        case configurationInvalid
    }

    public var kind: Kind
    /// One display-safe sentence describing what went wrong.
    public var message: String
    /// Optional display-safe detail, such as a redacted stderr excerpt.
    public var detail: String?
    /// Display form of the command involved, if any. Never executed.
    public var command: String?
    public var exitStatus: Int32?
    /// What the user can do next.
    public var recoverySuggestion: String?

    public init(
        _ kind: Kind,
        _ message: String,
        detail: String? = nil,
        command: String? = nil,
        exitStatus: Int32? = nil,
        recoverySuggestion: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.command = command
        self.exitStatus = exitStatus
        self.recoverySuggestion = recoverySuggestion
    }

    public var description: String {
        var parts = ["\(kind.rawValue): \(message)"]
        if let command { parts.append("command: \(command)") }
        if let exitStatus { parts.append("exit status: \(exitStatus)") }
        if let detail { parts.append(detail) }
        return parts.joined(separator: "\n")
    }
}

extension MacUpError {
    /// A command ran but its result could not be used.
    public static func commandFailed(
        _ result: CommandResult,
        _ message: String,
        recoverySuggestion: String? = nil,
        redactor: Redactor = Redactor()
    ) -> MacUpError {
        let stderr = TextExcerpt.tail(of: result.standardErrorText, redactor: redactor)
        let stdout = TextExcerpt.tail(of: result.standardOutputText, maxLines: 6, redactor: redactor)
        return MacUpError(
            .commandFailed,
            message,
            detail: stderr ?? stdout,
            command: redactor.redact(result.invocation.displayString),
            exitStatus: result.exitStatus,
            recoverySuggestion: recoverySuggestion
        )
    }

    public static func parseFailed(
        _ message: String,
        detail: String? = nil,
        command: String? = nil
    ) -> MacUpError {
        MacUpError(
            .parseFailed,
            message,
            detail: detail,
            command: command,
            recoverySuggestion: "MacUp did not act on output it could not understand. Please report this with the provider version."
        )
    }

    /// Converts any error thrown inside MacUp into a `MacUpError`.
    public static func wrapping(_ error: any Error, context: String) -> MacUpError {
        if let error = error as? MacUpError { return error }
        if error is CancellationError { return MacUpError(.cancelled, "\(context) was cancelled.") }
        return MacUpError(.commandFailed, "\(context) failed.", detail: Redactor().redact(String(describing: error)))
    }
}
