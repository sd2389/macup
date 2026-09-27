import Foundation
import LocalAuthentication

/// The biometric sensor macOS reports for this device.
///
/// MacUp never assumes which one it is. The same code path serves Touch ID
/// today and Face ID or Optic ID on any device that has them: the name shown
/// to the user comes from the system, not from a constant in MacUp.
public enum BiometryKind: String, Sendable, Hashable, Codable, CaseIterable {
    case touchID
    case faceID
    case opticID
    /// No biometric sensor, or one macOS did not name.
    case none

    public var displayName: String {
        switch self {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        case .none: return "No biometric sensor"
        }
    }
}

/// What this Mac can do, read from macOS. Building it changes nothing and
/// shows no prompt.
public struct BiometricCapability: Sendable, Hashable, Codable {
    public var kind: BiometryKind
    /// Whether a biometric check would work right now.
    public var isAvailable: Bool
    /// Whether a password (or Apple Watch) can stand in for the sensor.
    public var hasFallback: Bool
    /// Why biometrics are unavailable, in macOS's own words. Sanitized.
    public var unavailableReason: String?

    public init(
        kind: BiometryKind,
        isAvailable: Bool,
        hasFallback: Bool,
        unavailableReason: String? = nil
    ) {
        self.kind = kind
        self.isAvailable = isAvailable
        self.hasFallback = hasFallback
        self.unavailableReason = unavailableReason
    }

    /// Nothing MacUp can ask the user to confirm with.
    public static let unavailable = BiometricCapability(
        kind: .none,
        isAvailable: false,
        hasFallback: false,
        unavailableReason: "This Mac has no biometric sensor MacUp can use."
    )
}

/// The answer to one approval request.
public enum ApprovalOutcome: Sendable, Hashable {
    /// The configuration does not ask for approval, so none was requested.
    case notRequired
    case approved(BiometryKind)
    /// The user said no, or the check failed.
    case declined(String)
    /// MacUp could not ask. A change requiring approval does not happen.
    case unavailable(String)

    /// Whether the change may go ahead. Anything MacUp could not establish
    /// is a no (CLAUDE.md §2: ambiguity means skip and explain).
    public var allowsChange: Bool {
        switch self {
        case .notRequired, .approved: return true
        case .declined, .unavailable: return false
        }
    }

    public var explanation: String? {
        switch self {
        case .notRequired, .approved: return nil
        case .declined(let reason), .unavailable(let reason): return reason
        }
    }
}

/// Asks the device owner to confirm. Implemented by macOS, and by a fake in
/// tests so no test ever shows a prompt.
public protocol BiometricAuthorizing: Sendable {
    func capability(allowsFallback: Bool) -> BiometricCapability
    /// - Parameter reason: what the user is approving, shown in the system
    ///   prompt. Always MacUp's own words; never provider output or any other
    ///   untrusted text.
    func approve(reason: String, allowsFallback: Bool) async -> ApprovalOutcome
}

/// macOS's own authentication: Touch ID, Face ID, or Optic ID where the
/// hardware exists, with the owner's password (and Apple Watch) as the
/// fallback when allowed.
///
/// MacUp never sees the fingerprint, the face, or the password. It asks macOS
/// a yes/no question and is told yes or no (CLAUDE.md §2 rules 9 and 10).
public struct LocalAuthenticator: BiometricAuthorizing {
    public init() {}

    public func capability(allowsFallback: Bool) -> BiometricCapability {
        let context = LAContext()
        var error: NSError?
        let biometricsAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let kind = Self.kind(context.biometryType)
        var fallbackAvailable = false
        if allowsFallback {
            let fallbackContext = LAContext()
            fallbackAvailable = fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        }
        return BiometricCapability(
            kind: kind,
            isAvailable: biometricsAvailable,
            hasFallback: fallbackAvailable,
            unavailableReason: biometricsAvailable ? nil : Self.reason(error, kind: kind)
        )
    }

