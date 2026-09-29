import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A pause MacUp asked for, recorded instead of slept.
final class RecordedSleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [Duration] = []

    var delays: [Duration] { lock.withLock { _delays } }

    func sleep(_ delay: Duration) async throws {
        lock.withLock { _delays.append(delay) }
    }
}

@Suite("The TypeSafe client")
struct TypeSafeClientTests {
    /// Obviously not a real key. No test has, sends, or needs one.
    static let keyText = "ts_test_not_a_real_key_0123456789"

    static let questions: [String: TypeSafeQuestion] = [
        "department": .choice(
            "Which team should handle this?",
            options: [
                .init("billing", "Payments, invoicing, refunds"),
                .init("technical", "Bugs, outages, integrations"),
                .init("sales", nil),
            ]
        ),
        "is_urgent": .noul("Does this convey urgency?", yes: "Explicitly time-sensitive", no: "No urgency expressed"),
        "frustration": .score("How frustrated is the customer?", levels: ["Calm", "Frustrated", "Very angry"]),
    ]

    private func client(_ transport: FakeTypeSafeTransport, sleeps: RecordedSleeps = RecordedSleeps()) throws -> TypeSafeClient {
        TypeSafeClient(
            transport: transport,
            key: try TypeSafeAPIKey(validating: Self.keyText),
            sleep: { try await sleeps.sleep($0) }
        )
    }

    private func ask(_ transport: FakeTypeSafeTransport, sleeps: RecordedSleeps = RecordedSleeps()) async throws -> TypeSafeResponse {
        try await client(transport, sleeps: sleeps).ask(state: "Help! My payouts have been failing for 3 days.", questions: Self.questions)
    }

    private func fixture(_ name: String, status: Int = 200) throws -> TypeSafeHTTPResponse {
        TypeSafeHTTPResponse(statusCode: status, body: try Fixture.data("typesafe/\(name)"))
    }

    // MARK: What is sent

