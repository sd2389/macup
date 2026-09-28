import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("macOS planning")
struct MacOSPlanTests {
    let provider = MacOSProvider()

    private func harness() -> ProviderHarness {
        let harness = ProviderHarness()
        harness.fileSystem.addExecutable("/usr/sbin/softwareupdate")
        return harness
    }

    private func candidate(_ fixture: String, context: ProviderContext) async throws -> UpdateCandidate {
        let listing = try await provider.outdated(context: context)
        return try #require(listing.elements.first, "no macOS candidate in \(fixture)")
    }

    @Test("macOS does not claim it can plan updates")
    func noPlanCapability() {
        #expect(!provider.capabilities.contains(.planUpdates))
        #expect(!provider.capabilities.contains(.updateSelectedItems))
    }

    @Test("macOS refuses to plan, and says what it would take")
    func refusesToPlan() async throws {
        let harness = harness()
        harness.runner.register(
            "softwareupdate",
            ["--list", "--no-scan"],
            .success(try Fixture.text("macos/list-one-update.txt"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try await candidate("macos/list-one-update.txt", context: context)
        let before = harness.requests.count

        let error = await capture { try await provider.makePlan(for: candidate, context: context) }
        #expect(error?.kind == .unsupported)
        #expect(error?.message == "MacUp reports macOS updates but does not apply them.")
        #expect(error?.detail?.contains("administrator authorization") == true)
        #expect(error?.detail?.contains("never restarts your Mac") == true)
        #expect(error?.recoverySuggestion?.contains("System Settings") == true)
        #expect(harness.requests.count == before, "refusing to plan ran a command")
    }

    @Test("There is nothing to verify, because nothing was applied")
    func verifyIsNotPerformed() async throws {
        let harness = harness()
        harness.runner.register(
            "softwareupdate",
            ["--list", "--no-scan"],
            .success(try Fixture.text("macos/list-one-update.txt"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try await candidate("macos/list-one-update.txt", context: context)

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .notPerformed)
        #expect(result.message.contains("does not apply macOS updates"))
    }

    @Test("No rule in the modifying allowlist mentions softwareupdate")
    func softwareUpdateIsNotInTheRules() {
        #expect(!ModifyingCommandRules.all.contains { $0.executableName == "softwareupdate" })
    }
}
