import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("npm planning")
struct NpmPlanTests {
    let provider = NpmProvider()
    private let globalRoot = "/opt/homebrew/lib/node_modules"

    private func harness() -> ProviderHarness {
        let harness = ProviderHarness()
        // A Homebrew node is a symlink into the Cellar, which is how
        // ownership is recognized.
        harness.fileSystem
            .addExecutable("/opt/homebrew/bin/npm")
            .addSymlink("/opt/homebrew/bin/node", to: "/opt/homebrew/Cellar/node/24.19.0/bin/node")
            .addExecutable("/opt/homebrew/Cellar/node/24.19.0/bin/node")
            .addDirectory(globalRoot)
        harness.runner.register("npm", ["--version"], .success("11.17.0\n"))
        harness.runner.register("node", ["--version"], .success("v24.19.0\n"))
        harness.runner.register("npm", ["prefix", "-g"], .success("/opt/homebrew\n"))
        harness.runner.register("npm", ["root", "-g"], .success(globalRoot + "\n"))
        return harness
    }

    private func candidates() throws -> [UpdateCandidate] {
        let text = try Fixture.text("npm/outdated-global.json").replacingOccurrences(
            of: "/Users/example/.local/share/mise/installs/node/24.19.0/lib/node_modules",
            with: globalRoot
        )
        return try NpmParsers.parseOutdated(
            .fixture(text, exitStatus: 1),
            context: NpmParsers.Context(globalRoot: globalRoot, nodeManager: .homebrew)
        ).elements
    }

    private func candidate(_ id: String) throws -> UpdateCandidate {
        try #require(try candidates().first { $0.id.rawValue == id }, "no candidate \(id)")
    }

    @Test("npm declares that it can plan and verify updates")
    func capabilities() {
        #expect(provider.capabilities.contains(.planUpdates))
        #expect(provider.capabilities.contains(.verifyUpdates))
    }

    @Test("A scoped package becomes one argument with the version named")
    func scopedPackagePlan() async throws {
        let harness = harness()
        let context = try await harness.planningContext(provider)
        let before = harness.requests.count

        let plan = try await provider.makePlan(for: try candidate("npm:@anthropic-ai/claude-code"), context: context)

        let command = try plan.command
        #expect(command.executable == "/opt/homebrew/bin/npm")
        #expect(command.arguments == ["install", "-g", "@anthropic-ai/claude-code@2.1.283"])
        #expect(try plan.onlyStep.effect == .modifying)
        #expect(plan.proposedVersion == "2.1.283")
        expectAllowedByRules(plan)
        #expect(harness.requests.count == before, "planning ran a command")
    }

    @Test("Exactly one package is named, so nothing else is swept along")
    func onePackagePerPlan() async throws {
        let context = try await harness().planningContext(provider)
        for result in await plans(provider, for: try candidates(), context: context) {
            let plan = try result.get()
            let arguments = try plan.command.arguments
            #expect(arguments.prefix(2) == ["install", "-g"])
            #expect(arguments.count == 3)
            expectAllowedByRules(plan)
        }
    }

    @Test("Updating npm itself says what it replaces and which tool manages Node")
    func selfUpdateIsNoted() async throws {
        let context = try await harness().planningContext(provider)
        let plan = try await provider.makePlan(for: try candidate("npm:npm"), context: context)

        #expect(try plan.command.arguments == ["install", "-g", "npm@12.1.0"])
        #expect(plan.rationale.contains("replaces the npm your shell and MacUp use"))
        #expect(plan.rationale.contains("managed by Homebrew"))
        #expect(plan.rationale.contains("Updating Node through Homebrew"))
    }

    @Test("A plan names the Node that owns the global packages")
    func nodeOwnershipIsNamed() async throws {
        let context = try await harness().planningContext(provider)
        let plan = try await provider.makePlan(for: try candidate("npm:corepack"), context: context)
        #expect(plan.rationale.contains("/opt/homebrew/bin/node"))
        #expect(plan.rationale.contains("v24.19.0"))
        #expect(plan.rationale.contains("MacUp never uses sudo"))
        #expect(!plan.mayRequirePrivilege, "npm fails rather than escalating")
        #expect(!plan.mayChangeUserConfiguration)
        #expect(!plan.mayRequireRestart)
        #expect(plan.expectsNetwork)
        #expect(plan.rollback.availability == .unavailable)
    }

    @Test("A package under a mise-managed Node names mise as the owner")
    func miseManagedNode() async throws {
        let miseRoot = "/Users/example/.local/share/mise/installs/node/24.19.0"
        let harness = ProviderHarness(path: "\(miseRoot)/bin:/usr/bin:/bin")
        harness.fileSystem
            .addExecutable("\(miseRoot)/bin/npm")
            .addExecutable("\(miseRoot)/bin/node")
            .addDirectory("\(miseRoot)/lib/node_modules")
        harness.runner.register("npm", ["--version"], .success("11.17.0\n"))
        harness.runner.register("node", ["--version"], .success("v24.19.0\n"))
        harness.runner.register("npm", ["prefix", "-g"], .success(miseRoot + "\n"))
        harness.runner.register("npm", ["root", "-g"], .success("\(miseRoot)/lib/node_modules\n"))
        let context = try await harness.planningContext(provider)

        let candidate = UpdateCandidate(
            id: try PackageID(.npm, "npm"),
            kind: .globalPackage,
            displayName: "npm",
            installedVersion: "11.17.0",
            availableVersion: "12.1.0",
            signals: [.packageManagerSelfUpdate]
        )
        let plan = try await provider.makePlan(for: candidate, context: context)
        #expect(try plan.command.executable == "\(miseRoot)/bin/npm")
        #expect(plan.rationale.contains("managed by mise"))
        #expect(plan.rationale.contains("changing the active version with mise"))
    }

