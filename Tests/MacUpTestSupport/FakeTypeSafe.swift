import Foundation
import MacUpCore

/// A TypeSafe that answers from a script and records every request. No test
/// ever reaches the network: an unscripted request is answered with an error,
/// so a test that sends something it did not mean to fails loudly.
public final class FakeTypeSafeTransport: TypeSafeTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (TypeSafeHTTPRequest) throws -> TypeSafeHTTPResponse

    private let lock = NSLock()
    private var queue: [Handler] = []
    private var fallback: Handler?
    private var _requests: [TypeSafeHTTPRequest] = []

    public init() {}

    /// Answers the next request with `response`.
    public func enqueue(_ response: TypeSafeHTTPResponse) {
        lock.withLock { queue.append { _ in response } }
    }

    /// Answers the next request by throwing `error`, as the real transport
    /// does when the network is not there.
    public func enqueue(failing error: AIError) {
        lock.withLock { queue.append { _ in throw error } }
    }

    /// Answers every request that has no queued answer.
    public func answerEveryRequest(_ handler: @escaping Handler) {
        lock.withLock { fallback = handler }
    }

    public func send(_ request: TypeSafeHTTPRequest) async throws -> TypeSafeHTTPResponse {
        let handler: Handler? = lock.withLock {
            _requests.append(request)
            return queue.isEmpty ? fallback : queue.removeFirst()
        }
        guard let handler else {
            throw AIError(.offline, "FakeTypeSafeTransport has no answer scripted for this request.")
        }
        return try handler(request)
    }

    public var requests: [TypeSafeHTTPRequest] { lock.withLock { _requests } }

    /// The request bodies, parsed.
    public var bodies: [[String: Any]] {
        requests.compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
    }
}

/// A key store in memory. The real Keychain is never touched by a test.
public final class FakeAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TypeSafeAPIKey?
    private var _reads = 0
    /// Thrown by every call, standing in for a Keychain that refuses.
    public var failure: AIError?

    /// `key` must look like a key; tests use obviously fake ones.
    public init(key: String? = nil) {
        // A malformed test key is a mistake in the test, not a case to handle.
        // swiftlint:disable:next force_try
        stored = key.map { try! TypeSafeAPIKey(validating: $0) }
    }

    public var key: TypeSafeAPIKey? { lock.withLock { stored } }
    /// How many times the secret itself was read.
    public var reads: Int { lock.withLock { _reads } }

    public func containsKey() throws -> Bool {
        if let failure { throw failure }
        return lock.withLock { stored != nil }
    }

    public func readKey() throws -> TypeSafeAPIKey? {
        if let failure { throw failure }
        return lock.withLock {
            _reads += 1
            return stored
        }
    }

    public func saveKey(_ key: TypeSafeAPIKey) throws {
        if let failure { throw failure }
        lock.withLock { stored = key }
    }

    public func deleteKey() throws -> Bool {
        if let failure { throw failure }
        return lock.withLock {
            defer { stored = nil }
            return stored != nil
        }
    }
}

/// Builds TypeSafe replies shaped like the documented examples
/// (https://docs.typesafe.ai/api.md).
public enum TypeSafeReply {
    public static let model = "jev-1.13.0"

    public static func noul(_ probability: Double) -> [String: Any] {
        ["type": "noul", "noul": probability]
    }

    /// A Choice answer: `winner` gets `probability`, the rest is spread over
    /// the other options, and confidence follows the documented
    /// approximation `(n × max − 1) / (n − 1)`.
    public static func choice(_ winner: String, _ probability: Double = 0.95, over options: [String]) -> [String: Any] {
        let others = options.filter { $0 != winner }
        let rest = others.isEmpty ? 0 : (1 - probability) / Double(others.count)
        var probabilities: [String: Double] = [winner: probability]
        for option in others { probabilities[option] = rest }
        let count = Double(max(options.count, 2))
        let confidence = max(0, min(1, (count * probability - 1) / (count - 1)))
        return ["type": "choice", "choice": winner, "probabilities": probabilities, "confidence": confidence]
    }

    /// A Choice answer with the probabilities given.
    public static func choice(_ probabilities: [String: Double], confidence: Double) -> [String: Any] {
        let winner = probabilities.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
        return ["type": "choice", "choice": winner, "probabilities": probabilities, "confidence": confidence]
    }

    public static func body(_ answers: [String: [String: Any]], model: String = model) -> Data {
        let object: [String: Any] = [
            "model": model,
            "answers": answers,
            "usage": ["input_tokens": 312, "output_tokens": 20],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    public static func http(_ answers: [String: [String: Any]], status: Int = 200) -> TypeSafeHTTPResponse {
        TypeSafeHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: body(answers))
    }

    public static func status(_ code: Int, body: String = "{}", headers: [String: String] = [:]) -> TypeSafeHTTPResponse {
        TypeSafeHTTPResponse(statusCode: code, headers: headers, body: Data(body.utf8))
    }

    /// Answers any request by reading its questions: each Choice gets the
    /// option `choose` returns for its id (or its first option), each Noul
    /// `noul` for its id (or 0.1). Lets a test script the meaning of an answer
    /// without restating every option MacUp offered.
    public static func answering(
        choose: @escaping @Sendable (String, [String]) -> (String, Double)? = { _, _ in nil },
        noul: @escaping @Sendable (String) -> Double? = { _ in nil }
    ) -> FakeTypeSafeTransport.Handler {
        { request in
            guard let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let questions = body["questions"] as? [String: [String: Any]]
            else { return status(422, body: #"{"detail": "not a request"}"#) }
            var answers: [String: [String: Any]] = [:]
            for (id, question) in questions {
                switch question["type"] as? String {
                case "choice":
                    let options = ((question["criteria"] as? [String: Any]) ?? [:]).keys.sorted()
                    let (winner, probability) = choose(id, options) ?? (options.first ?? "", 0.95)
                    answers[id] = choice(winner, probability, over: options)
                case "noul":
                    answers[id] = TypeSafeReply.noul(noul(id) ?? 0.1)
                default:
                    answers[id] = ["type": "score", "score": 0, "legend": ["0": "low", "1": "high"], "probabilities": ["0": 1.0, "1": 0.0], "confidence": 1.0]
                }
            }
            return http(answers)
        }
    }
}
