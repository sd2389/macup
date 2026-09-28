import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("mise planning")
struct MisePlanTests {
    let provider = MiseProvider()

    private func harness() -> ProviderHarness {
        let harness = ProviderHarness(path: "/Users/example/.local/bin:/usr/bin:/bin")
        harness.fileSystem.addExecutable("/Users/example/.local/bin/mise")
        harness.runner.register("mise", ["--version"], .success("2026.7.3 macos-arm64 (2026-07-08)\n"))
        return harness
    }

    private func candidates(_ fixture: String, fileSystem: FakeFileSystem = FakeFileSystem()) throws -> [UpdateCandidate] {
        try MiseParsers.parseOutdated(
            Fixture.data(fixture),
            context: MiseParsers.Context(
                homeDirectory: "/Users/example",
                directories: MiseProvider.directories(environment: [:], homeDirectory: "/Users/example"),
                miseLink: OwnershipLink(label: "mise 2026.7.3"),
                fileSystem: fileSystem
            )
        ).elements
    }

    private func candidate(_ fixture: String, _ id: String, fileSystem: FakeFileSystem = FakeFileSystem()) throws -> UpdateCandidate {
        try #require(try candidates(fixture, fileSystem: fileSystem).first { $0.id.rawValue == id }, "no candidate \(id)")
    }

    @Test("mise declares that it can plan and verify updates")
    func capabilities() {
        #expect(provider.capabilities.contains(.planUpdates))
        #expect(provider.capabilities.contains(.verifyUpdates))
    }

    @Test("A plan upgrades within the requested range and never passes the bumping flag")
    func rangePreserved() async throws {
        let harness = harness()
        let context = try await harness.planningContext(provider)
        let before = harness.requests.count

        let plan = try await provider.makePlan(
            for: try candidate("mise/outdated-global-fuzzy.json", "mise:node"),
            context: context
        )

        let command = try plan.command
        #expect(command.executable == "/Users/example/.local/bin/mise")
        #expect(command.arguments == ["upgrade", "--cd", "/Users/example", "node"])
        #expect(!command.arguments.contains("--bump"))
        #expect(!command.arguments.contains("-l"))
        #expect(plan.proposedVersion == "24.21.0")
        #expect(plan.rationale.contains("your request \"24\""))
        #expect(plan.rationale.contains("no major version is bumped"))
        // mise leaves the old version installed, which is what `mise prune`
        // exists to clean up and what MacUp never runs.
        #expect(plan.rationale.contains("stays installed"))
        #expect(!plan.steps.contains { $0.invocation.arguments.contains("prune") })
        expectAllowedByRules(plan)
        #expect(harness.requests.count == before, "planning ran a command")
    }

    @Test("No mise plan ever carries the bumping flag")
    func neverBumps() async throws {
        let context = try await harness().planningContext(provider)
        for fixture in ["mise/outdated-global-fuzzy.json", "mise/outdated-scopes.json", "mise/outdated-legacy-format.json"] {
            for result in await plans(provider, for: try candidates(fixture), context: context) {
                guard let plan = try? result.get() else { continue }
                for step in plan.steps {
                    #expect(!step.invocation.arguments.contains { $0 == "--bump" || $0 == "-l" })
                    #expect(step.invocation.arguments.first == "upgrade")
                }
                expectAllowedByRules(plan)
            }
        }
    }

    @Test("Every mise plan says a lockfile may change, and names one when it exists")
    func lockfileIsDeclared() async throws {
        let context = try await harness().planningContext(provider)

        let withoutLockfile = try await provider.makePlan(
            for: try candidate("mise/outdated-global-fuzzy.json", "mise:node"),
            context: context
        )
        #expect(withoutLockfile.mayChangeUserConfiguration)
        #expect(withoutLockfile.rationale.contains("configuration is not rewritten"))
        #expect(withoutLockfile.rationale.contains("lockfiles enabled"))

        let fileSystem = FakeFileSystem()
        _ = fileSystem.addFile("/Users/example/.config/mise/mise.lock")
        let locked = try candidate("mise/outdated-global-fuzzy.json", "mise:node", fileSystem: fileSystem)
        #expect(locked.details["lockfile"] == "/Users/example/.config/mise/mise.lock")

        let lockedPlan = try await provider.makePlan(for: locked, context: context)
        #expect(lockedPlan.mayChangeUserConfiguration)
        #expect(lockedPlan.rationale.contains("/Users/example/.config/mise/mise.lock"))
    }

    @Test("A project's own configuration stays informational")
    func projectScopeRefused() async throws {
        let context = try await harness().planningContext(provider)
        let candidate = try candidate("mise/outdated-local-project.json", "mise:node")
        #expect(candidate.details["configScope"] == "project")

        let error = await capture { try await provider.makePlan(for: candidate, context: context) }
        #expect(error?.kind == .unsupported)
        #expect(error?.message.contains("reports it rather than changing it") == true)
    }