    @Test("Unusual but valid package names travel verbatim, never as a shell string")
    func hostileNames() async throws {
        let context = try await harness().planningContext(provider)
        let listing = try NpmParsers.parseOutdated(
            .fixture(try Fixture.text("npm/outdated-hostile-names.json"), exitStatus: 1),
            context: NpmParsers.Context()
        )
        #expect(!listing.elements.isEmpty, "the fixture should still carry hostile-but-valid names")

        for candidate in listing.elements {
            guard let plan = try? await provider.makePlan(for: candidate, context: context) else { continue }
            let arguments = try plan.command.arguments
            #expect(arguments.count == 3)
            #expect(arguments[2] == "\(candidate.id.name)@\(candidate.availableVersion.raw)")
            #expect(arguments[2].hasPrefix(candidate.id.name), "the name must stay one unmodified argument")
            expectAllowedByRules(plan)
        }
    }

    @Test("A dist tag, range, or path where a version belongs is refused, not repeated to npm")
    func suspiciousVersionRefused() async throws {
        let context = try await harness().planningContext(provider)
        let candidate = { (offered: String) throws -> UpdateCandidate in
            UpdateCandidate(
                id: try PackageID(.npm, "example"),
                kind: .globalPackage,
                displayName: "example",
                installedVersion: "1.0.0",
                availableVersion: AvailableVersion(offered)
            )
        }
        for offered in ["latest", "next", "^1.0.0", "~1.0", "file:../evil", "1.0.0 || 2.0.0", "-rf", "", ".1.0", "v1.0.0",
                        "github:owner/repo", "https://example.invalid/pkg.tgz"] {
            let error = await capture { try await provider.makePlan(for: try candidate(offered), context: context) }
            #expect(error?.kind == .unsupported, "\(offered.debugDescription) should not be planned")
        }

        // Real published versions, including pre-releases and build metadata.
        for offered in ["1.0.0", "2.1.283", "3.0.0-rc.1", "1.0.0+build.5"] {
            let plan = try await provider.makePlan(for: try candidate(offered), context: context)
            #expect(try plan.command.arguments == ["install", "-g", "example@\(offered)"])
        }
    }

    @Test("Hostile package names travel verbatim as one argument, never as a shell string")
    func hostileNamesFromTheTestPlan() async throws {
        let context = try await harness().planningContext(provider)
        var planned = 0
        for name in HostileInput.names where PackageID.validateName(name) == nil {
            let candidate = UpdateCandidate(
                id: try PackageID(.npm, name),
                kind: .globalPackage,
                displayName: name,
                installedVersion: "1.0.0",
                availableVersion: "2.0.0"
            )
            let plan = try await provider.makePlan(for: candidate, context: context)
            let arguments = try plan.command.arguments
            #expect(arguments == ["install", "-g", "\(name)@2.0.0"])
            expectAllowedByRules(plan)
            planned += 1
        }
        #expect(planned >= 10, "the hostile-name list should still exercise this")
    }

    @Test("The environment an install runs with is npm's own, not MacUp's whole environment")
    func executionEnvironment() async throws {
        let context = try await harness().planningContext(provider)
        let environment = provider.executionEnvironment(context: context)
        #expect(environment["npm_config_update_notifier"] == "false")
        #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(environment["NODE_OPTIONS"] == nil, "an install never inherits code-loading variables")
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
    }

    @Test("Verification lists the global packages again and confirms the version")
    func verifySuccess() async throws {
        let harness = harness()
        harness.runner.register(
            "npm",
            NpmProvider.globalListArguments,
            .success(try Fixture.text("npm/ls-global-after-upgrade.json"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("npm:@anthropic-ai/claude-code")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .verified)
        #expect(result.observedVersion == "2.1.283")
    }

    @Test("A package still at its old version is reported as not reached")
    func verifyTargetNotReached() async throws {
        let harness = harness()
        harness.runner.register("npm", NpmProvider.globalListArguments, .success(try Fixture.text("npm/ls-global.json")))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("npm:@anthropic-ai/claude-code")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .targetNotReached)
        #expect(result.observedVersion == "2.1.282")
    }

    @Test("A package npm no longer lists cannot be confirmed")
    func verifyMissingPackage() async throws {
        let harness = harness()
        harness.runner.register("npm", NpmProvider.globalListArguments, .success(try Fixture.text("npm/ls-global-empty.json")))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("npm:corepack")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("no longer lists corepack"))
    }

    @Test("Output MacUp cannot parse is a failed verification, never a verified one")
    func verifyUnparseable() async throws {
        let harness = harness()
        harness.runner.register("npm", NpmProvider.globalListArguments, .success("not json at all"))
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("npm:corepack")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
    }

    @Test("npm reporting an error in JSON is a failed verification")
    func verifyReportedError() async throws {
        let harness = harness()
        harness.runner.register(
            "npm",
            NpmProvider.globalListArguments,
            .exit(1, standardOutput: try Fixture.text("npm/outdated-error-eacces.json"))
        )
        let context = try await harness.planningContext(provider)
        let candidate = try candidate("npm:corepack")

        let result = try await provider.verify(.stub(candidate.id), for: candidate, context: context)
        #expect(result.outcome == .failed)
        #expect(result.message.contains("denied access"))
    }
}
