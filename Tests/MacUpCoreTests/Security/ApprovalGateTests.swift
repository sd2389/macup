import Foundation
import LocalAuthentication
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Approval before MacUp changes anything")
struct ApprovalGateTests {
    typealias Settings = MacUpConfiguration.SecuritySettings

    @Test("With approval off, MacUp does not ask")
    func doesNotAskWhenNotRequired() async {
        let authorizer = FakeBiometricAuthorizer()
        let gate = ApprovalGate(settings: Settings(requireApproval: false), authorizer: authorizer)
        let outcome = await gate.approve("change MacUp's scheduled check")
        #expect(outcome == .notRequired)
        #expect(outcome.allowsChange)
        #expect(authorizer.requestedReasons.isEmpty)
    }

    @Test("With approval on, MacUp asks with its own words and honours the answer")
    func asksWhenRequired() async {
        let authorizer = FakeBiometricAuthorizer()
        let gate = ApprovalGate(settings: Settings(requireApproval: true), authorizer: authorizer)

        let approved = await gate.approve("change MacUp's scheduled check")
        #expect(approved == .approved(.touchID))
        #expect(approved.allowsChange)
        #expect(authorizer.requestedReasons == ["change MacUp's scheduled check"])

        authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))
        let declined = await gate.approve("change MacUp's scheduled check")
        #expect(!declined.allowsChange)
        #expect(declined.explanation == "You cancelled, so nothing was changed.")
    }

    @Test("What MacUp could not establish is a no")
    func failsClosed() async {
        let authorizer = FakeBiometricAuthorizer()
        authorizer.set(outcome: .unavailable("Touch ID is locked out."))
        let gate = ApprovalGate(settings: Settings(requireApproval: true), authorizer: authorizer)
        let outcome = await gate.approve("change MacUp's scheduled check")
        #expect(!outcome.allowsChange)
        #expect(outcome.explanation == "Touch ID is locked out.")
    }

    @Test("Refusing the fallback removes it from what MacUp reports")
    func fallbackIsRespected() {
        let authorizer = FakeBiometricAuthorizer()
        #expect(ApprovalGate(settings: Settings(allowPasswordFallback: true), authorizer: authorizer).capability.hasFallback)
        #expect(!ApprovalGate(settings: Settings(allowPasswordFallback: false), authorizer: authorizer).capability.hasFallback)
    }

    @Test("The sensor is whatever macOS says it is, never assumed")
    func reportsTheDevicesOwnSensor() {
        #expect(LocalAuthenticator.kind(.touchID) == .touchID)
        #expect(LocalAuthenticator.kind(.faceID) == .faceID)
        #expect(LocalAuthenticator.kind(.none) == .none)
        #expect(BiometryKind.touchID.displayName == "Touch ID")
        #expect(BiometryKind.faceID.displayName == "Face ID")
        #expect(BiometryKind.opticID.displayName == "Optic ID")
    }

    @Test("A cancelled check is a decline; a missing sensor is unavailable")
    func mapsSystemErrors() {
        let cancelled = NSError(domain: LAError.errorDomain, code: LAError.userCancel.rawValue)
        #expect(LocalAuthenticator.failure(cancelled, kind: .touchID).allowsChange == false)
        #expect(LocalAuthenticator.failure(cancelled, kind: .touchID) == .declined("You cancelled, so nothing was changed."))

        let notEnrolled = NSError(domain: LAError.errorDomain, code: LAError.biometryNotEnrolled.rawValue)
        if case .unavailable(let reason) = LocalAuthenticator.failure(notEnrolled, kind: .faceID) {
            #expect(reason.contains("Face ID"))
            #expect(reason.contains("nothing enrolled"))
        } else {
            Issue.record("an unenrolled sensor should be unavailable, not a decline")
        }

        let lockout = NSError(domain: LAError.errorDomain, code: LAError.biometryLockout.rawValue)
        #expect(!LocalAuthenticator.failure(lockout, kind: .touchID).allowsChange)

        // A process that cannot put a window in front of the user is told so,
        // rather than being led to think the sensor is broken.
        let background = NSError(domain: LAError.errorDomain, code: LAError.notInteractive.rawValue)
        #expect(LocalAuthenticator.reason(background, kind: .touchID).contains("would not show the Touch ID prompt here"))
    }

    @Test("The security section round-trips through the configuration")
    func encodesInConfiguration() throws {
        let json = #"{"schemaVersion": 1, "security": {"requireApproval": true, "allowPasswordFallback": false}}"#
        let configuration = try JSONDecoder().decode(MacUpConfiguration.self, from: Data(json.utf8))
        #expect(configuration.security.requireApproval)
        #expect(!configuration.security.allowPasswordFallback)

        // Omitted: approval off, fallback allowed, so a Mac with no sensor is
        // never locked out by a default.
        let empty = try JSONDecoder().decode(MacUpConfiguration.self, from: Data(#"{"schemaVersion": 1}"#.utf8))
        #expect(!empty.security.requireApproval)
        #expect(empty.security.allowPasswordFallback)
    }
}
