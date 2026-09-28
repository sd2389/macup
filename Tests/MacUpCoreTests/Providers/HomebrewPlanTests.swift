import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Homebrew planning")
struct HomebrewPlanTests {
    let provider = HomebrewProvider()

    private func harness() -> ProviderHarness {
        let harness = ProviderHarness()
        harness.fileSystem.addExecutable("/opt/homebrew/bin/brew")
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6-54-g86650d0\n"))
        harness.runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        return harness
    }

    private func candidates(_ fixture: String) throws -> [UpdateCandidate] {
        try HomebrewOutdatedParser.parse(Fixture.data(fixture), ownership: nil).elements
    }

    private func candidate(_ fixture: String, _ id: String) throws -> UpdateCandidate {
        try #require(try candidates(fixture).first { $0.id.rawValue == id }, "no candidate \(id)")
    }

    @Test("Homebrew declares that it can plan and verify updates")
    func capabilities() {
        #expect(provider.capabilities.contains(.planUpdates))
        #expect(provider.capabilities.contains(.verifyUpdates))
    }

    @Test("A formula plan names the formula and nothing else")
    func formulaPlan() async throws {
        let harness = harness()
        let context = try await harness.planningContext(provider)
        let before = harness.requests.count

        let plan = try await provider.makePlan(for: try candidate("homebrew/outdated-formula.json", "brew:git"), context: context)

        let command = try plan.command
        #expect(command.executable == "/opt/homebrew/bin/brew")
        #expect(command.arguments == ["upgrade", "--formula", "--yes", "git"])
        #expect(try plan.onlyStep.effect == .modifying)
        #expect(plan.item.rawValue == "brew:git")
        #expect(plan.currentVersion == "2.43.0")
        #expect(plan.proposedVersion == "2.44.0")
        #expect(plan.createdAt == planningInstant)
        expectAllowedByRules(plan)
        #expect(harness.requests.count == before, "planning ran a command")
    }

    @Test("A cask plan uses Homebrew's cask invocation, not the formula one")
    func caskPlan() async throws {
        let context = try await harness().planningContext(provider)
        let plan = try await provider.makePlan(
            for: try candidate("homebrew/outdated-cask.json", "brew-cask:firefox"),
            context: context
        )
        #expect(try plan.command.arguments == ["upgrade", "--cask", "--yes", "firefox"])
        expectAllowedByRules(plan)
    }

    @Test("A plan promises network, no privilege, no restart, and no config change")
    func formulaPlanFacts() async throws {
        let context = try await harness().planningContext(provider)
        let plan = try await provider.makePlan(for: try candidate("homebrew/outdated-formula.json", "brew:git"), context: context)
        #expect(plan.expectsNetwork)
        #expect(!plan.mayRequirePrivilege)
        #expect(!plan.mayRequireRestart)
        #expect(!plan.mayChangeUserConfiguration)
        #expect(plan.risk.level == .moderate)
        #expect(plan.rationale.contains("the items you excluded stay excluded"))
        #expect(plan.rationale.contains("skip its automatic cleanup"))
    }

    @Test("Rollback is never claimed for a Homebrew upgrade")
    func noRollback() async throws {
        let context = try await harness().planningContext(provider)
        for result in await plans(provider, for: try candidates("homebrew/outdated-both.json"), context: context) {
            let plan = try result.get()
            #expect(plan.rollback.availability == .unavailable)
            #expect(plan.rollback.explanation.contains("no tested rollback"))
        }
    }

    @Test("A cask that runs an installer package says an administrator may be asked")
    func caskNeedingAdministrator() async throws {
        let context = try await harness().planningContext(provider)
        let inventory = try HomebrewInventoryParser.parse(Fixture.data("homebrew/info-installed.json"), ownership: nil)
        // zoom in that inventory installs through a pkg artifact; firefox
        // installs an app bundle and needs no authorization.
        let zoom = UpdateCandidate(
            id: try PackageID(.brewCask, "zoom"),
            kind: .cask,
            displayName: "zoom",
            installedVersion: "6.0.0",
            availableVersion: "6.1.0"
        )
        let refined = provider.refine(
            [zoom] + (try candidates("homebrew/outdated-cask.json")),
            using: inventory.elements
        )

        let zoomPlan = try await provider.makePlan(for: try #require(refined.first), context: context)
        #expect(zoomPlan.mayRequirePrivilege)
        #expect(try zoomPlan.onlyStep.mayRequirePrivilege)
        #expect(zoomPlan.rationale.contains("neither supplies nor stores one"))

        let firefox = try #require(refined.first { $0.id.rawValue == "brew-cask:firefox" })
        #expect(!(try await provider.makePlan(for: firefox, context: context)).mayRequirePrivilege)
    }

    @Test("A Homebrew-pinned item cannot be planned, so MacUp never unpins it")
    func pinnedItemsRefuse() async throws {
        let context = try await harness().planningContext(provider)
        for candidate in try candidates("homebrew/outdated-pinned.json") {
            await #expect(throws: MacUpError.self) {
                try await provider.makePlan(for: candidate, context: context)
            }
            let error = await capture { try await provider.makePlan(for: candidate, context: context) }
            #expect(error?.kind == .unsupported)
            #expect(error?.message.contains("does not unpin") == true)
        }
    }

    @Test("Unusual but valid names travel verbatim as one argument, never as a shell string")
    func hostileNames() async throws {
        let context = try await harness().planningContext(provider)
        let candidates = try candidates("homebrew/outdated-unusual-names.json")
        #expect(candidates.count >= 6, "the fixture should still carry hostile-but-valid names")

        for candidate in candidates {
            let plan = try await provider.makePlan(for: candidate, context: context)
            let arguments = try plan.command.arguments
            #expect(arguments.count == 4)
            #expect(arguments.last == candidate.id.name, "the name must be one unmodified argument")
            #expect(!arguments.contains { $0.contains("sh -c") })
            expectAllowedByRules(plan)
        }
    }

