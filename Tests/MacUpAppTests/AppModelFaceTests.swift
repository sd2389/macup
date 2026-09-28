import AVFoundation
import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Enrolling a face from the app")
@MainActor
struct AppModelFaceTests {
    @Test("Enrolling saves the samples and turns the face match on")
    func enrolmentSavesAndEnables() async throws {
        let harness = try AppModelHarness()
        await harness.enroll()

        let enrollment = try #require(harness.model.faceEnrollment)
        #expect(enrollment.signatures.count == 3)
        #expect(harness.model.faceProblem == nil)
        #expect(harness.model.securitySettings.faceUnlock)
        #expect(!harness.model.isEnrollingFace)
        // The sheet's camera view and its stage line are both put away.
        #expect(harness.model.faceCaptureSession == nil)
        #expect(harness.model.faceStage == nil)
    }

    @Test("Cancelling an enrolment stops it and clears what it was showing")
    func cancellationClearsItsOwnState() async throws {
        let camera = FakeFaceCamera()
        let rendezvous = Rendezvous()
        camera.rendezvous = rendezvous
        let harness = try AppModelHarness(camera: camera)

        // Captured before Cancel drops the handle, so the test can wait for
        // the enrolment to finish unwinding.
        harness.model.startFaceEnrollment()
        let enrolment = harness.model.faceTask
        await rendezvous.waitUntilReached()
        #expect(harness.model.isEnrollingFace)
        #expect(harness.model.faceStage == "Look at the camera")

        harness.model.cancelFaceEnrollment()
        rendezvous.open()
        await enrolment?.value

        #expect(!harness.model.isEnrollingFace)
        #expect(harness.model.faceStage == nil)
        #expect(harness.model.faceCaptureSession == nil)
        // Cancelling is not a failure, so it leaves no error on screen, and
        // nothing was enrolled.
        #expect(harness.model.faceProblem == nil)
        #expect(harness.model.faceEnrollment == nil)
        #expect(!harness.model.securitySettings.faceUnlock)
    }

    @Test("A camera MacUp cannot use is explained before any sheet opens")
    func refusesEarlyWhenTheCameraCannotBeUsed() async throws {
        let camera = FakeFaceCamera(readiness: .adHocSigned)
        let harness = try AppModelHarness(camera: camera)

        await harness.enroll()

        #expect(!harness.model.isEnrollingFace)
        #expect(camera.enrolments == 0)
        let problem = try #require(harness.model.faceProblem)
        #expect(problem.contains("signed ad-hoc"))
        #expect(problem.contains("A signed build of MacUp is what changes that"))
        #expect(harness.model.faceEnrollment == nil)
    }

    @Test("A Mac with no camera is told it has no camera, not that signing is wrong")
    func noCameraIsItsOwnReason() async throws {
        let harness = try AppModelHarness(camera: FakeFaceCamera(readiness: .noCamera))
        await harness.enroll()

        #expect(harness.model.faceProblem == "This Mac has no camera MacUp can use.")
        #expect(!harness.model.cameraReadiness.hasCamera)
    }

    @Test("An enrolment that fails says what went wrong and enables nothing")
    func failureIsReported() async throws {
        let camera = FakeFaceCamera()
        camera.failure = MacUpError(
            .verificationFailed,
            "MacUp saw a face in only 1 of 5 pictures.",
            recoverySuggestion: "Face the camera in even light and try again."
        )
        let harness = try AppModelHarness(camera: camera)

        await harness.enroll()

        let problem = try #require(harness.model.faceProblem)
        #expect(problem.contains("saw a face in only 1 of 5 pictures"))
        #expect(problem.contains("even light"))
        #expect(harness.model.faceEnrollment == nil)
        #expect(!harness.model.securitySettings.faceUnlock)
        #expect(harness.model.faceCaptureSession == nil)
    }

