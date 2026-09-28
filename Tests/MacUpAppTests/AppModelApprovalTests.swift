import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Whether the app can ask for approval at all")
@MainActor
struct AppModelApprovalTests {
    typealias Security = MacUpConfiguration.SecuritySettings

    @Test("A Mac with no biometric sensor can still be asked, through the password")
    func noSensorButPasswordFallback() throws {
        let harness = try AppModelHarness(capability: .noSensorWithFallback)
        #expect(harness.model.canAskForApproval(with: Security(requireApproval: true, allowPasswordFallback: true)))
        #expect(harness.model.biometricCapability.kind == BiometryKind.none)
        #expect(!harness.model.biometricCapability.isAvailable)
    }

    @Test("A Mac with no sensor and no password fallback cannot be asked at all")
    func noSensorAndNoFallback() throws {
        let harness = try AppModelHarness(capability: .noSensorWithFallback)
        #expect(!harness.model.canAskForApproval(with: Security(requireApproval: true, allowPasswordFallback: false)))
    }

    @Test("A sensor that works can be asked whether or not the password is allowed")
    func sensorAvailable() throws {
        let harness = try AppModelHarness(capability: .touchID)
        #expect(harness.model.canAskForApproval(with: Security(requireApproval: true, allowPasswordFallback: true)))
        #expect(harness.model.canAskForApproval(with: Security(requireApproval: true, allowPasswordFallback: false)))
    }

    @Test("Requiring approval MacUp could never obtain is refused, with a reason")
    func refusesToLockItselfOut() async throws {
        let harness = try AppModelHarness(capability: .noSensorWithFallback)
        await harness.model.applySecurity(Security(requireApproval: true, allowPasswordFallback: false))

        let problem = try #require(harness.model.securityProblem)
        #expect(problem.contains("cannot ask you to confirm"))
        #expect(!harness.model.securitySettings.requireApproval)
    }

    @Test("Turning approval on is saved, and reported as required afterwards")
    func turningApprovalOnIsSaved() async throws {
        let harness = try AppModelHarness(capability: .touchID)
        await harness.model.applySecurity(Security(requireApproval: true))

        #expect(harness.model.securityProblem == nil)
        #expect(harness.model.securitySettings.requireApproval)
        #expect(FileManager.default.fileExists(atPath: harness.paths.configFile))
    }

    @Test("Turning approval off needs the approval that is in force now")
    func turningApprovalOffGoesThroughTheGate() async throws {
        let harness = try AppModelHarness(capability: .touchID)
        try harness.save(security: Security(requireApproval: true))
        harness.model.loadConfiguration()
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        await harness.model.applySecurity(Security(requireApproval: false))

        #expect(harness.model.securityProblem == "You cancelled, so nothing was changed.")
        #expect(harness.model.securitySettings.requireApproval)
        #expect(harness.authorizer.requestedReasons == ["change when MacUp asks for your approval"])
    }

    @Test("What this Mac will really ask for is described without overstating it")
    func capabilityDescribesWhatWillHappen() {
        let noSensor = BiometricCapability.noSensorWithFallback.summary
        #expect(noSensor.contains("no biometric sensor"))
        #expect(noSensor.contains("login password"))
        // The Apple Watch is named as a possibility, because MacUp is not told
        // whether one is paired.
        #expect(noSensor.contains("Apple Watch"))
        #expect(noSensor.contains("if you have one paired"))

        let locked = BiometricCapability(kind: .none, isAvailable: false, hasFallback: false).summary
        #expect(locked.contains("cannot ask you to confirm"))
        #expect(!locked.contains("Apple Watch"))

        #expect(BiometricCapability.touchID.summary.contains("Touch ID"))
        #expect(BiometricCapability(kind: .touchID, isAvailable: true, hasFallback: false).summary == "Touch ID is ready.")
    }
}
