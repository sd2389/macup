import Foundation

/// Whether AI help can send anything right now, and why or why not. Working
/// it out reads no secret and sends nothing.
public struct AIStatus: Sendable, Hashable, Codable {
    /// What the configuration says.
    public var enabled: Bool
    /// False when the configuration has errors, which keeps AI help off.
    public var configurationReadable: Bool
    public var model: String
    public var key: AIKeyStatus
    public var host: String
    /// True only when every condition for sending holds.
    public var isActive: Bool
    /// One display-safe sentence.
    public var summary: String

    public init(enabled: Bool, configurationReadable: Bool, model: String, key: AIKeyStatus) {
        self.enabled = enabled
        self.configurationReadable = configurationReadable
        self.model = model
        self.key = key
        host = TypeSafeEndpoint.host
        isActive = enabled && configurationReadable && key.source != nil
        if !configurationReadable {
            summary = "Off: the configuration has errors, so AI help stays off until they are fixed."
        } else if !enabled {
            summary = key.source == nil
                ? "Off. Add a TypeSafe API key first; nothing is sent until you turn AI help on."
                : "Off. A key is ready; nothing is sent until you turn AI help on."
        } else if key.source == nil {
            summary = "On, but MacUp has no usable TypeSafe API key, so it sends nothing."
        } else {
            summary = "On. MacUp asks TypeSafe only when you ask it something."
        }
    }
}

extension AIStatus {
    /// Why nothing can be sent right now, or `nil` when a request may go.
    /// Lets a caller refuse before doing any work, such as a check, that
    /// would only end in the same refusal.
    public var refusal: AIError? {
        if !configurationReadable { return .configurationUnreadable }
        if !enabled { return .disabled }
        if key.source == nil { return .noKey }
        return nil
    }
}

/// The result of `macup ai test` and Test Connection.
public struct AIConnectionTest: Sendable, Hashable, Codable {
    /// The versioned model that answered.
    public var model: String
    public var milliseconds: Int
    public var keySource: AIKeySource
    public var inputTokens: Int?

    public init(model: String, milliseconds: Int, keySource: AIKeySource, inputTokens: Int?) {
        self.model = model
        self.milliseconds = milliseconds
        self.keySource = keySource
        self.inputTokens = inputTokens
    }
}

/// Everything AI help needs from outside MacUp, and the one gate every
/// request passes through.
///
/// Nothing reaches the network unless ``client(_:environment:)`` hands out a
/// client, and it does so only when the configuration was read without errors,
/// AI help is on in it, and a usable key exists. Every caller asks for a
/// client because the user just did something — pressed a button, ran a
/// command — so there is no background request to switch off.
public struct AIService: Sendable {
    public var transport: any TypeSafeTransport
    public var keyStore: any APIKeyStoring
    public var estimates: @Sendable (MacUpPaths) -> any AIEstimateCaching
    public var retry: TypeSafeClient.RetryPolicy
    public var sleep: @Sendable (Duration) async throws -> Void
    public var now: @Sendable () -> Date

    public init(
        transport: any TypeSafeTransport,
        keyStore: any APIKeyStoring,
        estimates: @escaping @Sendable (MacUpPaths) -> any AIEstimateCaching = { AIEstimateFile(paths: $0) },
        retry: TypeSafeClient.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.estimates = estimates
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    /// The real network and the real Keychain.
    public static func live() -> AIService {
        AIService(transport: LiveTypeSafeTransport(), keyStore: KeychainAPIKeyStore())
    }

    /// No network, no Keychain, nothing kept. What a surface has until it is
    /// wired to the real ones, so a missing wire sends nothing.
    public static let unavailable = AIService(
        transport: UnavailableTypeSafeTransport(),
        keyStore: UnavailableAPIKeyStore(),
        estimates: { _ in InMemoryAIEstimateCache() }
    )

    public func status(_ configuration: LoadedConfiguration, environment: [String: String]) -> AIStatus {
        AIStatus(
            enabled: configuration.configuration.aiSettings.enabled,
            configurationReadable: !configuration.hasErrors,
            model: configuration.configuration.aiSettings.model,
            key: AIKeyLookup(store: keyStore, environment: environment).status()
        )
    }

    /// Whether cached estimates should shape what MacUp shows. Only while AI
    /// help is on in a readable configuration: with it off, MacUp behaves as
    /// though it had never asked.
    public func appliesEstimates(_ configuration: LoadedConfiguration) -> Bool {
        !configuration.hasErrors && configuration.configuration.aiSettings.enabled
    }

    /// A client, when every condition for sending holds. Throws ``AIError``
    /// otherwise, and nothing has been sent.
    public func client(_ configuration: LoadedConfiguration, environment: [String: String]) throws -> (client: TypeSafeClient, keySource: AIKeySource) {
        guard !configuration.hasErrors else { throw AIError.configurationUnreadable }
        let settings = configuration.configuration.aiSettings
        guard settings.enabled else { throw AIError.disabled }
        let (key, source) = try AIKeyLookup(store: keyStore, environment: environment).resolve()
        return (TypeSafeClient(transport: transport, key: key, model: settings.model, retry: retry, sleep: sleep), source)
    }

    /// One tiny request that says nothing about this Mac.
    public func testConnection(_ configuration: LoadedConfiguration, environment: [String: String]) async throws -> AIConnectionTest {
        let (client, source) = try client(configuration, environment: environment)
        let started = ContinuousClock.now
        let response = try await client.ask(
            state: "MacUp connection test.",
            questions: ["connection_test": .noul("Is this text a connection test?")]
        )
        let elapsed = started.duration(to: .now)
        return AIConnectionTest(
            model: response.model,
            milliseconds: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
            keySource: source,
            inputTokens: response.usage?.inputTokens
        )
    }
}
