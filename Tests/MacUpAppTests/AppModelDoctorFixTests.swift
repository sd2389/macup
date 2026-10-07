import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

/// The Fix button on a Doctor finding: review first, then one change to
/// MacUp's own settings.
@MainActor
@Suite("App: Doctor fixes")
struct AppModelDoctorFixTests {
    private func finding() -> DiagnosticFinding {
        DiagnosticFinding(
            id: "configuration.staleItemPolicy",
            severity: .info,
            provider: nil,
            title: "A policy names software that is not installed",
            fix: DiagnosticFix(
                action: .clearItemRules(["brew:not-installed"]),
                summary: "Drop this rule",
                detail: "Removes brew:not-installed from MacUp's configuration."
            )
        )
    }

    private func harness() throws -> AppModelHarness {
        let harness = try AppModelHarness()
        let store = ConfigurationStore(paths: try harness.model.resolvedPaths())
        var configuration = MacUpConfiguration.defaults
        configuration.items["brew:not-installed"] = MacUpConfiguration.ItemSettings(policy: .ignore)
        try store.save(configuration)
        return harness
    }

    @Test("Pressing Fix opens the review and changes nothing yet")
    func reviewFirst() throws {
        let harness = try harness()
        harness.model.reviewFix(for: finding())

        #expect(harness.model.doctorFixes.reviewing?.id == "configuration.staleItemPolicy")
        #expect(harness.model.doctorFixes.result == nil)
        let store = ConfigurationStore(paths: try harness.model.resolvedPaths())
        #expect(store.load().configuration.items["brew:not-installed"] != nil)
    }

    @Test("Cancelling the review changes nothing")
    func cancel() throws {
        let harness = try harness()
        harness.model.reviewFix(for: finding())
        harness.model.cancelFix()

        #expect(harness.model.doctorFixes.reviewing == nil)
        let store = ConfigurationStore(paths: try harness.model.resolvedPaths())
        #expect(store.load().configuration.items["brew:not-installed"] != nil)
    }

    @Test("Confirming makes the one change, and says what it did")
    func apply() async throws {
        let harness = try harness()
        harness.model.reviewFix(for: finding())
        await harness.model.applyReviewedFix()

        let result = try #require(harness.model.doctorFixes.result)
        #expect(result.succeeded)
        #expect(result.changes.count == 1)
        #expect(harness.model.doctorFixes.reviewing == nil)
        let store = ConfigurationStore(paths: try harness.model.resolvedPaths())
        #expect(store.load().configuration.items["brew:not-installed"] == nil)
        #expect(harness.runner.recordedRequests.allSatisfy { $0.effect != .modifying }, "no package manager ran")
    }

    @Test("A finding with no fix is never reviewed")
    func noFix() throws {
        let harness = try harness()
        harness.model.reviewFix(for: DiagnosticFinding(
            id: "homebrew.multipleInstallations",
            severity: .warning,
            provider: .homebrew,
            title: "Two Homebrews"
        ))
        #expect(harness.model.doctorFixes.reviewing == nil)
    }
}
