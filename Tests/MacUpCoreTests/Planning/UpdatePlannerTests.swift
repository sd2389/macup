import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Update planner", .timeLimit(.minutes(1)))
struct UpdatePlannerTests {
    let planner = UpdatePlanner.standard()
    let defaults = LoadedConfiguration(
        configuration: .defaults,
        source: .defaults,
        path: "/Users/example/.config/macup/config.json"
    )

    private func configuration(_ mutate: (inout MacUpConfiguration) -> Void) -> LoadedConfiguration {
        var configuration = MacUpConfiguration.defaults
        mutate(&configuration)
        return LoadedConfiguration(
            configuration: configuration,
            source: .file,
            path: "/Users/example/.config/macup/config.json"
        )
    }

    /// The whole flow a `macup plan` runs: a read-only check, then planning
    /// from its result.
    private func plan(
        _ request: PlanRequest = PlanRequest(),
        configuration: LoadedConfiguration? = nil,
        mac: FakeMac? = nil
    ) async throws -> (report: PlanReport, mac: FakeMac) {
        let mac = try mac ?? FakeMac()
        let loaded = configuration ?? defaults
        let check = await CheckEngine.standard().run(configuration: loaded, environment: mac.checkEnvironment)
        let report = await planner.plan(check, request: request, configuration: loaded, environment: mac.checkEnvironment)
        return (report, mac)
    }

    private func skip(_ report: PlanReport, _ id: String) throws -> SkippedUpdate {
        try #require(report.skipped.first { $0.item.rawValue == id }, "\(id) is not among the skipped items")
    }

