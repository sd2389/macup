import Foundation

/// Why an AI request did not happen, or did not produce anything MacUp used.
///
/// Every message is a fixed sentence written here, never text built from the
/// request, so no message can carry the API key. The one exception is the
/// detail TypeSafe gives for a request it could not validate, which is
/// redacted, cut short, and made display-safe before it is kept (see
/// ``TypeSafeClient``).
public struct AIError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// AI help is switched off in the configuration.
        case disabled
        /// The configuration has errors, so AI help stays off.
        case configurationUnreadable
        /// No key in the Keychain and none in the environment.
        case noKey
        /// A key was found but cannot be what TypeSafe issues.
        case invalidKey
        /// The Keychain refused a read or a write.
        case keychain
        /// TypeSafe did not accept the key (HTTP 401).
        case unauthorized
        /// TypeSafe could not validate the request (HTTP 422).
        case invalidRequest
        /// Still rate limited after the retries MacUp allows (HTTP 429).
        case rateLimited
        /// Still overloaded after the retries MacUp allows (HTTP 529).
        case overloaded
        /// api.typesafe.ai could not be reached.
        case offline
        /// No answer within the time limit.
        case timedOut
        /// Any other status, or a response from somewhere MacUp did not send to.
        case serverError
        /// An answer MacUp could not read, or one that does not fit the questions.
        case unexpectedResponse
        /// The request would be larger than MacUp will send.
        case requestTooLarge
        case cancelled
    }

    public var kind: Kind
    /// One display-safe sentence.
    public var message: String
    /// A redacted, display-safe excerpt of what TypeSafe said, when it said something useful.
    public var detail: String?
    public var recoverySuggestion: String?
    public var statusCode: Int?

    public init(
        _ kind: Kind,
        _ message: String,
        detail: String? = nil,
        recoverySuggestion: String? = nil,
        statusCode: Int? = nil
    ) {
        self.kind = kind
        self.message = message
        self.detail = detail
        self.recoverySuggestion = recoverySuggestion
        self.statusCode = statusCode
    }

    public var description: String {
        [message, detail, recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
    }

    // MARK: The sentences

    public static let disabled = AIError(
        .disabled,
        "AI help from TypeSafe is off, so MacUp sent nothing.",
        recoverySuggestion: "Turn it on with `macup ai enable`, or on the Features screen in the app."
    )

    public static let configurationUnreadable = AIError(
        .configurationUnreadable,
        "MacUp could not read its configuration without errors, so AI help stays off and nothing was sent.",
        recoverySuggestion: "`macup config show` lists each problem."
    )

    public static let noKey = AIError(
        .noKey,
        "MacUp has no TypeSafe API key, so it sent nothing.",
        recoverySuggestion: "Save one with `macup ai key set`, or set TYPESAFE_API_KEY in your shell."
    )

    public static func invalidKey(from source: AIKeySource) -> AIError {
        AIError(
            .invalidKey,
            "The key \(source.phrase) does not look like a TypeSafe API key, so MacUp sent nothing.",
            recoverySuggestion: "Copy the key again from the TypeSafe console and save it with `macup ai key set`."
        )
    }

    public static let rejectedKeyText = AIError(
        .invalidKey,
        "That does not look like a TypeSafe API key: it should be one line of letters, digits, and punctuation, with no spaces.",
        recoverySuggestion: "Copy the key again from the TypeSafe console."
    )

    public static func keychain(_ status: OSStatus, reading: Bool) -> AIError {
        AIError(
            .keychain,
            reading
                ? "MacUp could not read its key from the Keychain (status \(status))."
                : "MacUp could not save the key in the Keychain (status \(status)).",
            recoverySuggestion: reading
                ? "If macOS asked whether MacUp may use the key, allow it and try again."
                : "Unlock your login keychain and try again."
        )
    }

    public static let unauthorized = AIError(
        .unauthorized,
        "TypeSafe did not accept the API key (HTTP 401), so nothing was answered.",
        recoverySuggestion: "Check the key in the TypeSafe console, then save it again with `macup ai key set`.",
        statusCode: 401
    )

    public static func invalidRequest(detail: String?) -> AIError {
        AIError(
            .invalidRequest,
            "TypeSafe could not process MacUp's request (HTTP 422), so nothing was answered.",
            detail: detail,
            recoverySuggestion: "This is most likely a problem in MacUp. Please report it with the output of `macup --version`.",
            statusCode: 422
        )
    }

    public static func rateLimited(attempts: Int, retryAfter: Int?) -> AIError {
        AIError(
            .rateLimited,
            "TypeSafe is limiting how often this key can ask (HTTP 429). MacUp tried \(attempts) \(attempts == 1 ? "time" : "times").",
            recoverySuggestion: retryAfter.map { "Try again in \($0) seconds." } ?? "Try again in a minute.",
            statusCode: 429
        )
    }

    public static func overloaded(attempts: Int) -> AIError {
        AIError(
            .overloaded,
            "TypeSafe is busy right now (HTTP 529). MacUp tried \(attempts) \(attempts == 1 ? "time" : "times").",
            recoverySuggestion: "Try again shortly.",
            statusCode: 529
        )
    }

    public static let offline = AIError(
        .offline,
        "MacUp could not reach \(TypeSafeEndpoint.host). This Mac may be offline.",
        recoverySuggestion: "Check the network connection and try again."
    )

    public static let timedOut = AIError(
        .timedOut,
        "TypeSafe did not answer within \(Int(TypeSafeEndpoint.requestTimeoutSeconds)) seconds.",
        recoverySuggestion: "Try again; nothing was changed."
    )

    public static func serverError(status: Int) -> AIError {
        AIError(
            .serverError,
            "TypeSafe answered with an unexpected status (HTTP \(status)), so MacUp used nothing from it.",
            recoverySuggestion: "Try again later.",
            statusCode: status
        )
    }

    public static let wrongHost = AIError(
        .serverError,
        "The answer did not come from \(TypeSafeEndpoint.host), so MacUp used nothing from it."
    )

    public static let unexpectedResponse = AIError(
        .unexpectedResponse,
        "MacUp could not read TypeSafe's answer, so it used none of it.",
        recoverySuggestion: "Try again. If it keeps happening, please report it with the output of `macup --version`."
    )

    public static let requestTooLarge = AIError(
        .requestTooLarge,
        "The request would be larger than MacUp sends, so it sent nothing."
    )

    public static let cancelled = AIError(.cancelled, "Cancelled. Nothing was changed.")
}
