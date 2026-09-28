import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("Changing the scheduled check from the app")
@MainActor
struct AppModelScheduleTests {
    typealias Schedule = MacUpConfiguration.ScheduleSettings

    @Test("With no macup to schedule, MacUp says so and changes nothing")
    func refusesWithoutAnExecutable() async throws {
        let harness = try AppModelHarness()
        await harness.model.applySchedule(Schedule(enabled: true))

        #expect(harness.model.scheduleProblem?.contains("could not find the macup command") == true)
        #expect(!harness.model.scheduleSettings.enabled)
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("A schedule that could not be installed leaves a readable problem and no claim of success")
    func failureIsReportedAndNothingIsSaved() async throws {
        // launchctl is missing from the pretend Mac, so the scheduler refuses
        // before it writes anything.
        let harness = try AppModelHarness().withScheduledExecutable()
        await harness.model.applySchedule(Schedule(enabled: true, frequency: .weekly, time: "07:30"))

        let problem = try #require(harness.model.scheduleProblem)
        #expect(problem.contains("launchctl"))
        #expect(!problem.isEmpty)
        // The configuration still says scheduling is off, and no agent exists.
        #expect(!harness.model.scheduleSettings.enabled)
        #expect(!FileManager.default.fileExists(atPath: harness.paths.launchAgentsDirectory + "/" + LaunchAgent.fileName))
        #expect(!harness.model.isChangingSchedule)
    }

    @Test("A schedule launchd refuses is reported with what launchd said")
    func launchdRefusalIsReported() async throws {
        let harness = try AppModelHarness().withScheduledExecutable().withLaunchctl()
        let scheduler = Scheduler(paths: harness.paths, executable: harness.bundledExecutable)
        harness.runner.register(
            path: Scheduler.launchctlPath,
            ["bootstrap", scheduler.domainTarget, scheduler.agentPath],
            .exit(5, standardError: "Load failed: 5: Input/output error")
        )
        await harness.model.applySchedule(Schedule(enabled: true))

        let problem = try #require(harness.model.scheduleProblem)
        #expect(problem.contains("launchd refused to load the scheduled check"))
        #expect(problem.contains("Load failed"))
        #expect(!harness.model.scheduleSettings.enabled)
    }

    @Test("A schedule MacUp will not change is never approved by the security gate instead")
    func approvalRefusalStopsTheChange() async throws {
        let harness = try AppModelHarness().withScheduledExecutable().withLaunchctl()
        try harness.save(security: MacUpConfiguration.SecuritySettings(requireApproval: true))
        harness.model.loadConfiguration()
        harness.authorizer.set(outcome: .declined("You cancelled, so nothing was changed."))

        await harness.model.applySchedule(Schedule(enabled: true))

        #expect(harness.model.scheduleProblem == "You cancelled, so nothing was changed.")
        #expect(!harness.model.scheduleSettings.enabled)
        // Refused before launchd was asked anything.
        #expect(harness.launchedExecutables.isEmpty)
    }

    @Test("A schedule change never looks like a security change")
    func scheduleAndSecurityHaveTheirOwnBusyFlags() async throws {
        let harness = try AppModelHarness().withScheduledExecutable()
        #expect(!harness.model.isChangingSchedule)
        #expect(!harness.model.isChangingSecurity)

        await harness.model.applySchedule(Schedule(enabled: true))
        // The schedule change failed, and that is the schedule's problem
        // alone: the approval card must not show an error it did not cause.
        #expect(harness.model.scheduleProblem != nil)
        #expect(harness.model.securityProblem == nil)
        #expect(!harness.model.isChangingSchedule)
        #expect(!harness.model.isChangingSecurity)
    }

    @Test("A security change never looks like a schedule change")
    func securityChangeLeavesTheScheduleAlone() async throws {
        let harness = try AppModelHarness(capability: .noSensorWithFallback)
        await harness.model.applySecurity(
            MacUpConfiguration.SecuritySettings(requireApproval: true, allowPasswordFallback: false)
        )

        #expect(harness.model.securityProblem != nil)
        #expect(harness.model.scheduleProblem == nil)
        #expect(!harness.model.isChangingSchedule)
        #expect(!harness.model.isChangingSecurity)
    }

    @Test("Reading the schedule status asks launchd nothing it cannot find")
    func statusWithoutAnExecutableIsUnknown() async throws {
        let harness = try AppModelHarness()
        await harness.model.refreshScheduleStatus()
        #expect(harness.model.scheduleStatus == nil)
        #expect(harness.launchedExecutables.isEmpty)
    }
}
