import Foundation
import MacUpCore

/// A stand-in for macOS authentication. Tests never show a real prompt, and
/// never depend on whether the machine running them has a sensor.
public final class FakeBiometricAuthorizer: BiometricAuthorizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _capability: BiometricCapability
    private var _outcome: ApprovalOutcome
    private var _requests: [String] = []

    public init(
        capability: BiometricCapability = BiometricCapability(kind: .touchID, isAvailable: true, hasFallback: true),
        outcome: ApprovalOutcome = .approved(.touchID)
    ) {
        _capability = capability
        _outcome = outcome
    }

    /// Every reason string MacUp asked with, for asserting what the user was
    /// actually shown.
    public var requestedReasons: [String] { lock.withLock { _requests } }

    public func set(outcome: ApprovalOutcome) {
        lock.withLock { _outcome = outcome }
    }

    public func set(capability: BiometricCapability) {
        lock.withLock { _capability = capability }
    }

    public func capability(allowsFallback: Bool) -> BiometricCapability {
        lock.withLock {
            allowsFallback ? _capability : BiometricCapability(
                kind: _capability.kind,
                isAvailable: _capability.isAvailable,
                hasFallback: false,
                unavailableReason: _capability.unavailableReason
            )
        }
    }

    public func approve(reason: String, allowsFallback: Bool) async -> ApprovalOutcome {
        lock.withLock {
            _requests.append(reason)
            return _outcome
        }
    }
}
