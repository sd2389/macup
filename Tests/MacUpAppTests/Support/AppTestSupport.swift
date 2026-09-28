import AVFoundation
import Foundation
import MacUpCore
import MacUpTestSupport

@testable import MacUpAppCore

/// A one-shot rendezvous between a test and the code it is testing.
///
/// Used where a test has to observe the model *while* it is busy — an
/// overlapping check, a cancellation part-way through enrolment. Sleeping for a
/// guessed interval would make those tests flaky; waiting for the code to
/// arrive makes them deterministic.
final class Rendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var arrived = false
    private var waitingForOpen: [CheckedContinuation<Void, Never>] = []
    private var waitingForArrival: [CheckedContinuation<Void, Never>] = []

    /// Called by the code under test: announces it got here, then waits.
    func arriveAndWait() async {
        let announce: [CheckedContinuation<Void, Never>] = lock.withLock {
            arrived = true
            defer { waitingForArrival = [] }
            return waitingForArrival
        }
        for continuation in announce { continuation.resume() }

        await withCheckedContinuation { continuation in
            let alreadyOpen: Bool = lock.withLock {
                if isOpen { return true }
                waitingForOpen.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    /// Called by the test: returns once the code under test has arrived.
    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let already: Bool = lock.withLock {
                if arrived { return true }
                waitingForArrival.append(continuation)
                return false
            }
            if already { continuation.resume() }
        }
    }

    /// Called by the test: lets the code under test carry on.
    func open() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waitingForOpen = [] }
            return waitingForOpen
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// A provider that reports whatever a test tells it to, without running
/// anything. It stands in for Homebrew so its candidates have real package
/// IDs, and it runs inside the real ``CheckEngine``, so what the app sees is
/// what the engine really produces.
final class StubCheckProvider: UpdateProvider, @unchecked Sendable {
    let id = ProviderID.homebrew
    let capabilities: Set<ProviderCapability> = [.detect, .outdated]

    private let lock = NSLock()
    private var _updates: [UpdateCandidate] = []
    private var _outdatedError: MacUpError?
    private var _unreadableUpdates = 0
    private var _detections = 0
    /// Held here so a test can watch a check in progress.
    var detectRendezvous: Rendezvous?

    init(updateNames: [String] = [], outdatedError: MacUpError? = nil, unreadableUpdates: Int = 0) {
        _updates = updateNames.map { name in
            UpdateCandidate(
                id: try! PackageID(.brew, name),
                kind: .formula,
                displayName: name,
                installedVersion: "1.0.0",
                availableVersion: "1.0.1"
            )
        }
        _outdatedError = outdatedError
        _unreadableUpdates = unreadableUpdates
    }

    /// How many times a check asked this provider to detect itself.
    var detections: Int { lock.withLock { _detections } }

    func detect(context: ProviderContext) async -> ProviderStatus {
        lock.withLock { _detections += 1 }
        if let rendezvous = detectRendezvous { await rendezvous.arriveAndWait() }
        return ProviderStatus(
            provider: id,
            availability: .available,
            installation: ProviderInstallation(
                executable: ResolvedExecutable(
                    path: "/stub/bin/brew",
                    canonicalPath: "/stub/bin/brew",
                    source: .standardLocation
                ),
                version: "4.0.0"
            )
        )
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        ProviderListing()
    }

    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        let (updates, error, unreadable) = lock.withLock { (_updates, _outdatedError, _unreadableUpdates) }
        if let error { throw error }
        // A real provider records a finding for every entry it skipped, so
        // this one does too: the two travel together.
        let findings = (0..<unreadable).map { index in
            DiagnosticFinding(
                id: "homebrew.unreadableEntry",
                severity: .warning,
                provider: id,
                title: "Skipped an entry MacUp could not read",
                detail: "entry \(index + 1)"
            )
        }
        return ProviderListing(updates, findings: findings, skipped: unreadable)
    }
}

/// Face enrolment with no camera behind it.
///
/// Every test uses this. Nothing here touches AVFoundation, so no test can
/// open a lens or provoke a macOS permission prompt.
@MainActor
final class FakeFaceCamera: FaceEnrolling {
    var readiness: CameraReadiness
    /// Signatures the next enrolment will produce.
    var signatures = [
        FaceSignature(values: [0, 0, 0]),
        FaceSignature(values: [0, 0, 0.01]),
        FaceSignature(values: [0, 0, 0.02]),
    ]
    var failure: MacUpError?
    /// Held part-way through so a test can cancel an enrolment in progress.
    var rendezvous: Rendezvous?
    private(set) var stages: [String] = []
    private(set) var enrolments = 0
    private(set) var isCameraOpen = false

    init(readiness: CameraReadiness = .usable) {
        self.readiness = readiness
    }

    func enroll(
        into store: FaceEnrollmentStore,
        threshold: Double,
        stage: (String) -> Void,
        preview: (AVCaptureSession?) -> Void
    ) async throws -> FaceEnrollment {
        enrolments += 1
        isCameraOpen = true
        defer {
            isCameraOpen = false
            preview(nil)
        }
        report("Opening the camera", to: stage)
        report("Look at the camera", to: stage)
        if let rendezvous {
            await rendezvous.arriveAndWait()
            // A real enrolment is a sequence of waits on hardware, so it
            // notices cancellation at one of them rather than instantly.
            try Task.checkCancellation()
        }
        if let failure { throw failure }
        report("Taking pictures", to: stage)
        let enrollment = FaceEnrollment(signatures: signatures)
        try store.save(enrollment)
        return enrollment
    }

