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

    @Test("Nothing a test does runs a provider command or launchctl")
    func noCommandReachesTheHost() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["git"]))
            .withScheduledExecutable()
        await harness.model.checkNow()
        await harness.model.refreshScheduleStatus()
        await harness.model.applySchedule(MacUpConfiguration.ScheduleSettings(enabled: true))
        await harness.model.applySecurity(MacUpConfiguration.SecuritySettings(requireApproval: true))
        await harness.enroll()

        // Every request the fake runner saw. It answers nothing it was not
        // told to, so an unexpected command fails rather than escaping; this
        // names what was attempted so a regression is legible.
        let attempted = Set(harness.launchedExecutables.map { ($0 as NSString).lastPathComponent })
        for forbidden in ["brew", "npm", "node", "mise", "softwareupdate"] {
            #expect(!attempted.contains(forbidden), "a test tried to run \(forbidden)")
        }
        // Reading the login shell's environment is the one thing the app asks
        // of a shell, and the fake runner refuses it too.
        #expect(attempted.subtracting(["zsh", "bash", "sh", "fish", "launchctl"]).isEmpty)
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
