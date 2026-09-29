import Foundation
import Security

/// Where the key MacUp would use came from.
public enum AIKeySource: String, Sendable, Hashable, Codable {
    /// MacUp's own item in the login keychain.
    case keychain
    /// The `TYPESAFE_API_KEY` environment variable.
    case environment

    public var displayName: String {
        switch self {
        case .keychain: "the Keychain (\(KeychainAPIKeyStore.service))"
        case .environment: "the \(AIKeyLookup.environmentVariable) environment variable"
        }
    }

    var phrase: String {
        switch self {
        case .keychain: "in the Keychain"
        case .environment: "in \(AIKeyLookup.environmentVariable)"
        }
    }
}

/// Stores MacUp's TypeSafe key. Behind a protocol so no test ever reads or
/// writes the real Keychain.
public protocol APIKeyStoring: Sendable {
    /// Whether a key is stored. Reads no secret, so macOS has nothing to ask
    /// about, and status screens can call it freely.
    func containsKey() throws -> Bool
    /// The stored key, or `nil` when there is none. Reading it may make macOS
    /// ask whether MacUp may use it; that prompt is macOS's, not MacUp's.
    /// Throws when what is stored cannot be a key.
    func readKey() throws -> TypeSafeAPIKey?
    func saveKey(_ key: TypeSafeAPIKey) throws
    /// Returns whether a key was there to delete.
    @discardableResult
    func deleteKey() throws -> Bool
}

/// The key as a generic password in the login keychain, under
/// ``service`` and ``account``. Nothing else in MacUp stores it: not the
/// configuration file, not history, not diagnostics.
public struct KeychainAPIKeyStore: APIKeyStoring {
    public static let service = "dev.macup.typesafe"
    public static let account = "api-key"

    public init() {}

    private var identity: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func containsKey() throws -> Bool {
        var query = identity
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw AIError.keychain(status, reading: true)
        }
    }

    public func readKey() throws -> TypeSafeAPIKey? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8),
                  let key = try? TypeSafeAPIKey(validating: text)
            else { throw AIError.invalidKey(from: .keychain) }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw AIError.keychain(status, reading: true)
        }
    }

    public func saveKey(_ key: TypeSafeAPIKey) throws {
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: key.keychainData] as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = identity
            item[kSecValueData as String] = key.keychainData
            item[kSecAttrLabel as String] = "MacUp: TypeSafe API key"
            item[kSecAttrDescription as String] = "API key"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw AIError.keychain(added, reading: false) }
        default:
            throw AIError.keychain(update, reading: false)
        }
    }

    @discardableResult
    public func deleteKey() throws -> Bool {
        let status = SecItemDelete(identity as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw AIError.keychain(status, reading: false)
        }
    }
}

/// A key store with nothing in it that cannot hold anything. What a surface
/// has until a real Keychain is wired in.
public struct UnavailableAPIKeyStore: APIKeyStoring {
    public init() {}
    public func containsKey() throws -> Bool { false }
    public func readKey() throws -> TypeSafeAPIKey? { nil }
    public func saveKey(_ key: TypeSafeAPIKey) throws {
        throw AIError(.keychain, "This copy of MacUp has no Keychain to save the key in.")
    }
    public func deleteKey() throws -> Bool { false }
}

/// What MacUp knows about the key without reading it.
public struct AIKeyStatus: Sendable, Hashable, Codable {
    /// Where the key MacUp would use comes from, or `nil` when there is none.
    public var source: AIKeySource?
    public var keychainHasKey: Bool
    /// `TYPESAFE_API_KEY` is set to something that could be a key.
    public var environmentHasKey: Bool
    /// Display-safe sentences about keys MacUp found but cannot use.
    public var problems: [String]

    public init(source: AIKeySource?, keychainHasKey: Bool, environmentHasKey: Bool, problems: [String] = []) {
        self.source = source
        self.keychainHasKey = keychainHasKey
        self.environmentHasKey = environmentHasKey
        self.problems = problems
    }
}

/// Finds the key: MacUp's Keychain item first, then `TYPESAFE_API_KEY`.
///
/// The Keychain wins because saving a key there is something the user did in
/// MacUp; the variable may be left over from something else. A Keychain item
/// that cannot be read is an error, not a reason to use a different key.
public struct AIKeyLookup: Sendable {
    public static let environmentVariable = "TYPESAFE_API_KEY"

    public var store: any APIKeyStoring
    /// The CLI's own environment, or the login shell's in the app.
    public var environment: [String: String]

    public init(store: any APIKeyStoring, environment: [String: String]) {
        self.store = store
        self.environment = environment
    }

    public func status() -> AIKeyStatus {
        var problems: [String] = []
        var keychainHasKey = false
        do {
            keychainHasKey = try store.containsKey()
        } catch let error as AIError {
            problems.append(error.message)
        } catch {
            problems.append("MacUp could not look in the Keychain.")
        }

        var environmentHasKey = false
        if let raw = environment[Self.environmentVariable], !raw.isEmpty {
            if (try? TypeSafeAPIKey(validating: raw)) != nil {
                environmentHasKey = true
            } else {
                problems.append("\(Self.environmentVariable) is set, but not to something that could be a TypeSafe API key.")
            }
        }
        let source: AIKeySource? = keychainHasKey ? .keychain : environmentHasKey ? .environment : nil
        return AIKeyStatus(
            source: source,
            keychainHasKey: keychainHasKey,
            environmentHasKey: environmentHasKey,
            problems: problems
        )
    }

    /// The key to send, and where it came from. Throws ``AIError``.
    public func resolve() throws -> (key: TypeSafeAPIKey, source: AIKeySource) {
        if try store.containsKey(), let key = try store.readKey() {
            return (key, .keychain)
        }
        if let raw = environment[Self.environmentVariable], !raw.isEmpty {
            guard let key = try? TypeSafeAPIKey(validating: raw) else { throw AIError.invalidKey(from: .environment) }
            return (key, .environment)
        }
        throw AIError.noKey
    }
}
