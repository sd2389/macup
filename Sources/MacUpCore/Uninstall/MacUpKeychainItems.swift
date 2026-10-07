import Foundation
import Security

/// The Keychain items MacUp may have left behind, for uninstalling MacUp.
///
/// Today MacUp stores nothing in the Keychain. An earlier build kept an API
/// key there, as a generic password with the service below, and an uninstall
/// that leaves it would leave a residue the person cannot see. So this can
/// ask whether that item exists and delete it — and nothing else: it never
/// reads a secret, never adds or changes an item, and never touches an item
/// with any other service. `scripts/check-trust-invariants.sh` keeps every
/// Keychain call in this one file.
public protocol MacUpKeychainItemStoring: Sendable {
    /// Whether the item exists. Asks for its attributes only, so macOS has
    /// no secret to ask permission for.
    func hasLeftoverItem() -> Bool
    /// Deletes every generic password with MacUp's service. Returns whether
    /// there was one.
    func deleteLeftoverItem() throws -> Bool
}

/// The login keychain.
public struct SystemMacUpKeychainItems: MacUpKeychainItemStoring {
    /// The service an earlier MacUp saved its TypeSafe key under.
    public static let service = "dev.macup.typesafe"

    public init() {}

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
    }

    public func hasLeftoverItem() -> Bool {
        var search = query
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        return SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess
    }

    public func deleteLeftoverItem() throws -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            let reason = (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
            throw MacUpError(.commandFailed, "MacUp could not delete its Keychain item: \(TerminalText.sanitize(reason)).")
        }
    }
}