    public func approve(reason: String, allowsFallback: Bool) async -> ApprovalOutcome {
        let capability = capability(allowsFallback: allowsFallback)
        let policy: LAPolicy = capability.isAvailable ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        if !capability.isAvailable && !capability.hasFallback {
            return .unavailable(capability.unavailableReason ?? "MacUp could not ask you to confirm.")
        }

        let context = LAContext()
        let kind = capability.kind
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .approved(kind))
                } else {
                    continuation.resume(returning: Self.failure(error, kind: kind))
                }
            }
        }
    }

    static func kind(_ type: LABiometryType) -> BiometryKind {
        switch type {
        case .touchID: return .touchID
        case .faceID: return .faceID
        case .none: return .none
        @unknown default:
            // A sensor this build does not know about. Reported honestly as
            // unnamed rather than guessed at.
            if type.rawValue == 3 { return .opticID }
            return .none
        }
    }

    static func failure(_ error: (any Error)?, kind: BiometryKind) -> ApprovalOutcome {
        guard let error = error as? NSError else {
            return .declined("MacUp did not get your approval, so nothing was changed.")
        }
        switch LAError.Code(rawValue: error.code) {
        case .userCancel, .appCancel, .systemCancel:
            return .declined("You cancelled, so nothing was changed.")
        case .userFallback:
            return .declined("MacUp did not get your approval, so nothing was changed.")
        case .authenticationFailed:
            return .declined("\(kind.displayName) did not recognise you, so nothing was changed.")
        case .biometryNotEnrolled, .biometryNotAvailable, .biometryLockout, .passcodeNotSet:
            return .unavailable(Self.reason(error, kind: kind))
        default:
            return .declined(Self.reason(error, kind: kind))
        }
    }

    static func reason(_ error: NSError?, kind: BiometryKind) -> String {
        guard let error else {
            return kind == .none
                ? "This Mac has no biometric sensor MacUp can use."
                : "\(kind.displayName) is not available right now."
        }
        switch LAError.Code(rawValue: error.code) {
        case .biometryNotEnrolled:
            return "\(kind.displayName) is set up on this Mac but has nothing enrolled."
        case .biometryNotAvailable:
            return kind == .none
                ? "This Mac has no biometric sensor MacUp can use."
                : "\(kind.displayName) is turned off or unavailable."
        case .biometryLockout:
            return "\(kind.displayName) is locked out. Unlock this Mac with your password first."
        case .passcodeNotSet:
            return "This Mac has no login password set, so macOS cannot confirm it is you."
        case .systemCancel, .appCancel, .notInteractive, .invalidContext:
            // macOS will not show the prompt to a process that cannot put a
            // window in front of the user: a command run in the background,
            // over SSH, or from a script. The sensor itself is fine.
            return "macOS would not show the \(kind.displayName) prompt here. Run the command in a terminal you are looking at, or use the MacUp app."
        default:
            return TerminalText.sanitize(error.localizedDescription)
        }
    }
}

/// Decides whether a change MacUp is about to make needs the owner's approval,
/// and asks for it.
///
/// One gate for every modifying action. Scheduling uses it today; the
/// execution engine uses the same gate when it arrives, so approval cannot be
/// enforced in one place and forgotten in another.
public struct ApprovalGate: Sendable {
    public var settings: MacUpConfiguration.SecuritySettings
    public var authorizer: any BiometricAuthorizing

    public init(settings: MacUpConfiguration.SecuritySettings, authorizer: any BiometricAuthorizing = LocalAuthenticator()) {
        self.settings = settings
        self.authorizer = authorizer
    }

    public var capability: BiometricCapability {
        authorizer.capability(allowsFallback: settings.allowPasswordFallback)
    }

    /// - Parameter action: MacUp's own description of the change, completing
    ///   the sentence macOS shows: "MacUp is trying to <action>."
    public func approve(_ action: String) async -> ApprovalOutcome {
        guard settings.requireApproval else { return .notRequired }
        return await authorizer.approve(reason: action, allowsFallback: settings.allowPasswordFallback)
    }
}
