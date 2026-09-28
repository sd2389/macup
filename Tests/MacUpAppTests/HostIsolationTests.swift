import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The golden rule in one place: a passing test suite must not alter the
/// machine it ran on (CLAUDE.md §20). The other suites rely on this being
/// true; this one checks it.
@Suite("The app's tests leave the host machine alone")
@MainActor
struct HostIsolationTests {
    @Test("The app's files are read and written under the throwaway home only")
    func pathsStayInsideTheTemporaryHome() async throws {
        let harness = try AppModelHarness()
        let home = harness.home.canonicalPath
        let paths = harness.paths

        for path in [paths.configFile, paths.stateDirectory, paths.launchAgentsDirectory, paths.historyFile] {
            #expect(path.hasPrefix(home), "\(path) is outside the test's home directory")
        }

        // The real locations belong to whoever is running the tests.
        let real = MacUpPaths.standard(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(paths.configDirectory != real.configDirectory)
        #expect(paths.stateDirectory != real.stateDirectory)

        let loaded = harness.model.loadConfiguration()
        #expect(loaded.path == paths.configFile)
        #expect(loaded.source == .defaults)
    }

    /// The only real paths the app is ever allowed to name: the login shell it
    /// reads the environment from, and launchctl. The fake runner refuses both.
    private static let permittedRealPaths: Set<String> = [
        "/bin/zsh", "/bin/bash", "/bin/sh", "/bin/dash", Scheduler.launchctlPath,
    ]

    @Test("Nothing a test does runs a provider command or launchctl")
    func noCommandReachesTheHost() async throws {
        let git = try PackageID(parsing: "brew:git")
        let harness = try AppModelHarness(
            planning: StubPlanningProvider(candidates: [PlannedUpdateFactory.candidate("brew:git")]),
            doctorChecks: [StubDiagnosticCheck()]
        ).withScheduledExecutable()
        try harness.rule(.auto, for: git)
        harness.allowUpdate(of: "git")

        // Every screen that can reach the outside world, including the one
        // that applies a change.
        await harness.model.checkNow()
        await harness.model.refreshScheduleStatus()
        await harness.model.applySchedule(MacUpConfiguration.ScheduleSettings(enabled: true))
        await harness.model.applySecurity(MacUpConfiguration.SecuritySettings(requireApproval: true))
        await harness.model.setPolicy(.ask, for: git)
        await harness.model.runDoctor()
        await harness.model.showCommand(for: git)
        await harness.reviewEverything()
        await harness.applyAndWait()
        harness.model.loadHistory()
        await harness.enroll()

        // Every executable path any command was given. The fake runner
        // launches nothing, so this is what the app *named*, and nothing on
        // it may be a package manager that exists on this Mac.
        for path in harness.launchedExecutables where !Self.permittedRealPaths.contains(path) {
            #expect(path.hasPrefix("/stub/"), "a test named \(path), which is not one of this suite's stubs")
            #expect(
                !FileManager.default.fileExists(atPath: path),
                "\(path) is a real executable on this Mac"
            )
        }
        let attempted = Set(harness.launchedExecutables.map { ($0 as NSString).lastPathComponent })
        #expect(attempted.subtracting(["zsh", "bash", "sh", "fish", "launchctl", "brew"]).isEmpty)
    }

    @Test("Applying an update writes MacUp's history inside the throwaway home only")
    func historyIsWrittenInsideTheTemporaryHome() async throws {
        let git = try PackageID(parsing: "brew:git")
        let harness = try AppModelHarness(planning: StubPlanningProvider(
            candidates: [PlannedUpdateFactory.candidate("brew:git")]
        ))
        try harness.rule(.auto, for: git)
        harness.allowUpdate(of: "git")
        await harness.reviewEverything()
        await harness.applyAndWait()

        // The run really did record something, or this would prove nothing.
        #expect(try harness.recordedHistory().count == 1)
        #expect(FileManager.default.fileExists(atPath: harness.paths.historyFile))
        #expect(harness.paths.historyFile.hasPrefix(harness.home.canonicalPath))

        let real = MacUpPaths.standard(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(harness.paths.historyFile != real.historyFile)
        #expect(harness.paths.configFile != real.configFile)
    }

    @Test("No test opens a camera or shows an authentication prompt")
    func noCameraAndNoPrompt() async throws {
        let harness = try AppModelHarness()
        await harness.enroll()
        await harness.model.applySecurity(MacUpConfiguration.SecuritySettings(requireApproval: true))

        // Both are fakes, which is the guarantee: the real camera and the real
        // LocalAuthentication prompt are only ever built by
        // AppEnvironment.live().
        #expect(harness.model.environment.faceCamera is FakeFaceCamera)
        #expect(harness.model.environment.authorizer is FakeBiometricAuthorizer)
        #expect(!harness.camera.isCameraOpen)
    }

    @Test("No test installs a launchd agent")
    func noAgentIsInstalled() async throws {
        let harness = try AppModelHarness().withScheduledExecutable()
        await harness.model.applySchedule(MacUpConfiguration.ScheduleSettings(enabled: true))

        let agent = harness.paths.launchAgentsDirectory + "/" + LaunchAgent.fileName
        #expect(!FileManager.default.fileExists(atPath: agent))
        let realAgent = MacUpPaths.standard(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            .launchAgentsDirectory + "/" + LaunchAgent.fileName
        #expect(agent != realAgent)
    }
}
