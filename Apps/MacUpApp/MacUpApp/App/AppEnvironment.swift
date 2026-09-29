import AVFoundation
import Foundation
import MacUpCore

/// The camera side of face enrolment.
///
/// Behind a protocol so the enrolment flow — its stages, its cancellation, and
/// what it leaves behind when it fails — can be tested without a lens. No test
/// may open a camera or provoke a macOS permission prompt (CLAUDE.md §20).
@MainActor
protocol FaceEnrolling {
    /// What this build can expect from the camera. Reading it opens nothing.
    var readiness: CameraReadiness { get }

    /// Opens the camera, takes the samples, and saves them.
    ///
    /// `stage` reports what is happening in words and `preview` hands over the
    /// live session, so the sheet can show what the camera sees instead of a
    /// spinner. The camera is closed before this returns, however it returns.
    func enroll(
        into store: FaceEnrollmentStore,
        threshold: Double,
        stage: (String) -> Void,
        preview: (AVCaptureSession?) -> Void
    ) async throws -> FaceEnrollment
}

/// Face enrolment on the real camera, through ``FaceUnlockService``.
struct SystemFaceCamera: FaceEnrolling {
    var readiness: CameraReadiness { .current() }

    func enroll(
        into store: FaceEnrollmentStore,
        threshold: Double,
        stage: (String) -> Void,
        preview: (AVCaptureSession?) -> Void
    ) async throws -> FaceEnrollment {
        let service = FaceUnlockService(store: store, comparator: FaceComparator(threshold: Float(threshold)))
        defer {
            service.camera.end()
            preview(nil)
        }
        stage("Opening the camera")
        try await service.camera.begin()
        preview(service.camera.captureSession)
        // A moment to be in frame before the samples are taken, so the first
        // picture is not of someone still reaching for the mouse. Cancellation
        // during the pause stops the enrolment there, which is what the sheet's
        // Cancel button promises.
        stage("Look at the camera")
        try await Task.sleep(for: .milliseconds(1400))
        stage("Taking pictures")
        return try await service.enroll(cameraIsOpen: true)
    }
}

/// The environment the user's terminal would have.
///
/// Behind a protocol because reading it runs the user's own login shell, which
/// no test may do. A test says what that shell would have said, or that it
/// could not be read.
protocol LoginShellReading: Sendable {
    /// The login shell MacUp would run.
    func shell() -> String
    /// That shell's environment.
    func environment(from shell: String) async throws -> [String: String]
}

/// The user's real login shell, through ``LoginShellEnvironment``.
struct SystemLoginShell: LoginShellReading {
    var runner: any CommandRunning
    var fileSystem: any FileSystem
    var homeDirectory: String
    var baseEnvironment: [String: String]

    func shell() -> String {
        LoginShellEnvironment.userLoginShell(fileSystem: fileSystem)
    }

    func environment(from shell: String) async throws -> [String: String] {
        try await LoginShellEnvironment.capture(
            shell: shell,
            runner: runner,
            homeDirectory: homeDirectory,
            baseEnvironment: baseEnvironment
        )
    }
}

/// Everything ``AppModel`` needs from outside itself.
///
/// The model decides real things — whether a check may start, whether a change
/// is approved, which busy flag a screen sees, what the menu bar is allowed to
/// claim — and none of it could be tested while the model reached for the real
/// command runner, the real file system, the real authentication and the real
/// home directory. So it asks for them instead. ``live()`` is the only thing a
/// shipping build uses, and it supplies exactly what the model used to build
/// for itself.
@MainActor
struct AppEnvironment {
    var runner: any CommandRunning
    var fileSystem: any FileSystem
    var authorizer: any BiometricAuthorizing
    /// The read-only check, injected whole, so a test runs the real engine
    /// over stub providers rather than over the machine it is running on.
    var checkEngine: CheckEngine
    /// Turns the candidates a check found into reviewable plans. Injected for
    /// the same reason as the check engine, and it launches nothing either.
    var planner: UpdatePlanner
    /// Builds the engine that runs a plan. A closure because the engine needs
    /// the paths MacUp resolved at the time, and because a test supplies
    /// providers whose commands the fake runner refuses.
    var makeExecutionEngine: (MacUpPaths) -> ExecutionEngine
    /// MacUp's deterministic diagnostics.
    var doctorEngine: DoctorEngine
    var faceCamera: any FaceEnrolling
    var loginShell: any LoginShellReading
    var homeDirectory: String
    /// MacUp's own environment, which is where the `MACUP_*_DIR` overrides are
    /// read from. Deliberately not the login shell's: an app started from
    /// Finder sees no shell variables, so where MacUp keeps its files must not
    /// depend on how it was started.
    var processEnvironment: [String: String]
    var system: SystemInfo
    /// Where the `macup` inside the app bundle would be. Checked when it is
    /// needed rather than remembered, so a bundle rebuilt underneath the
    /// running app is not reported wrongly.
    var bundledExecutablePath: String?
    /// TypeSafe and the Keychain, for opt-in AI help. Unavailable unless set,
    /// so an environment built without it sends nothing; tests pass fakes.
    var ai: AIService = .unavailable

    static func live() -> AppEnvironment {
        let runner = ProcessCommandRunner()
        let fileSystem = LocalFileSystem()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let processEnvironment = ProcessInfo.processInfo.environment
        return AppEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            authorizer: LocalAuthenticator(),
            checkEngine: .standard(),
            planner: .standard(),
            makeExecutionEngine: { ExecutionEngine.standard(paths: $0) },
            doctorEngine: .standard(),
            faceCamera: SystemFaceCamera(),
            loginShell: SystemLoginShell(
                runner: runner,
                fileSystem: fileSystem,
                homeDirectory: home,
                baseEnvironment: processEnvironment
            ),
            homeDirectory: home,
            processEnvironment: processEnvironment,
            system: .current(),
            bundledExecutablePath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/Helpers/macup").path,
            ai: AIState.liveService()
        )
    }
}
