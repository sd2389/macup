import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("ExecutionGuard")
struct ExecutionGuardTests {
    /// `ModifyingCommandRules.all` is populated by the provider planning work,
    /// so the rules a test needs are stated here rather than assumed.
    let rules = [
        ModifyingCommandRule("brew", ["upgrade"], options: ["--formula"], maximumPositionals: 1),
    ]

    let candidate = PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.51.0")

    var plan: ExecutionPlan {
        PlannedUpdateFactory.plan(
            for: candidate,
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"])],
            verification: [
                VerificationStep(
                    summary: "Read the installed version of git",
                    invocation: CommandInvocation(executable: "/opt/homebrew/bin/brew", arguments: ["info", "--json=v2", "git"]),
                    expectedVersion: "2.51.0"
                ),
            ]
        )
    }

    private func request(
        _ arguments: [String],
        effect: CommandEffect = .modifying,
        executable: String = "/opt/homebrew/bin/brew"
    ) -> CommandRequest {
        CommandRequest(executable: URL(fileURLWithPath: executable), arguments: arguments, effect: effect)
    }

    @Test("The plan's own steps run")
    func runsThePlansSteps() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"], .success("done"))
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)
        let result = try await guarded.run(request(["upgrade", "--formula", "git"]))
        #expect(result.standardOutputText == "done")
        #expect(fake.recordedRequests.count == 1)
    }

    @Test(
        "A change that was not in the plan is refused",
        arguments: [
            ["upgrade", "--formula", "openssl"],
            ["upgrade", "git", "openssl"],
            ["upgrade"],
            ["upgrade", "--formula", "--greedy", "git"],
        ]
    )
    func refusesCommandsOutsideThePlan(arguments: [String]) async throws {
        let fake = FakeCommandRunner()
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)
        let error = await #expect(throws: MacUpError.self) { try await guarded.run(request(arguments)) }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty, "a refused command must never reach the operating system")
    }

    @Test("A change with no matching rule is refused even when the plan asks for it")
    func refusesChangesWithNoRule() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"], .success())
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: [])
        let error = await #expect(throws: MacUpError.self) { try await guarded.run(request(["upgrade", "--formula", "git"])) }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test("A plan's verification command runs, and nothing like it does")
    func runsThePlansVerification() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["info", "--json=v2", "git"], .success("{}"))
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)
        #expect(try await guarded.run(request(["info", "--json=v2", "git"], effect: .readOnly)).succeeded)

        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["info", "--json=v2", "openssl"], effect: .readOnly))
        }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.count == 1)
    }

    @Test("Read-only lookups outside the plan run only when they are allowlisted")
    func allowsAllowlistedReadOnlyLookups() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["--version"], .success("Homebrew 7.0.6"))
        let strict = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)
        let error = await #expect(throws: MacUpError.self) {
            try await strict.run(request(["--version"], effect: .readOnly))
        }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)

        let verifying = ExecutionGuard(
            base: fake,
            plan: plan,
            modifyingRules: rules,
            readOnlyRules: CommandAllowlist.readOnlyCheck
        )
        #expect(try await verifying.run(request(["--version"], effect: .readOnly)).succeeded)
    }

    @Test("The allowlist never widens what a change may do")
    func readOnlyRulesDoNotWidenChanges() async throws {
        let fake = FakeCommandRunner()
        let guarded = ExecutionGuard(
            base: fake,
            plan: plan,
            modifyingRules: [],
            readOnlyRules: CommandAllowlist.readOnlyCheck
        )
        let error = await #expect(throws: MacUpError.self) { try await guarded.run(request(["upgrade", "--formula", "git"])) }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test("A step's declared effect has to match the request")
    func effectMustMatchThePlan() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"], .success())
        fake.register(path: "/opt/homebrew/bin/brew", ["info", "--json=v2", "git"], .success())
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)

        // The plan presented the upgrade as a change, so it cannot run labelled read-only.
        let mislabelled = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["upgrade", "--formula", "git"], effect: .readOnly))
        }
        #expect(mislabelled?.kind == .policyDenied)

        // Nor can a verification command run as a change.
        let escalated = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["info", "--json=v2", "git"], effect: .modifying))
        }
        #expect(escalated?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }

    @Test("A metadata refresh runs only when the plan said it would")
    func metadataRefreshMustBeInThePlan() async throws {
        let fake = FakeCommandRunner()
        fake.register(path: "/opt/homebrew/bin/brew", ["update"], .success())
        let refresh = request(["update"], effect: .metadataRefresh)

        let denied = await #expect(throws: MacUpError.self) {
            try await ExecutionGuard(base: fake, plan: plan, modifyingRules: rules).run(refresh)
        }
        #expect(denied?.kind == .policyDenied)

        let refreshing = PlannedUpdateFactory.plan(
            for: candidate,
            steps: [
                PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["update"], effect: .metadataRefresh),
                PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"]),
            ]
        )
        let allowed = ExecutionGuard(base: fake, plan: refreshing, modifyingRules: rules)
        #expect(try await allowed.run(refresh).succeeded)
    }

    @Test("The refusal names the command, redacted")
    func refusalNamesTheRedactedCommand() async throws {
        let guarded = ExecutionGuard(base: FakeCommandRunner(), plan: plan, modifyingRules: rules)
        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(CommandRequest(
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                arguments: ["upgrade", "--formula", "git", "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123"],
                effect: .modifying
            ))
        }
        let command = try #require(error?.command)
        #expect(command.contains("/opt/homebrew/bin/brew"))
        #expect(!command.contains("ghp_abcdefghijklmnopqrstuvwxyz0123"))
        #expect(command.contains(Redactor.placeholder))
    }

    @Test("A different executable with the plan's arguments is refused")
    func executablePathMustMatch() async throws {
        let fake = FakeCommandRunner()
        fake.register("brew", ["upgrade", "--formula", "git"], .success())
        let guarded = ExecutionGuard(base: fake, plan: plan, modifyingRules: rules)
        let error = await #expect(throws: MacUpError.self) {
            try await guarded.run(request(["upgrade", "--formula", "git"], executable: "/usr/local/bin/brew"))
        }
        #expect(error?.kind == .policyDenied)
        #expect(fake.recordedRequests.isEmpty)
    }
}