    @Test("System-wide and unattributable requests are refused rather than guessed")
    func systemAndUnknownScopesRefused() async throws {
        let context = try await harness().planningContext(provider)

        let system = try candidate("mise/outdated-scopes.json", "mise:npm:prettier")
        #expect(system.details["configScope"] == "system")
        #expect(await capture { try await provider.makePlan(for: system, context: context) }?.message
            .contains("system-wide mise configuration") == true)

        let unknown = try candidate("mise/outdated-scopes.json", "mise:deno")
        #expect(unknown.details["configScope"] == "unknown")
        #expect(await capture { try await provider.makePlan(for: unknown, context: context) }?.message
            .contains("could not tell which configuration file") == true)
    }

    @Test("A home-directory request is planned, because it is not a project's")
    func homeScopePlanned() async throws {
        let context = try await harness().planningContext(provider)
        let ruby = try candidate("mise/outdated-scopes.json", "mise:ruby")
        #expect(ruby.details["configScope"] == "home")
        #expect(try await provider.makePlan(for: ruby, context: context).command.arguments
            == ["upgrade", "--cd", "/Users/example", "ruby"])
    }

    @Test("An exact pin is refused, because reaching the new version means editing the request")
    func exactPinRefused() async throws {
        let context = try await harness().planningContext(provider)
        let pinned = try candidate("mise/outdated-exact-pin.json", "mise:node")

        let error = await capture { try await provider.makePlan(for: pinned, context: context) }
        #expect(error?.kind == .unsupported)
        #expect(error?.message.contains("pinned to exactly 24.18.0") == true)
        #expect(error?.message.contains("MacUp does not do for you") == true)
    }

    @Test("A runtime change is called out in the plan")
    func runtimeIsCalledOut() async throws {
        let context = try await harness().planningContext(provider)
        let plan = try await provider.makePlan(
            for: try candidate("mise/outdated-global-fuzzy.json", "mise:node"),
            context: context
        )
        #expect(plan.rationale.contains("language runtime"))
        #expect(plan.rationale.contains("Global npm packages are installed per Node version"))
        #expect(plan.risk.level == .moderate)
        #expect(plan.rollback.availability == .unavailable)
        #expect(!plan.mayRequirePrivilege)
        #expect(!plan.mayRequireRestart)
    }

    @Test("Hostile tool names stay one argument after the directory")
    func hostileNamesFromTheTestPlan() async throws {
        let context = try await harness().planningContext(provider)
        var planned = 0
        for name in HostileInput.names where PackageID.validateName(name) == nil {
            let candidate = UpdateCandidate(
                id: try PackageID(.mise, name),
                kind: .tool,
                displayName: name,
                installedVersion: "1.0.0",
                availableVersion: "1.1.0",
                details: ["configScope": "global", "requested": "1"]
            )
            let plan = try await provider.makePlan(for: candidate, context: context)
            #expect(try plan.command.arguments == ["upgrade", "--cd", "/Users/example", name])
            expectAllowedByRules(plan)
            planned += 1
        }
        #expect(planned >= 10, "the hostile-name list should still exercise this")
    }

    @Test("The environment an upgrade runs with keeps mise's own variables")
    func executionEnvironment() async throws {
        let harness = harness()
        harness.environment["MISE_GLOBAL_CONFIG_FILE"] = "/Users/example/.config/mise/config.toml"
        let context = try await harness.planningContext(provider)

        let environment = provider.executionEnvironment(context: context)
        #expect(environment["MISE_GLOBAL_CONFIG_FILE"] == "/Users/example/.config/mise/config.toml")
        #expect(environment["GITHUB_TOKEN"] == "ghp_testtokentesttokentesttoken00")
        #expect(environment["PATH"]?.hasPrefix("/Users/example/.local/bin:") == true)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    }

    @Test("Verification lists mise's tools again and confirms the active version")
    func verifySuccess() async throws {
        let harness = harness()
        harness.runner.register("mise", MiseProvider.toolListArguments, .success(try Fixture.text("mise/ls-after-upgrade.json")))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("mise/outdated-global-fuzzy.json", "mise:node")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .verified)
        #expect(result.observedVersion == "24.21.0")
    }

    @Test("An unchanged active version is reported as not reached")
    func verifyTargetNotReached() async throws {
        let harness = harness()
        harness.runner.register("mise", MiseProvider.toolListArguments, .success(try Fixture.text("mise/ls.json")))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("mise/outdated-global-fuzzy.json", "mise:node")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .targetNotReached)
        #expect(result.observedVersion == "24.19.0")
    }

    @Test("Output MacUp cannot parse is a failed verification, never a verified one")
    func verifyUnparseable() async throws {
        let harness = harness()
        harness.runner.register("mise", MiseProvider.toolListArguments, .success("{\"node\": "))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("mise/outdated-global-fuzzy.json", "mise:node")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("not valid JSON"))
    }

    @Test("A failed read-back is a failed verification")
    func verifyCommandFailed() async throws {
        let harness = harness()
        harness.runner.register("mise", MiseProvider.toolListArguments, .exit(1, standardError: "mise ERROR broken\n"))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("mise/outdated-global-fuzzy.json", "mise:node")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("`mise ls` failed"))
    }
}
