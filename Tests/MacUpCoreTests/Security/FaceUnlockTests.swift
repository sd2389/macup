import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Camera face match")
struct FaceUnlockTests {
    private func signature(_ values: [Float]) -> FaceSignature { FaceSignature(values: values) }

    @Test("Distance is only defined between comparable signatures")
    func distance() {
        #expect(signature([0, 0, 0]).distance(to: signature([0, 0, 0])) == 0)
        #expect(signature([3, 4, 0]).distance(to: signature([0, 0, 0])) == 5)
        // Different Vision revisions produce different lengths. Not comparable,
        // and never silently treated as a match.
        #expect(signature([1, 2]).distance(to: signature([1, 2, 3])) == nil)
        #expect(signature([]).distance(to: signature([])) == nil)
    }

    @Test("A match is the closest enrolled sample, judged against the threshold")
    func matching() {
        let enrollment = FaceEnrollment(signatures: [signature([0, 0]), signature([1, 0]), signature([0, 1])])
        let comparator = FaceComparator(threshold: 0.5)

        let close = try! #require(comparator.match(signature([0.9, 0]), against: enrollment))
        #expect(close.distance < 0.2)
        #expect(close.isMatch)

        let far = try! #require(comparator.match(signature([5, 5]), against: enrollment))
        #expect(!far.isMatch)
    }

    @Test("Nothing comparable is not a match")
    func incomparableIsNotAMatch() {
        let enrollment = FaceEnrollment(signatures: [signature([0, 0, 0])])
        #expect(FaceComparator().match(signature([1, 1]), against: enrollment) == nil)
    }

    @Test("The spread of your own samples is reported, so the threshold can be judged")
    func sampleSpread() {
        #expect(FaceEnrollment(signatures: [signature([0, 0])]).sampleSpread == nil)
        let enrollment = FaceEnrollment(signatures: [signature([0, 0]), signature([3, 4]), signature([0, 1])])
        #expect(enrollment.sampleSpread == 5)
    }

    @Test("Enrollment is stored owner-only, and refuses too few samples")
    func store() throws {
        let directory = try TemporaryDirectory(prefix: "macup-face")
        let paths = MacUpPaths(
            configDirectory: directory.path,
            stateDirectory: directory.path + "/state",
            launchAgentsDirectory: directory.path + "/agents"
        )
        let store = FaceEnrollmentStore(paths: paths)
        #expect(try store.load() == nil)

        #expect(throws: MacUpError.self) {
            try store.save(FaceEnrollment(signatures: [signature([1, 2, 3])]))
        }

        let enrollment = FaceEnrollment(signatures: [signature([1, 2]), signature([1, 3]), signature([1, 4])])
        try store.save(enrollment)
        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        let loaded = try #require(try store.load())
        #expect(loaded.signatures == enrollment.signatures)

        #expect(try store.remove())
        #expect(try store.load() == nil)
        #expect(try store.remove() == false)
    }

    @Test("A stored file MacUp cannot read is an error, not an empty enrollment")
    func refusesUnreadableEnrollment() throws {
        let directory = try TemporaryDirectory(prefix: "macup-face")
        let paths = MacUpPaths(
            configDirectory: directory.path,
            stateDirectory: directory.path + "/state",
            launchAgentsDirectory: directory.path + "/agents"
        )
        let store = FaceEnrollmentStore(paths: paths)
        _ = try PrivateDirectory(paths.stateDirectory)
        try "not json".write(toFile: store.path, atomically: true, encoding: .utf8)
        #expect(throws: MacUpError.self) { try store.load() }

        try #"{"schemaVersion": 99, "createdAt": "2026-09-27T00:00:00Z", "signatures": []}"#
            .write(toFile: store.path, atomically: true, encoding: .utf8)
        #expect(throws: MacUpError.self) { try store.load() }
    }

    @Test("The camera match is named apart from the macOS sensors")
    func namedHonestly() {
        #expect(BiometryKind.cameraFace.displayName == "Face match (camera)")
        #expect(BiometryKind.cameraFace != .faceID)
    }

    @Test("A face that does not match still lets macOS decide")
    func fallsBackToMacOS() async {
        // The gate has no face service configured, which is what happens when
        // the setting is off: macOS is asked, and the camera is never opened.
        let authorizer = FakeBiometricAuthorizer()
        let settings = MacUpConfiguration.SecuritySettings(requireApproval: true, faceUnlock: true)
        let outcome = await ApprovalGate(settings: settings, authorizer: authorizer, faceUnlock: nil).approve("do something")
        #expect(outcome == .approved(.touchID))
        #expect(authorizer.requestedReasons == ["do something"])
    }

    @Test("Face match turned on without approval required is reported as doing nothing")
    func warnsWhenInert() {
        let configuration = MacUpConfiguration(
            security: MacUpConfiguration.SecuritySettings(requireApproval: false, faceUnlock: true)
        )
        let issues = ConfigurationValidator.semanticIssues(in: configuration)
        #expect(issues.contains { $0.path == "security.faceUnlock" && $0.severity == .warning })
    }

    @Test("A threshold outside the usable range is an error")
    func validatesThreshold() {
        for value in [0.0, -1.0, 5.1, 100.0] {
            let configuration = MacUpConfiguration(
                security: MacUpConfiguration.SecuritySettings(faceMatchThreshold: value)
            )
            let issues = ConfigurationValidator.semanticIssues(in: configuration)
            #expect(issues.contains { $0.path == "security.faceMatchThreshold" && $0.severity == .error })
        }
    }
}
