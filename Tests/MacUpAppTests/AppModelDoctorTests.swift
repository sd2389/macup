import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the Doctor screen is given to show")
@MainActor
struct AppModelDoctorTests {
    private static let findings = [
        DiagnosticFinding.test(.info, id: "test.note", title: "Something MacUp noticed"),
        DiagnosticFinding.test(.error, id: "test.problem", title: "Two Homebrew installations", recommendation: "Pick one."),
        DiagnosticFinding.test(.warning, id: "test.warning", title: "Node is managed by two things at once"),
    ]

    @Test("Findings come back most severe first, whatever order the checks ran in")
    func findingsAreOrderedMostSevereFirst() async throws {
        let harness = try AppModelHarness(doctorChecks: [StubDiagnosticCheck(findings: Self.findings)])
        await harness.model.runDoctor()

        let report = try #require(harness.model.doctorReport)
        #expect(report.findings.map(\.severity) == [.error, .warning, .info])
        #expect(report.summary.errors == 1)
        #expect(report.summary.warnings == 1)
        #expect(report.summary.notes == 1)
        #expect(report.summary.checksRun == 1)
        #expect(!report.isHealthy)
    }

    @Test("A Mac with nothing wrong reads as healthy, with the notes still available")
    func aHealthyMacIsCalm() async throws {
        let harness = try AppModelHarness(doctorChecks: [StubDiagnosticCheck(findings: [
            DiagnosticFinding.test(.info, id: "test.note", title: "Something MacUp noticed"),
        ])])
        await harness.model.runDoctor()

        let report = try #require(harness.model.doctorReport)
        #expect(report.isHealthy)
        #expect(report.summary.errors == 0)
        #expect(report.summary.warnings == 0)
        #expect(report.summary.notes == 1)
        #expect(harness.model.doctorProblem == nil)
    }

    @Test("A check that finds nothing leaves Doctor with a report, not with nothing")
    func noFindingsIsStillAReport() async throws {
        let harness = try AppModelHarness(doctorChecks: [StubDiagnosticCheck()])
        await harness.model.runDoctor()

        let report = try #require(harness.model.doctorReport)
        #expect(report.findings.isEmpty)
        #expect(report.isHealthy)
        // What MacUp looked at is still worth showing on a healthy Mac.
        #expect(!report.providers.isEmpty)
        #expect(report.configuration.path == harness.paths.configFile)
    }

    @Test("What a provider noticed while being checked reaches Doctor too")
    func providerFindingsReachDoctor() async throws {
        let harness = try AppModelHarness(
            provider: StubCheckProvider(updateNames: ["git"], unreadableUpdates: 1),
            doctorChecks: []
        )
        await harness.model.runDoctor()

        let report = try #require(harness.model.doctorReport)
        #expect(report.findings.contains { $0.id == "homebrew.unreadableEntry" })
        #expect(report.summary.warnings == 1)
    }

    @Test("Doctor runs no command of its own on this Mac")
    func doctorLaunchesNothing() async throws {
        let harness = try AppModelHarness(doctorChecks: [StubDiagnosticCheck(findings: Self.findings)])
        await harness.model.runDoctor()

        // The only shell the app ever asks for is the login-shell probe, and
        // the fake runner refuses that too.
        let attempted = Set(harness.launchedExecutables.map { ($0 as NSString).lastPathComponent })
        #expect(attempted.subtracting(["zsh", "bash", "sh", "fish"]).isEmpty)
    }

    @Test("An overlapping run is ignored rather than started twice")
    func overlappingRunsAreIgnored() async throws {
        let harness = try AppModelHarness(doctorChecks: [StubDiagnosticCheck(findings: Self.findings)])
        await harness.model.runDoctor()
        let first = try #require(harness.model.doctorReport)

        await harness.model.runDoctor()
        let second = try #require(harness.model.doctorReport)
        #expect(second.findings == first.findings)
        #expect(!harness.model.isDiagnosing)
    }
}