    private func report(_ stage: String, to sink: (String) -> Void) {
        stages.append(stage)
        sink(stage)
    }
}

extension CameraReadiness {
    /// A Mac whose camera MacUp can use: a real signature and access granted.
    static let usable = CameraReadiness(
        hasCamera: true,
        cameraName: "FaceTime HD Camera",
        signature: BundleSignature(teamIdentifier: "ABCDE12345", isAdHoc: false),
        access: .authorized
    )

    /// What every locally built MacUp actually is today: ad-hoc signed, with
    /// macOS never having been asked.
    static let adHocSigned = CameraReadiness(
        hasCamera: true,
        cameraName: "FaceTime HD Camera",
        signature: BundleSignature(teamIdentifier: nil, isAdHoc: true),
        access: .notDetermined
    )

    static let noCamera = CameraReadiness(
        hasCamera: false,
        cameraName: nil,
        signature: BundleSignature(teamIdentifier: "ABCDE12345", isAdHoc: false),
        access: .notDetermined
    )
}

/// A login shell that answers from memory. No shell is ever run.
struct FakeLoginShell: LoginShellReading {
    var name = "/bin/zsh"
    var result: [String: String] = ["PATH": "/usr/bin:/bin"]
    var failure: MacUpError?

    func shell() -> String { name }

    func environment(from shell: String) async throws -> [String: String] {
        if let failure { throw failure }
        return result
    }
}

extension BiometricCapability {
    /// A Mac with no Touch ID, where macOS will ask for the login password
    /// (and take an unlocked Apple Watch) instead.
    static let noSensorWithFallback = BiometricCapability(
        kind: .none,
        isAvailable: false,
        hasFallback: true,
        unavailableReason: "This Mac has no biometric sensor MacUp can use."
    )

    static let touchID = BiometricCapability(kind: .touchID, isAvailable: true, hasFallback: true)
}

/// An ``AppModel`` wired to fakes and a throwaway home directory.
///
/// The home directory is a fresh temporary one, so `~/.config/macup` and
/// `~/.local/state/macup` on the machine running the tests are never read and
/// never written (CLAUDE.md §20). The command runner answers nothing it was not
/// told to answer, so no provider binary and no `launchctl` can run.
@MainActor
final class AppModelHarness {
    let home: TemporaryDirectory
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    let authorizer: FakeBiometricAuthorizer
    let camera: FakeFaceCamera
    let provider: StubCheckProvider
    let model: AppModel

    init(
        provider: StubCheckProvider = StubCheckProvider(),
        capability: BiometricCapability = .touchID,
        camera: FakeFaceCamera = FakeFaceCamera(),
        loginShell: FakeLoginShell = FakeLoginShell()
    ) throws {
        home = try TemporaryDirectory(prefix: "macup-app-tests")
        authorizer = FakeBiometricAuthorizer(capability: capability)
        self.camera = camera
        self.provider = provider
        // The directories MacUp's own live under exist on a Mac that has been
        // used; MacUp creates only its own leaf directory, so a test home has
        // to look the same or it would be testing a different machine.
        for parent in ["/.config", "/.local", "/.local/state", "/Library", "/Library/LaunchAgents"] {
            try FileManager.default.createDirectory(
                atPath: home.canonicalPath + parent,
                withIntermediateDirectories: true
            )
        }
        let bundledExecutablePath = home.canonicalPath + "/MacUp.app/Contents/Helpers/macup"
        model = AppModel(environment: AppEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            authorizer: authorizer,
            checkEngine: CheckEngine(providers: [provider]),
            faceCamera: camera,
            loginShell: loginShell,
            homeDirectory: home.canonicalPath,
            // No `MACUP_*_DIR` overrides and no `PATH`: everything resolves
            // under the throwaway home, and nothing is found on the real one.
            processEnvironment: [:],
            system: SystemInfo(productVersion: "15.0", buildVersion: "24A335", architecture: "arm64"),
            bundledExecutablePath: bundledExecutablePath
        ))
    }

    var paths: MacUpPaths { MacUpPaths.standard(homeDirectory: home.canonicalPath) }

    /// The `macup` the app would schedule: its own bundled copy.
    var bundledExecutable: String { home.canonicalPath + "/MacUp.app/Contents/Helpers/macup" }

    /// Puts that `macup` on the pretend file system, so a schedule has
    /// something to name. It is never run: the fake runner answers no command.
    @discardableResult
    func withScheduledExecutable() -> AppModelHarness {
        fileSystem.addExecutable(bundledExecutable)
        return self
    }

    /// Puts `launchctl` where the scheduler looks for it, so a test can get
    /// past the check that it exists.
    @discardableResult
    func withLaunchctl() -> AppModelHarness {
        fileSystem.addExecutable(Scheduler.launchctlPath)
        return self
    }

    /// Runs one enrolment and waits for it to finish, however it finishes.
    func enroll() async {
        model.startFaceEnrollment()
        await model.faceTask?.value
    }

    /// Writes a configuration into the throwaway home, for tests that need
    /// MacUp to start from something other than its defaults.
    func save(
        security: MacUpConfiguration.SecuritySettings = .init(),
        schedule: MacUpConfiguration.ScheduleSettings = .init()
    ) throws {
        var configuration = MacUpConfiguration.defaults
        configuration.security = security
        configuration.schedule = schedule
        try ConfigurationStore(paths: paths).save(configuration)
    }

    /// Every executable path any command was asked to launch, for asserting
    /// that a test ran nothing on the host.
    var launchedExecutables: [String] {
        runner.recordedRequests.map(\.executable.path)
    }
}