    @Test("Forgetting a face deletes it and turns the face match off")
    func forgettingRemovesEverything() async throws {
        let harness = try AppModelHarness()
        await harness.enroll()
        #expect(harness.model.securitySettings.faceUnlock)

        harness.model.forgetFace()

        #expect(harness.model.faceEnrollment == nil)
        #expect(!harness.model.securitySettings.faceUnlock)
        #expect(harness.model.faceProblem == nil)
        #expect(!FileManager.default.fileExists(
            atPath: harness.paths.stateDirectory + "/" + FaceEnrollmentStore.fileName
        ))

        // And reading it back agrees, rather than remembering a deleted face.
        harness.model.loadFaceEnrollment()
        #expect(harness.model.faceEnrollment == nil)
    }

    @Test("A second enrolment while one is running is ignored")
    func overlappingEnrolmentsAreIgnored() async throws {
        let camera = FakeFaceCamera()
        let rendezvous = Rendezvous()
        camera.rendezvous = rendezvous
        let harness = try AppModelHarness(camera: camera)

        harness.model.startFaceEnrollment()
        let enrolment = harness.model.faceTask
        await rendezvous.waitUntilReached()
        harness.model.startFaceEnrollment()

        rendezvous.open()
        await enrolment?.value
        #expect(camera.enrolments == 1)
    }
}

@Suite("What MacUp says about the camera it cannot use")
struct CameraReadinessTests {
    @Test("An ad-hoc signed build says macOS will never ask, and why")
    func adHocSignedBuildIsExplained() throws {
        let readiness = CameraReadiness.adHocSigned
        #expect(!readiness.canUse)
        let problem = try #require(readiness.problem)
        #expect(problem.contains("signed ad-hoc"))
        #expect(problem.contains("no developer identity"))
        #expect(problem.contains("It never asks"))
        #expect(problem.contains("A signed build of MacUp is what changes that"))
        // It must not send anyone to a setting that cannot help, and must not
        // suggest they did anything wrong.
        #expect(problem.contains("nothing to turn on in System Settings"))
        #expect(!problem.lowercased().contains("you need to"))
    }

    @Test("A signature macOS can attribute is not the camera's problem")
    func attributableSignatureIsUsable() {
        #expect(CameraReadiness.usable.canUse)
        #expect(CameraReadiness.usable.problem == nil)
        #expect(BundleSignature(teamIdentifier: "ABCDE12345", isAdHoc: false).isAttributable)
        #expect(!BundleSignature(teamIdentifier: nil, isAdHoc: true).isAttributable)
        // A team identifier on an ad-hoc signature is still ad-hoc, and a
        // signature with neither is neither.
        #expect(!BundleSignature(teamIdentifier: "ABCDE12345", isAdHoc: true).isAttributable)
        #expect(!BundleSignature(teamIdentifier: nil, isAdHoc: false).isAttributable)
    }

    @Test("A signed build macOS has refused is sent to the setting that can change it")
    func deniedAccessIsActionable() throws {
        var readiness = CameraReadiness.usable
        readiness.access = .denied
        let problem = try #require(readiness.problem)
        #expect(problem.contains("System Settings"))
        #expect(!problem.contains("ad-hoc"))
    }

    @Test("Whatever macOS says about access, an ad-hoc build is still refused")
    func theSignatureDecidesOnItsOwn() throws {
        // Allowing it in System Settings would not help, so MacUp does not
        // suggest it; and macOS reporting access as granted is no evidence the
        // camera will work, so MacUp does not offer the button either.
        for access in [AVAuthorizationStatus.notDetermined, .denied, .restricted, .authorized] {
            var readiness = CameraReadiness.adHocSigned
            readiness.access = access
            #expect(!readiness.canUse)
            #expect(try #require(readiness.problem).contains("signed ad-hoc"))
        }
    }

    @Test("The diagnostic run and the screen give the same reason")
    func diagnosticAgreesWithTheScreen() throws {
        let readiness = CameraReadiness.adHocSigned
        let lines = readiness.diagnosticLines
        #expect(lines.contains("usable: no"))
        #expect(lines.contains { $0.contains("signature: ad-hoc") })
        #expect(lines.contains { $0.contains("team none") })
        let reason = try #require(lines.first { $0.hasPrefix("reason: ") })
        #expect(reason.contains(try #require(readiness.problem)))

        #expect(CameraReadiness.usable.diagnosticLines.contains("usable: yes"))
        #expect(!CameraReadiness.usable.diagnosticLines.contains { $0.hasPrefix("reason: ") })
    }
}