    @Test("A request is exactly the documented shape, with every criteria form")
    func requestShape() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture("all-primitives.json"))
        _ = try await ask(transport)

        let request = try #require(transport.requests.first)
        #expect(request.url.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(request.method == "POST")
        let body = try #require(transport.bodies.first)
        #expect(Set(body.keys) == ["model", "state", "questions"])
        #expect(body["model"] as? String == "jev-latest")
        #expect(body["state"] as? String == "Help! My payouts have been failing for 3 days.")

        let questions = try #require(body["questions"] as? [String: [String: Any]])
        let department = try #require(questions["department"])
        #expect(department["type"] as? String == "choice")
        let criteria = try #require(department["criteria"] as? [String: Any])
        #expect(criteria["billing"] as? String == "Payments, invoicing, refunds")
        #expect(criteria["sales"] is NSNull, "an option with no description is sent as null")

        let urgent = try #require(questions["is_urgent"])
        #expect(urgent["type"] as? String == "noul")
        #expect((urgent["criteria"] as? [String: String]) == ["true": "Explicitly time-sensitive", "false": "No urgency expressed"])

        let score = try #require(questions["frustration"])
        #expect(score["type"] as? String == "score")
        #expect(score["criteria"] as? [String] == ["Calm", "Frustrated", "Very angry"])
    }

    @Test("Every request carries the key only in its Authorization header, and names nothing about this Mac")
    func headers() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture("all-primitives.json"))
        _ = try await ask(transport)

        let headers = try #require(transport.requests.first).headers
        #expect(headers["Authorization"] == "Bearer \(Self.keyText)")
        #expect(headers["Content-Type"] == "application/json")
        #expect(headers["Accept-Language"] == "en")
        #expect(headers["User-Agent"] == "MacUp/\(MacUp.version)")
        #expect(!String(decoding: try #require(transport.requests.first).body, as: UTF8.self).contains(Self.keyText))
    }

    @Test("A question MacUp built wrongly, or a request too big to be one of MacUp's, is never sent")
    func invalidRequestsAreNotSent() async throws {
        let transport = FakeTypeSafeTransport()
        let client = try client(transport)
        let one = await #expect(throws: AIError.self) {
            _ = try await client.ask(state: "x", questions: ["only": .choice("Pick one", options: [.init("a", nil)])])
        }
        #expect(one?.kind == .invalidRequest)

        let huge = TypeSafeValue.string(String(repeating: "x", count: TypeSafeEndpoint.maximumRequestBytes + 1))
        let big = await #expect(throws: AIError.self) {
            _ = try await client.ask(state: huge, questions: ["q": .noul("Is this long?")])
        }
        #expect(big?.kind == .requestTooLarge)
        #expect(transport.requests.isEmpty)
    }

    // MARK: What comes back

    @Test("All three primitives decode from a documented response, ignoring fields MacUp does not use")
    func decodesAllPrimitives() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture("all-primitives.json"))
        let response = try await ask(transport)

        #expect(response.model == "jev-1.13.0")
        let department = try #require(response.choice("department"))
        #expect(department.choice == "billing")
        #expect(department.probability(of: "technical") == 0.12)
        #expect(department.confidence == 0.81)
        #expect(department.ranked.map(\.option) == ["billing", "technical", "sales"])
        #expect(response.noul("is_urgent") == 0.95)
        let score = try #require(response.score("frustration"))
        #expect(score.score == 1.05)
        #expect(score.legend["2"] == "Very angry")
        #expect(score.confidence == 0.92)
        #expect(response.usage == TypeSafeUsage(inputTokens: 318, outputTokens: 34))
    }

    @Test(
        "An answer that does not fit its question is not used at all",
        arguments: [
            "choice-not-offered.json", "probability-out-of-range.json", "missing-answer.json", "wrong-type.json",
            "unasked-answer.json", "choice-contradicts-itself.json", "probabilities-do-not-add-up.json", "not-json.txt",
        ]
    )
    func failsClosed(_ name: String) async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture(name))
        let error = await #expect(throws: AIError.self) { _ = try await ask(transport) }
        #expect(error?.kind == .unexpectedResponse)
        #expect(transport.requests.count == 1, "a reply MacUp cannot read is not worth asking for again")
    }

    // MARK: Statuses

    @Test("401 is a key TypeSafe did not accept, and is not retried")
    func unauthorized() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(TypeSafeReply.status(401, body: #"{"detail": "invalid api key"}"#))
        let error = await #expect(throws: AIError.self) { _ = try await ask(transport) }
        #expect(error?.kind == .unauthorized)
        #expect(error?.statusCode == 401)
        #expect(error?.message.contains("did not accept the API key") == true)
        #expect(transport.requests.count == 1)
    }

    @Test("422 keeps TypeSafe's reason, without anything secret-shaped in it, and is not retried")
    func validationFailure() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture("validation-error-422.json", status: 422))
        let error = try #require(await #expect(throws: AIError.self) { _ = try await ask(transport) })
        #expect(error.kind == .invalidRequest)
        #expect(error.detail?.contains("expected at most 255 options") == true)
        #expect(error.detail?.contains("ts_live_fixture_key") == false)
        #expect(transport.requests.count == 1)
    }

    @Test("429 and 529 are retried after a growing pause, then reported")
    func retriesThenReports() async throws {
        for status in [429, 529] {
            let transport = FakeTypeSafeTransport()
            transport.answerEveryRequest { _ in TypeSafeReply.status(status) }
            let sleeps = RecordedSleeps()
            let error = await #expect(throws: AIError.self) { _ = try await ask(transport, sleeps: sleeps) }
            #expect(error?.kind == (status == 429 ? .rateLimited : .overloaded))
            #expect(error?.message.contains("tried 3 times") == true)
            #expect(transport.requests.count == 3, "one attempt and two retries, never more")
            #expect(sleeps.delays == [.milliseconds(500), .seconds(1)])
        }
    }

    @Test("A retry that works is invisible to the caller")
    func retryThatWorks() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(TypeSafeReply.status(529))
        transport.enqueue(try fixture("all-primitives.json"))
        let sleeps = RecordedSleeps()
        let response = try await ask(transport, sleeps: sleeps)
        #expect(response.noul("is_urgent") == 0.95)
        #expect(transport.requests.count == 2)
        #expect(sleeps.delays == [.milliseconds(500)])
    }

    @Test("Retry-After is honoured when it is short, and reported rather than waited out when it is long")
    func retryAfter() async throws {
        let short = FakeTypeSafeTransport()
        short.enqueue(TypeSafeReply.status(429, headers: ["Retry-After": "2"]))
        short.enqueue(try fixture("all-primitives.json"))
        let shortSleeps = RecordedSleeps()
        _ = try await ask(short, sleeps: shortSleeps)
        #expect(shortSleeps.delays == [.seconds(2)])

        let long = FakeTypeSafeTransport()
        long.enqueue(TypeSafeReply.status(429, headers: ["Retry-After": "60"]))
        let longSleeps = RecordedSleeps()
        let error = await #expect(throws: AIError.self) { _ = try await ask(long, sleeps: longSleeps) }
        #expect(error?.recoverySuggestion == "Try again in 60 seconds.")
        #expect(long.requests.count == 1)
        #expect(longSleeps.delays.isEmpty)
    }

    @Test("Any other status is reported and not retried")
    func otherStatus() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(TypeSafeReply.status(503))
        let error = await #expect(throws: AIError.self) { _ = try await ask(transport) }
        #expect(error?.kind == .serverError)
        #expect(error?.statusCode == 503)
        #expect(transport.requests.count == 1)
    }

    @Test("No network is a plain sentence, and is not retried")
    func offline() async throws {
        let transport = FakeTypeSafeTransport()
        transport.enqueue(failing: .offline)
        let error = await #expect(throws: AIError.self) { _ = try await ask(transport) }
        #expect(error?.kind == .offline)
        #expect(error?.message == "MacUp could not reach api.typesafe.ai. This Mac may be offline.")
        #expect(transport.requests.count == 1)
    }

    // MARK: The key

    @Test("The key never appears in anything MacUp prints, logs, or reports")
    func keyNeverEscapes() async throws {
        let key = try TypeSafeAPIKey(validating: Self.keyText)
        var dumped = ""
        dump(key, to: &dumped)
        for text in [String(describing: key), String(reflecting: key), "\(key)", dumped] {
            #expect(!text.contains(Self.keyText))
        }

        let transport = FakeTypeSafeTransport()
        transport.enqueue(try fixture("all-primitives.json"))
        _ = try await ask(transport)
        let request = try #require(transport.requests.first)
        var dumpedRequest = ""
        dump(request, to: &dumpedRequest)
        for text in [String(describing: request), String(reflecting: request), dumpedRequest] {
            #expect(!text.contains(Self.keyText), "\(text)")
        }

        // Every way a request can fail, echoing the key back where it can.
        let echo = #"{"detail": "bad header Authorization: Bearer \#(Self.keyText)"}"#
        for response in [401, 422, 429, 500, 529].map({ TypeSafeReply.status($0, body: echo) }) {
            let failing = FakeTypeSafeTransport()
            failing.answerEveryRequest { _ in response }
            let error = try #require(await #expect(throws: AIError.self) { _ = try await ask(failing) })
            #expect(!String(describing: error).contains(Self.keyText))
            let encoded = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
            #expect(!encoded.contains(Self.keyText))
        }
    }

    @Test("A key is one line of printable text: pasted whitespace is dropped, anything else is refused")
    func keyValidation() throws {
        let pasted = try TypeSafeAPIKey(validating: "  \(Self.keyText)\n")
        #expect(pasted == (try TypeSafeAPIKey(validating: Self.keyText)))
        for bad in ["", "short", "has space inside 0123456789", "line\nbreak0123456789", "tab\there0123456789", "é_not_ascii_0123456789"] {
            #expect(throws: AIError.self) { _ = try TypeSafeAPIKey(validating: bad) }
        }
    }

    @Test("The real transport only ever talks HTTPS to api.typesafe.ai")
    func pinnedHost() throws {
        #expect(LiveTypeSafeTransport.isPinned(TypeSafeEndpoint.systemOne))
        for other in ["http://api.typesafe.ai/v1/systemone", "https://api.typesafe.ai.example.com/v1/systemone",
                      "https://evil.example/v1/systemone", "https://api.typesafe.ai:8443/v1/systemone"] {
            #expect(!LiveTypeSafeTransport.isPinned(try #require(URL(string: other))))
        }
        #expect(LiveTypeSafeTransport.explain(URLError(.notConnectedToInternet)).kind == .offline)
        #expect(LiveTypeSafeTransport.explain(URLError(.timedOut)).kind == .timedOut)
        #expect(LiveTypeSafeTransport.explain(URLError(.serverCertificateUntrusted)).message.contains("secure connection"))
    }
}