    @Test("Every hostile name the test plan lists stays one argument, or is refused")
    func hostileNamesFromTheTestPlan() async throws {
        let context = try await harness().planningContext(provider)
        var planned = 0
        for name in HostileInput.names {
            guard PackageID.validateName(name) == nil else { continue }
            let candidate = UpdateCandidate(
                id: try PackageID(.brew, name),
                kind: .formula,
                displayName: name,
                installedVersion: "1.0",
                availableVersion: "1.1"
            )
            let plan = try await provider.makePlan(for: candidate, context: context)
            #expect(try plan.command.arguments == ["upgrade", "--formula", "--yes", name])
            expectAllowedByRules(plan)
            planned += 1
        }
        #expect(planned >= 10, "the hostile-name list should still exercise this")
    }

    @Test("A name MacUp cannot render exactly is refused rather than passed on")
    func unrenderableNameRefused() async throws {
        let context = try await harness().planningContext(provider)
        for name in HostileInput.unrepresentableNames {
            // These cannot become a PackageID at all, which is the first
            // gate; the planner's own check is the second.
            #expect(PackageID.validateName(name) != nil, "\(name.debugDescription) should not be a usable name")
            #expect(!ModifyingCommandRule.isAcceptablePositional(name))
        }
        // A name that is long enough to be a valid ID but too long to pass as
        // an argument proves the planner checks rather than assumes.
        let long = String(repeating: "a", count: PackageID.maximumNameLength)
        let candidate = UpdateCandidate(
            id: try PackageID(.brew, long),
            kind: .formula,
            displayName: long,
            installedVersion: "1.0",
            availableVersion: "1.1"
        )
        #expect(try await provider.makePlan(for: candidate, context: context).command.arguments.last == long)
    }

    @Test("Planning without a recorded installation fails closed")
    func noInstallation() async throws {
        let harness = harness()
        let error = await capture {
            try await provider.makePlan(
                for: try candidate("homebrew/outdated-formula.json", "brew:git"),
                context: harness.context()
            )
        }
        #expect(error?.kind == .providerUnavailable)
        #expect(harness.requests.isEmpty)
    }

    @Test("The environment an upgrade runs with forbids cleanup and dependents")
    func executionEnvironment() async throws {
        let context = try await harness().planningContext(provider)
        let environment = provider.executionEnvironment(context: context)
        #expect(environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] == "1")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil, "an upgrade gets no more of the environment than a check")
    }

    @Test("Verification reads the installed versions back and confirms the target")
    func verifySuccess() async throws {
        let harness = harness()
        harness.runner.register(
            "brew",
            HomebrewProvider.installedInfoArguments,
            .success(try Fixture.text("homebrew/info-after-upgrade.json"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("homebrew/outdated-formula.json", "brew:git")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .verified)
        #expect(result.observedVersion == "2.44.0")
        #expect(result.expectedVersion == "2.44.0")
    }

    @Test("A version that did not move is reported as not reached, not as success")
    func verifyTargetNotReached() async throws {
        let harness = harness()
        harness.runner.register(
            "brew",
            HomebrewProvider.installedInfoArguments,
            .success(try Fixture.text("homebrew/info-installed.json"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("homebrew/outdated-formula.json", "brew:git")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .targetNotReached)
        #expect(result.observedVersion == "2.43.0")
        #expect(result.message.contains("the plan proposed 2.44.0"))
    }

    @Test("An item Homebrew no longer lists cannot be confirmed")
    func verifyMissingItem() async throws {
        let harness = harness()
        harness.runner.register(
            "brew",
            HomebrewProvider.installedInfoArguments,
            .success(try Fixture.text("homebrew/info-installed.json"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("homebrew/outdated-both.json", "brew:mise")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.observedVersion == nil)
    }

    @Test("Output MacUp cannot parse is a failed verification, never a verified one")
    func verifyUnparseable() async throws {
        let harness = harness()
        harness.runner.register("brew", HomebrewProvider.installedInfoArguments, .success("{ this is not json"))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("homebrew/outdated-formula.json", "brew:git")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("not valid JSON"))
    }

    @Test("A failed read-back is a failed verification")
    func verifyCommandFailed() async throws {
        let harness = harness()
        harness.runner.register("brew", HomebrewProvider.installedInfoArguments, .exit(1, standardError: "Error: broken\n"))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("homebrew/outdated-formula.json", "brew:git")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("`brew info` failed"))
    }

    @Test("Verification prefers the linked keg, because old kegs are left in place")
    func observedVersionPrefersLinkedKeg() {
        let item = ManagedItem(
            id: try! PackageID(.brew, "git"),
            kind: .formula,
            displayName: "git",
            installedVersions: ["2.43.0", "2.44.0"],
            activeVersion: "2.43.0"
        )
        #expect(HomebrewProvider.observedVersion(of: item) == "2.43.0")

        var unlinked = item
        unlinked.activeVersion = nil
        #expect(HomebrewProvider.observedVersion(of: unlinked) == "2.44.0", "no linked keg: the newest one present")
    }
}

/// Runs an operation and returns the ``MacUpError`` it threw, if any.
func capture(_ operation: () async throws -> some Any) async -> MacUpError? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return MacUpError.wrapping(error, context: "The operation")
    }
}

extension ExecutionResult {
    /// A succeeded result, for verification tests that only need the item.
    static func stub(_ item: PackageID) -> ExecutionResult {
        ExecutionResult(
            planID: UUID(),
            item: item,
            outcome: .succeeded,
            startedAt: planningInstant,
            finishedAt: planningInstant
        )
    }
}
