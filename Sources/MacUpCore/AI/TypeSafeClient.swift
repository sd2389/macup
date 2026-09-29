import Foundation
import OSLog

extension Log {
    /// AI requests: what was asked of TypeSafe and how it went, never what
    /// was sent or the key it was sent with.
    public static let ai = Logger(subsystem: MacUp.identifier, category: "ai")
}

/// A TypeSafe API key. It prints as `<redacted>` however it is printed —
/// `description`, `debugDescription`, a mirror, string interpolation — so a
/// key cannot reach a log, an error, history, or diagnostics by accident.
public struct TypeSafeAPIKey: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let lengths = 8...512

    private let secret: String

    /// Accepts a key as pasted: surrounding whitespace and line breaks are
    /// dropped, and what is left must be one run of printable ASCII. That
    /// also keeps a line break from ever reaching an HTTP header.
    public init(validating raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.lengths.contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) })
        else { throw AIError.rejectedKeyText }
        secret = trimmed
    }

    public var description: String { Redactor.placeholder }
    public var debugDescription: String { "TypeSafeAPIKey(\(Redactor.placeholder))" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    var authorizationValue: String { "Bearer " + secret }

    /// The key as the Keychain stores it. Only the key store reads this.
    var keychainData: Data { Data(secret.utf8) }

    /// `text` with every occurrence of the key replaced. Applied to anything
    /// that came back from the network before MacUp keeps it.
    func scrubbing(_ text: String) -> String {
        text.replacingOccurrences(of: secret, with: Redactor.placeholder)
    }
}

/// Asks TypeSafe's System One model typed questions about a state.
///
/// One endpoint, fixed in ``TypeSafeEndpoint``. A request is validated before
/// it is sent and its answer is checked against its questions when it comes
/// back (``TypeSafeResponse/decode(_:for:)``). HTTP 429 and 529 are retried a
/// small, fixed number of times with a growing pause; nothing else is
/// retried, because repeating a request that was refused or failed would only
/// fail again.
public struct TypeSafeClient: Sendable {
    public struct RetryPolicy: Sendable, Hashable {
        /// Retries after the first attempt, so at most three requests.
        public var maximumRetries: Int
        public var initialDelay: Duration
        /// The longest pause MacUp will make before trying again. A
        /// `Retry-After` longer than this is reported rather than waited out.
        public var maximumDelay: Duration

        public init(maximumRetries: Int = 2, initialDelay: Duration = .milliseconds(500), maximumDelay: Duration = .seconds(5)) {
            self.maximumRetries = maximumRetries
            self.initialDelay = initialDelay
            self.maximumDelay = maximumDelay
        }

        public static let standard = RetryPolicy()

        /// The pause before the next attempt, or `nil` to stop trying.
        func delay(afterAttempt attempt: Int, retryAfterSeconds: Int?) -> Duration? {
            guard attempt <= maximumRetries else { return nil }
            if let retryAfterSeconds {
                let requested = Duration.seconds(retryAfterSeconds)
                return requested <= maximumDelay ? requested : nil
            }
            var delay = initialDelay
            for _ in 1..<attempt { delay *= 2 }
            return min(delay, maximumDelay)
        }
    }

    public var transport: any TypeSafeTransport
    public var key: TypeSafeAPIKey
    public var model: String
    public var retry: RetryPolicy
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        transport: any TypeSafeTransport,
        key: TypeSafeAPIKey,
        model: String = MacUpConfiguration.AISettings.defaultModel,
        retry: RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.key = key
        self.model = model
        self.retry = retry
        self.sleep = sleep
    }

    /// Sends one request and returns its checked answers. Throws ``AIError``
    /// and nothing else.
    public func ask(state: TypeSafeValue, questions: [String: TypeSafeQuestion]) async throws -> TypeSafeResponse {
        let request = TypeSafeRequest(model: model, state: state, questions: questions)
        guard request.isValid else { throw AIError.malformedRequest }
        let body: Data
        do {
            body = try request.encoded()
        } catch {
            throw AIError.malformedRequest
        }
        guard body.count <= TypeSafeEndpoint.maximumRequestBytes else { throw AIError.requestTooLarge }
        let http = TypeSafeHTTPRequest(body: body, key: key)

        var attempt = 0
        while true {
            attempt += 1
            if Task.isCancelled { throw AIError.cancelled }
            let started = ContinuousClock.now
            let response: TypeSafeHTTPResponse
            do {
                response = try await transport.send(http)
            } catch let error as AIError {
                Self.record(status: nil, attempt: attempt, questions: questions.count, since: started)
                throw error
            } catch {
                Self.record(status: nil, attempt: attempt, questions: questions.count, since: started)
                throw AIError.offline
            }
            Self.record(status: response.statusCode, attempt: attempt, questions: questions.count, since: started)

            switch response.statusCode {
            case 200..<300:
                return try TypeSafeResponse.decode(response.body, for: request)
            case 401:
                throw AIError.unauthorized
            case 422:
                throw AIError.invalidRequest(detail: excerpt(of: response.body))
            case 429, 529:
                let retryAfter = Self.retryAfterSeconds(response.headers["retry-after"])
                guard let delay = retry.delay(afterAttempt: attempt, retryAfterSeconds: retryAfter) else {
                    throw response.statusCode == 429
                        ? AIError.rateLimited(attempts: attempt, retryAfter: retryAfter)
                        : AIError.overloaded(attempts: attempt)
                }
                do {
                    try await sleep(delay)
                } catch {
                    throw AIError.cancelled
                }
            default:
                throw AIError.serverError(status: response.statusCode)
            }
        }
    }

    /// `Retry-After` as whole seconds. The HTTP-date form is ignored and the
    /// usual pause applies instead.
    static func retryAfterSeconds(_ value: String?) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), let seconds = Int(value), seconds >= 0 else { return nil }
        return seconds
    }

    /// What TypeSafe said was wrong with a request, cut short, with the key
    /// and anything else secret-shaped taken out, and made safe to print.
    func excerpt(of body: Data) -> String? {
        var text = String(decoding: body.prefix(2_000), as: UTF8.self)
        if let object = JSONValue.parse(body)?.objectValue,
           let detail = (object["detail"] ?? object["message"] ?? object["error"])?.stringValue {
            text = detail
        }
        let cleaned = TerminalText.sanitize(Redactor().redact(key.scrubbing(text)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }

    /// The only thing MacUp logs about a request: its outcome, as numbers.
    /// Nothing here can see the body or the key.
    private static func record(status: Int?, attempt: Int, questions: Int, since started: ContinuousClock.Instant) {
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        if let status {
            Log.ai.info("TypeSafe answered HTTP \(status) to \(questions) questions in \(milliseconds) ms (attempt \(attempt))")
        } else {
            Log.ai.info("TypeSafe could not be reached (attempt \(attempt), \(milliseconds) ms)")
        }
    }
}

extension AIError {
    static let malformedRequest = AIError(
        .invalidRequest,
        "MacUp built a request it will not send, so nothing was sent.",
        recoverySuggestion: "This is a problem in MacUp. Please report it with the output of `macup --version`."
    )
}