    @Test("Everything Ask First becomes a plan waiting on the user, in a stable order")
    func askFirstPlansNeedConfirmation() async throws {
        let (report, _) = try await plan()

        #expect(report.schemaVersion == 1)
        #expect(report.kind == "plan")
        #expect(report.intent == .interactive)
        #expect(!report.cancelled)
        #expect(report.planned.map(\.item.rawValue) == [
            "brew:git", "brew:mysql",
            "npm:@anthropic-ai/claude-code", "npm:corepack", "npm:npm",
            "mise:node", "mise:python",
        ])
        #expect(report.planned.allSatisfy { $0.needsConfirmation })
        #expect(report.allowed.isEmpty)
        #expect(report.summary.needsConfirmation == 7)
        #expect(report.summary.allowed == 0)
        #expect(report.unmatchedSelection.isEmpty)
        #expect(report.providers.map(\.provider) == [.homebrew, .npm, .mise, .macos])
        #expect(report.configuration?.automaticModificationsAllowed == true)
    }

    @Test("Planning twice from the same check produces the same plan")
    func planningIsDeterministic() async throws {
        let mac = try FakeMac()
        let (first, _) = try await plan(mac: mac)
        let (second, _) = try await plan(mac: mac)
        #expect(first.planned.map(\.plan.steps) == second.planned.map(\.plan.steps))
        #expect(first.planned.map(\.plan.createdAt) == second.planned.map(\.plan.createdAt))
    }

    @Test("Planning runs no commands of its own: a plan is a description")
    func planningRunsNothing() async throws {
        let mac = try FakeMac()
        let check = await CheckEngine.standard().run(configuration: defaults, environment: mac.checkEnvironment)
        let afterCheck = mac.runner.recordedRequests.count

        let report = await planner.plan(check, request: PlanRequest(), configuration: defaults, environment: mac.checkEnvironment)

        #expect(!report.planned.isEmpty)
        #expect(mac.runner.recordedRequests.count == afterCheck)
        #expect(mac.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("Every planned step names an exact executable and is allowed by a rule")
    func plannedStepsAreAllowed() async throws {
        let (report, _) = try await plan()
        for planned in report.planned {
            #expect(!planned.plan.steps.isEmpty)
            for step in planned.plan.steps {
                #expect(step.invocation.executable.hasPrefix("/"))
                #expect(step.effect == .modifying)
            }
            expectAllowedByRules(planned.plan)
        }
    }

    @Test("An ignored item never reaches the plan")
    func ignoredItemsAreSkipped() async throws {
        let (report, _) = try await plan(configuration: configuration {
            $0.items["brew:git"] = .init(policy: .ignore)
        })

        #expect(!report.planned.contains { $0.item.rawValue == "brew:git" })
        let skipped = try skip(report, "brew:git")
        #expect(skipped.decision?.action == .deny)
        #expect(skipped.decision?.source == .item)
        #expect(skipped.reason.contains("is ignored"))
        #expect(skipped.currentVersion == "2.43.0")
        #expect(skipped.proposedVersion == "2.44.0")
        #expect(report.summary.deniedByPolicy == 1)
    }

    @Test("An item held at its current version never reaches the plan")
    func pinnedByPolicyIsSkipped() async throws {
        let (report, _) = try await plan(configuration: configuration {
            $0.items["mise:node"] = .init(policy: .pin)
        })
        #expect(!report.planned.contains { $0.item.rawValue == "mise:node" })
        #expect(try skip(report, "mise:node").decision?.policy == .pin)
    }

    @Test("A provider-pinned item never reaches the plan, even set to update automatically")
    func providerPinnedItemIsSkipped() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], .success(try Fixture.text("homebrew/outdated-pinned.json")))
        let loaded = configuration {
            $0.global.defaultPolicy = .auto
            $0.items["brew:postgresql@16"] = .init(policy: .auto)
        }
        let (report, _) = try await plan(configuration: loaded, mac: mac)

        #expect(!report.planned.contains { $0.provider == .homebrew })
        let skipped = try skip(report, "brew:postgresql@16")
        #expect(skipped.decision?.source == .providerPin)
        #expect(skipped.reason.contains("does not unpin"))
    }

    @Test("A disabled provider's updates are never planned")
    func disabledProviderIsSkipped() async throws {
        let (report, _) = try await plan(configuration: configuration {
            $0.providers["npm"] = .init(enabled: false)
        })
        #expect(!report.planned.contains { $0.provider == .npm })
        #expect(!report.skipped.contains { $0.provider == .npm }, "a disabled provider is never checked")
    }

    @Test("A configuration MacUp could not read plans nothing at all")
    func untrustedConfigurationPlansNothing() async throws {
        let loaded = LoadedConfiguration(
            configuration: .defaults,
            source: .file,
            path: "/Users/example/.config/macup/config.json",
            issues: [ConfigurationIssue(.error, "providers", "MacUp could not read this file.")]
        )
        let (report, _) = try await plan(configuration: loaded)

        #expect(report.planned.isEmpty)
        #expect(report.skipped.count == 8)
        #expect(report.skipped.allSatisfy { $0.decision?.source == PolicyDecision.Source.configuration })
        #expect(report.summary.deniedByPolicy == 8)
    }

    @Test("Auto Update items are allowed to run without asking; risky ones still ask")
    func autoItemsAreAllowed() async throws {
        let (report, _) = try await plan(configuration: configuration {
            $0.items["brew:git"] = .init(policy: .auto)
            $0.items["brew:mysql"] = .init(policy: .auto)
        })

        let git = try #require(report.planned.first { $0.item.rawValue == "brew:git" })
        #expect(git.decision.action == .allow)
        #expect(!git.needsConfirmation)

        let mysql = try #require(report.planned.first { $0.item.rawValue == "brew:mysql" })
        #expect(mysql.decision.action == .confirm, "a major version change still asks")
        #expect(mysql.decision.escalated)
        #expect(report.summary.allowed == 1)
    }

    @Test("A scheduled run plans only what is set to update automatically")
    func unattendedRunPlansOnlyAutoItems() async throws {
        let (report, _) = try await plan(
            PlanRequest(intent: .unattended),
            configuration: configuration { $0.items["brew:git"] = .init(policy: .auto) }
        )

        #expect(report.intent == .unattended)
        #expect(report.planned.map(\.item.rawValue) == ["brew:git"])
        #expect(report.planned.allSatisfy { $0.decision.action == .allow })
        #expect(report.skipped.allSatisfy { $0.decision?.action == .deny })
        #expect(try skip(report, "npm:corepack").decision?.source == .unattended)
    }

    @Test("A selection narrows the plan to the items named")
    func selectionNarrowsThePlan() async throws {
        let selection: Set<PackageID> = [try PackageID(parsing: "brew:git"), try PackageID(parsing: "mise:python")]
        let (report, _) = try await plan(PlanRequest(selection: selection))

        #expect(report.planned.map(\.item.rawValue) == ["brew:git", "mise:python"])
        #expect(report.skipped.isEmpty, "items the user did not name were never in this run")
        #expect(report.unmatchedSelection.isEmpty)
    }

    @Test("A selected item that policy refuses is still reported as skipped")
    func selectedButDeniedIsSkipped() async throws {
        let selection: Set<PackageID> = [try PackageID(parsing: "brew:git")]
        let (report, _) = try await plan(
            PlanRequest(selection: selection),
            configuration: configuration { $0.items["brew:git"] = .init(policy: .ignore) }
        )

        #expect(report.planned.isEmpty)
        #expect(report.skipped.map(\.item.rawValue) == ["brew:git"])
        #expect(report.unmatchedSelection.isEmpty, "the item was offered; policy refused it")
    }

    @Test("An item nobody offered an update for is reported as unmatched")
    func unmatchedSelectionIsReported() async throws {
        let selection: Set<PackageID> = [
            try PackageID(parsing: "brew:git"),
            try PackageID(parsing: "brew:nosuchformula"),
            try PackageID(parsing: "npm:not-installed"),
        ]
        let (report, _) = try await plan(PlanRequest(selection: selection))

        #expect(report.planned.map(\.item.rawValue) == ["brew:git"])
        #expect(report.unmatchedSelection.map(\.rawValue) == ["brew:nosuchformula", "npm:not-installed"])
    }

    @Test("macOS updates are reported but never planned")
    func macOSUpdatesAreNotPlanned() async throws {
        let (report, _) = try await plan(configuration: configuration {
            $0.items["macos:macOS Sequoia 15.5-24F74"] = .init(policy: .auto)
        })

        #expect(!report.planned.contains { $0.provider == .macos })
        let skipped = try #require(report.skipped.first { $0.provider == .macos })
        #expect(skipped.error?.kind == .unsupported)
        #expect(skipped.reason.contains("does not apply them"))
        #expect(report.summary.unplannable >= 1)
    }

    @Test("A provider that cannot plan an item reports the reason, not a guess")
    func providerRefusalBecomesASkip() async throws {
        let mac = try FakeMac()
        mac.runner.register("mise", ["outdated", "--json"], .success(try Fixture.text("mise/outdated-exact-pin.json")))
        let (report, _) = try await plan(mac: mac)

        #expect(!report.planned.contains { $0.provider == .mise })
        let skipped = try skip(report, "mise:node")
        #expect(skipped.error?.kind == .unsupported)
        #expect(skipped.reason.contains("pinned to exactly 24.18.0"))
        #expect(skipped.decision?.action == .confirm, "policy allowed it; the provider could not plan it")
    }

    @Test("A provider without the planning capability cannot plan, even if it would")
    func capabilityIsRequired() async throws {
        let mac = try FakeMac()
        let planner = UpdatePlanner(providers: [SilentlyWillingProvider(), NpmProvider(), MiseProvider(), MacOSProvider()])
        let check = await CheckEngine(providers: planner.providers).run(configuration: defaults, environment: mac.checkEnvironment)
        let report = await planner.plan(check, request: PlanRequest(), configuration: defaults, environment: mac.checkEnvironment)

        #expect(!report.planned.contains { $0.provider == .homebrew })
        let skipped = try skip(report, "brew:git")
        #expect(skipped.error?.kind == .unsupported)
        #expect(skipped.reason.contains("does not apply them"))
    }

    @Test("A provider the check could not use is not planned for")
    func unavailableProviderIsSkipped() async throws {
        let mac = try FakeMac()
        // A candidate whose provider failed after detection cannot be
        // planned, because MacUp does not know which executable to name.
        let check = await CheckEngine.standard().run(configuration: defaults, environment: mac.checkEnvironment)
        var damaged = check
        damaged.providers = check.providers.map { report in
            var report = report
            if report.provider == .homebrew { report.executable = nil }
            return report
        }
        let report = await planner.plan(damaged, request: PlanRequest(), configuration: defaults, environment: mac.checkEnvironment)

        #expect(!report.planned.contains { $0.provider == .homebrew })
        #expect(try skip(report, "brew:git").error?.kind == .providerUnavailable)
    }

    @Test("Nothing outdated plans nothing and skips nothing")
    func nothingToDo() async throws {
        let mac = try FakeMac()
        mac.runner.register("brew", ["outdated", "--json=v2"], .success(try Fixture.text("homebrew/outdated-none.json")))
        mac.runner.register("npm", ["outdated", "-g", "--json"], .success("{}"))
        mac.runner.register("mise", ["outdated", "--json"], .success("{}"))
        mac.runner.register("softwareupdate", ["--list", "--no-scan"], .exit(0, standardError: "No new software available.\n"))
        let (report, _) = try await plan(mac: mac)

        #expect(report.isEmpty)
        #expect(report.skipped.isEmpty)
        #expect(report.summary == PlanReport.Summary(allowed: 0, needsConfirmation: 0, deniedByPolicy: 0, unplannable: 0))
    }

    @Test("Planning from scratch checks first, and still changes nothing")
    func planFromScratchChecksFirst() async throws {
        let mac = try FakeMac()
        let report = await planner.plan(PlanRequest(), configuration: defaults, environment: mac.checkEnvironment)

        #expect(report.planned.count == 7)
        #expect(mac.runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
    }

    @Test("A plan report survives a round trip through JSON")
    func planReportRoundTrips() async throws {
        let (report, _) = try await plan()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(PlanReport.self, from: try encoder.encode(report))
        #expect(decoded.planned.map(\.item) == report.planned.map(\.item))
        #expect(decoded.planned.map(\.plan.steps) == report.planned.map(\.plan.steps))
        #expect(decoded.summary == report.summary)
    }
}

/// A Homebrew provider that would happily build a plan but never said it
/// could, standing in for a provider whose planning is not reviewed yet.
private struct SilentlyWillingProvider: UpdateProvider {
    private let real = HomebrewProvider()

    var id: ProviderID { real.id }
    var capabilities: Set<ProviderCapability> { [.detect, .inventory, .outdated] }

    func detect(context: ProviderContext) async -> ProviderStatus {
        await real.detect(context: context)
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        try await real.inventory(context: context)
    }

    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        try await real.outdated(context: context)
    }

    func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        try await real.makePlan(for: candidate, context: context)
    }
}
