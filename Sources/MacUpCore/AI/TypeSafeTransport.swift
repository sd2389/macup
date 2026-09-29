import Foundation

/// One HTTPS request to TypeSafe, exactly as MacUp built it.
///
/// It can only ever be addressed to ``TypeSafeEndpoint/systemOne``. Its
/// description, debug description, and mirror leave the Authorization header
/// out, so printing, logging, or dumping a request cannot leak the key.
public struct TypeSafeHTTPRequest: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let url: URL
    public let method: String
    public let body: Data
    private let authorization: String

    init(body: Data, key: TypeSafeAPIKey) {
        url = TypeSafeEndpoint.systemOne
        method = "POST"
        self.body = body
        authorization = key.authorizationValue
    }

    /// Every header MacUp sets. The fixed `Accept-Language` and `User-Agent`
    /// replace the ones the system would otherwise add, which name this Mac's
    /// language and operating system version.
    public var headers: [String: String] {
        [
            "Authorization": authorization,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Accept-Language": "en",
            "User-Agent": "MacUp/\(MacUp.version)",
        ]
    }

    public var description: String {
        "\(method) \(url.absoluteString) (\(body.count) bytes; Authorization \(Redactor.placeholder))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["url": url, "method": method, "bytes": body.count], displayStyle: .struct)
    }
}

/// What came back, before MacUp has decided whether to believe it.
public struct TypeSafeHTTPResponse: Sendable, Hashable {
    public var statusCode: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// Sends one request and returns the response, or throws an ``AIError``.
///
/// Behind a protocol so that no test ever reaches the network: tests hand the
/// client a transport that answers from recorded fixtures.
public protocol TypeSafeTransport: Sendable {
    func send(_ request: TypeSafeHTTPRequest) async throws -> TypeSafeHTTPResponse
}

/// Sends nothing. What every surface has until a real connection is wired in,
/// so a missing wire fails closed rather than open.
public struct UnavailableTypeSafeTransport: TypeSafeTransport {
    public init() {}

    public func send(_ request: TypeSafeHTTPRequest) async throws -> TypeSafeHTTPResponse {
        throw AIError.offline
    }
}

/// The real connection: HTTPS to api.typesafe.ai and nowhere else.
///
/// This is the only place in MacUp that opens a network connection of its own,
/// and `scripts/check-trust-invariants.sh` fails the build if networking
/// appears anywhere else. The session is ephemeral — no cookies, no cache, no
/// stored credentials — it refuses every redirect, so the Authorization header
/// can never follow a response somewhere else, and it is not even created
/// until the first request, so with AI help off it never exists.
public struct LiveTypeSafeTransport: TypeSafeTransport {
    public init() {}

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TypeSafeEndpoint.requestTimeoutSeconds
        configuration.timeoutIntervalForResource = TypeSafeEndpoint.requestTimeoutSeconds + 10
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: RedirectRefusal(), delegateQueue: nil)
    }()

    public func send(_ request: TypeSafeHTTPRequest) async throws -> TypeSafeHTTPResponse {
        guard Self.isPinned(request.url) else { throw AIError.wrongHost }
        var urlRequest = URLRequest(
            url: request.url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: TypeSafeEndpoint.requestTimeoutSeconds
        )
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body

        do {
            let (bytes, response) = try await Self.session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse, let url = http.url, Self.isPinned(url) else {
                throw AIError.wrongHost
            }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > TypeSafeEndpoint.maximumResponseBytes { throw AIError.unexpectedResponse }
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
            return TypeSafeHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
        } catch let error as AIError {
            throw error
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as URLError {
            throw Self.explain(error)
        } catch {
            throw AIError.offline
        }
    }

    static func isPinned(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == TypeSafeEndpoint.host && url.port == nil
    }

    static func explain(_ error: URLError) -> AIError {
        switch error.code {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return AIError(
                .serverError,
                "MacUp could not make a secure connection to \(TypeSafeEndpoint.host), so it sent nothing.",
                recoverySuggestion: "Check the date and time on this Mac, and whether a network filter is intercepting secure connections."
            )
        default:
            return .offline
        }
    }
}

/// Refuses every redirect. A 3xx then reaches the client as an unexpected
/// status, and the request, key and all, goes nowhere else.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
