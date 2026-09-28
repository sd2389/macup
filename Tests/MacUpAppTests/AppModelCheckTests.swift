import Foundation
import MacUpCore
import MacUpTestSupport
import Testing

@testable import MacUpAppCore

@Suite("What the app says about the last check")
@MainActor
struct AppModelCheckTests {
    @Test("Before any check, the app says so rather than claiming anything")
    func statusBeforeFirstCheck() throws {
        let harness = try AppModelHarness()
        #expect(harness.model.status == .notChecked)
        #expect(harness.model.status.headline == "Not checked yet")
        #expect(harness.model.updateCount == 0)
    }

    @Test("A complete check with nothing outdated is the only way to be up to date")
    func upToDateOnlyWhenComplete() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider())
        await harness.model.checkNow()
        #expect(harness.model.status == .upToDate)
        #expect(harness.model.updateCount == 0)
        #expect(harness.model.report?.isComplete == true)
    }

    @Test("Updates found are counted and reported as available")
    func countsUpdates() async throws {
        let harness = try AppModelHarness(provider: StubCheckProvider(updateNames: ["git", "wget"]))
        await harness.model.checkNow()
        #expect(harness.model.updateCount == 2)
        #expect(harness.model.status == .updatesAvailable(2))
        #expect(harness.model.status.symbolName == "arrow.down.circle")
    }

    @Test("A provider that failed is never summarised as up to date")
    func providerFailureIsNeverUpToDate() async throws {
        let provider = StubCheckProvider(outdatedError: MacUpError(.commandFailed, "brew could not be read."))
        let harness = try AppModelHarness(provider: provider)
        await harness.model.checkNow()

        #expect(harness.model.status != .upToDate)
        #expect(harness.model.status.symbolName == "exclamationmark.triangle")
        #expect(harness.model.status.reasons.contains("Homebrew could not be checked."))
        #expect(harness.model.report?.isComplete == false)
    }

    @Test("Updates the provider listed but MacUp could not read leave the check incomplete")
    func unreadableUpdatesLeaveTheCheckIncomplete() async throws {
        let provider = StubCheckProvider(updateNames: ["git"], unreadableUpdates: 2)
        let harness = try AppModelHarness(provider: provider)
        await harness.model.checkNow()

        #expect(harness.model.updateCount == 1)
        #expect(harness.model.status != .upToDate)
        #expect(harness.model.status.reasons == ["Homebrew listed 2 updates MacUp could not read."])
        #expect(harness.model.status.headline == "1 update found; check incomplete")
    }

    @Test("A cancelled check is reported as incomplete, not as a clean result")
    func cancelledCheckIsIncomplete() async throws {
        let provider = StubCheckProvider()
        let rendezvous = Rendezvous()
        provider.detectRendezvous = rendezvous
        let harness = try AppModelHarness(provider: provider)

        let check = Task { await harness.model.checkNow() }
        await rendezvous.waitUntilReached()
        check.cancel()
        rendezvous.open()
        await check.value

        #expect(harness.model.report?.cancelled == true)
        #expect(harness.model.status != .upToDate)
        #expect(harness.model.status.reasons.contains("The last check was cancelled before it finished."))
    }

    @Test("A shell environment that could not be read is said out loud, not hidden")
    func unreadableShellEnvironmentIsReported() async throws {
        let shell = FakeLoginShell(failure: MacUpError(
            .timeout,
            "MacUp waited for your shell to answer and it did not."
        ))
        let harness = try AppModelHarness(loginShell: shell)
        await harness.model.checkNow()

        #expect(harness.model.environmentProblem == "MacUp waited for your shell to answer and it did not.")
        // Tools outside the standard locations may have been missed, so the
        // check cannot be summarised as clean.
        #expect(harness.model.status != .upToDate)
        #expect(harness.model.status.reasons.contains(
            "Your shell environment could not be read, so some tools may not have been found."
        ))
        #expect(harness.model.attentionCount == 1)
        #expect(harness.model.shell == "/bin/zsh")
    }

    @Test("An overlapping check is ignored rather than run twice")
    func overlappingChecksAreIgnored() async throws {
        let provider = StubCheckProvider()
        let rendezvous = Rendezvous()
        provider.detectRendezvous = rendezvous
        let harness = try AppModelHarness(provider: provider)

        let first = Task { await harness.model.checkNow() }
        await rendezvous.waitUntilReached()
        #expect(harness.model.isChecking)

        // The second call must return at once, having started nothing.
        await harness.model.checkNow()
        #expect(provider.detections == 1)

        rendezvous.open()
        await first.value
        #expect(!harness.model.isChecking)
        #expect(provider.detections == 1)
    }

    @Test("Attention counts provider errors, warnings, and MacUp's own problems")
    func attentionCount() async throws {
        let clean = try AppModelHarness(provider: StubCheckProvider())
        #expect(clean.model.attentionCount == 0)

        let provider = StubCheckProvider(outdatedError: MacUpError(.commandFailed, "brew could not be read."))
        let failing = try AppModelHarness(provider: provider)
        await failing.model.checkNow()
        #expect(failing.model.attentionCount == 1)

        // A warning finding from a provider that otherwise succeeded counts too.
        let warned = try AppModelHarness(provider: StubCheckProvider(unreadableUpdates: 1))
        await warned.model.checkNow()
        #expect(warned.model.attentionCount == 1)
    }
}
