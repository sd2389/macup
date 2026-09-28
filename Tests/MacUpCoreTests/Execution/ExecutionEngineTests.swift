import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A pretend Mac the execution engine can act on: a fake runner that refuses
/// anything unregistered, a real configuration file in a temporary directory
/// so the pre-execution policy re-read has something to re-read, and a
/// history file beside it. Nothing here touches the host.
final class ExecutionHarness: @unchecked Sendable {
    let root: TemporaryDirectory
    let runner = FakeCommandRunner()
    let fileSystem = FakeFileSystem()
    let paths: MacUpPaths
    /// Shapes of change the engine may run. Stated per test, because the
    /// shipping list belongs to the provider planning work.
    var modifyingRules: [ModifyingCommandRule] = [
        ModifyingCommandRule("brew", ["upgrade"], options: ["--formula"], maximumPositionals: 1),
        ModifyingCommandRule("npm", ["install"], options: ["-g"], maximumPositionals: 1),
    ]

    init() throws {
        root = try TemporaryDirectory(prefix: "macup-execution")
        paths = MacUpPaths(
            configDirectory: root.path + "/config",
            stateDirectory: root.path + "/state",
            launchAgentsDirectory: root.path + "/agents"
        )
    }

    var configurationStore: ConfigurationStore { ConfigurationStore(paths: paths) }
    var history: HistoryStore { HistoryStore(paths: paths) }

    /// Writes the configuration file and returns it as the engine's caller
    /// would have loaded it when the plan was built.
    @discardableResult
    func save(_ configuration: MacUpConfiguration) throws -> LoadedConfiguration {
        try configurationStore.save(configuration)
        return configurationStore.load()
    }

    var environment: CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: [
                "HOME": root.path,
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "GITHUB_TOKEN": "ghp_abcdefghijklmnopqrstuvwxyz0123",
            ],
            homeDirectory: root.path,
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64")
        )
    }

    func engine(
        providers: [any UpdateProvider] = [ScriptedUpdateProvider.confirming()],
        recordsHistory: Bool = true
    ) -> ExecutionEngine {
        ExecutionEngine(
            providers: providers,
            history: recordsHistory ? history : nil,
            configurationStore: configurationStore,
            modifyingRules: modifyingRules
        )
    }

    /// The one command every test's plan runs.
    static let brewUpgradeGit = PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"])

    func registerBrewUpgrade(_ response: FakeCommandRunner.Response = .success("Upgraded git")) {
        runner.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "git"], response)
    }
}

@Suite("ExecutionEngine", .timeLimit(.minutes(1)))
struct ExecutionEngineTests {
    private func gitPlan(
        action: PolicyDecision.Action = .allow,
        policy: UpdatePolicy = .auto,
        signals: Set<RiskSignal> = [],
        verification: [VerificationStep] = []
    ) -> PlannedUpdate {
        PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.50.1", signals: signals),
            steps: [ExecutionHarness.brewUpgradeGit],
            verification: verification,
            action: action,
            policy: policy
        )
    }

    private func configuration(
        _ items: [String: UpdatePolicy],
        confirmMajorUpdates: Bool = true
    ) -> MacUpConfiguration {
        MacUpConfiguration(
            global: .init(confirmMajorUpdates: confirmMajorUpdates),
            providers: Dictionary(uniqueKeysWithValues: ProviderID.known.map { ($0.rawValue, .init()) }),
            items: items.mapValues { MacUpConfiguration.ItemSettings(policy: $0) }
        )
    }

    // MARK: The policy re-check

    @Test("A policy change between planning and execution stops the item")
    func policyChangeSincePlanningWins() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        // Planned while the item was set to update automatically…
        let planned = try harness.save(configuration(["brew:git": .auto]))
        let plan = PlannedUpdateFactory.report([gitPlan()])
        // …then the user changed their mind.
        try harness.configurationStore.save(configuration(["brew:git": .ignore]))

        let report = await harness.engine().run(
            plan,
            configuration: planned,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.summary.skipped == 1)
        #expect(report.skipped.first?.reason.contains("ignored") == true)
        #expect(report.skipped.first?.decision?.source == .item)
        #expect(harness.runner.recordedRequests.isEmpty, "nothing may run once policy has changed")
    }

    @Test("An ignored item cannot be executed even when a plan exists for it")
    func ignoredItemsNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .ignore]))

        // The plan claims the item was allowed; the engine does not take its word.
        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli, confirmed: [try PackageID(parsing: "brew:git")]),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.decision?.action == .deny)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("An item the provider pins is not unpinned by a MacUp update")
    func providerPinnedItemsNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(signals: [.pinnedByProvider])]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.decision?.source == .providerPin)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("A disabled provider's items are not executed")
    func disabledProvidersNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        var configuration = self.configuration(["brew:git": .auto])
        configuration.providers[ProviderID.homebrew.rawValue] = .init(enabled: false)
        let loaded = try harness.save(configuration)

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.skipped.first?.decision?.source == .providerDisabled)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("A configuration MacUp could not read allows nothing")
    func unreadableConfigurationAllowsNothing() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        try Data("{ not json".utf8).write(to: URL(fileURLWithPath: harness.paths.configFile))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.skipped.first?.decision?.source == .configuration)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("A plan that needs confirmation runs only once it is confirmed")
    func confirmationIsRequired() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .ask]))
        let plan = PlannedUpdateFactory.report([gitPlan(action: .confirm, policy: .ask)])

        let unconfirmed = await harness.engine().run(
            plan,
            configuration: loaded,
            options: ExecutionOptions(origin: .gui),
            environment: harness.environment
        )
        #expect(unconfirmed.executed.isEmpty)
        #expect(unconfirmed.skipped.first?.reason.contains("not confirmed") == true)
        #expect(harness.runner.recordedRequests.isEmpty)

        let confirmed = await harness.engine().run(
            plan,
            configuration: loaded,
            options: ExecutionOptions(origin: .gui, confirmed: [try PackageID(parsing: "brew:git")]),
            environment: harness.environment
        )
        #expect(confirmed.summary.succeeded == 1)
        #expect(harness.runner.recordedInvocations.map(\.arguments) == [["upgrade", "--formula", "git"]])
    }

    @Test("An unattended run refuses an Ask First item even when it is listed as confirmed")
    func unattendedRunsRefuseAskItems() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .ask]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(action: .confirm, policy: .ask)], intent: .unattended),
            configuration: loaded,
            options: ExecutionOptions(
                origin: .scheduled,
                intent: .unattended,
                confirmed: [try PackageID(parsing: "brew:git")]
            ),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.decision?.source == .unattended)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("An unattended run refuses a change that may ask for a password")
    func unattendedRunsRefusePrivilegedChanges() async throws {
        let harness = try ExecutionHarness()
        let step = PlannedUpdateFactory.step(
            "/opt/homebrew/bin/brew",
            ["upgrade", "--formula", "git"],
            mayRequirePrivilege: true
        )
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        let planned = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.50.1"),
            steps: [step]
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([planned], intent: .unattended),
            configuration: loaded,
            options: ExecutionOptions(origin: .scheduled, intent: .unattended),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.reason.contains("administrator password") == true)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    // MARK: Dry run

    @Test("A dry run launches nothing and says what would have run")
    func dryRunLaunchesNothing() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli, dryRun: true),
            environment: harness.environment
        )

        #expect(harness.runner.recordedRequests.isEmpty, "a dry run must launch nothing at all")
        #expect(report.dryRun)
        #expect(report.summary.attempted == 0)
        #expect(report.skipped.first?.reason.contains("/opt/homebrew/bin/brew upgrade --formula git") == true)
        #expect(try harness.history.load().isEmpty, "a dry run attempts nothing, so it records nothing")
    }

    // MARK: Executing

    @Test("A successful update is verified and recorded")
    func successfulUpdateIsVerifiedAndRecorded() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let update = try #require(report.executed.first)
        #expect(update.succeeded)
        #expect(update.result.steps.map(\.command) == ["/opt/homebrew/bin/brew upgrade --formula git"])
        #expect(update.result.steps.first?.exitStatus == 0)
        #expect(update.verification?.outcome == .verified)
        #expect(update.verification?.observedVersion == "2.50.1")
        #expect(report.summary == .init(attempted: 1, succeeded: 1, failed: 0, skipped: 0, verified: 1, unverified: 0))
        // MacUp never claims a rollback it has not implemented.
        #expect(update.plan.rollback.availability == .unavailable)

        let entry = try #require(try harness.history.load().first)
        #expect(entry.item.rawValue == "brew:git")
        #expect(entry.origin == .cli)
        #expect(entry.outcome == .succeeded)
        #expect(entry.versionBefore == "2.50.0")
        #expect(entry.versionTarget == "2.50.1")
        #expect(entry.versionAfter == "2.50.1")
        #expect(entry.verification == .verified)
        #expect(entry.command == "/opt/homebrew/bin/brew upgrade --formula git")
    }

    @Test("Steps run with the allowlisted environment, not MacUp's own")
    func stepsRunWithAnAllowlistedEnvironment() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        _ = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let request = try #require(harness.runner.recordedRequests.first)
        #expect(request.environment["GITHUB_TOKEN"] == nil)
        #expect(request.environment["LANG"] == "en_US.UTF-8")
        #expect(request.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(request.effect == .modifying)
        #expect(request.timeout == .seconds(600))
    }

    @Test("Items run one at a time, in the plan's order")
    func itemsRunSequentially() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        harness.runner.register(path: "/opt/homebrew/bin/npm", ["install", "-g", "typescript"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto, "npm:typescript": .auto]))
        let npm = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.4.2", available: "5.4.3", kind: .globalPackage),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/npm", ["install", "-g", "typescript"])]
        )

        let report = await harness.engine(providers: [
            ScriptedUpdateProvider.confirming(),
            ScriptedUpdateProvider.confirming(.npm),
        ]).run(
            PlannedUpdateFactory.report([gitPlan(), npm]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.map(\.item.rawValue) == ["brew:git", "npm:typescript"])
        #expect(harness.runner.recordedInvocations.map(\.arguments) == [
            ["upgrade", "--formula", "git"],
            ["install", "-g", "typescript"],
        ])
        #expect(try harness.history.load().map(\.item.rawValue) == ["npm:typescript", "brew:git"])
    }

    @Test("The same item is never updated twice in one run")
    func duplicateItemsRunOnce() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(), gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.summary.attempted == 1)
        #expect(report.skipped.first?.reason.contains("twice") == true)
        #expect(harness.runner.recordedRequests.count == 1)
    }

    @Test("A plan with no commands changes nothing and says so")
    func emptyPlansAreRefused() async throws {
        let harness = try ExecutionHarness()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        let planned = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.50.1"),
            steps: []
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([planned]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(report.skipped.first?.reason.contains("no command") == true)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    // MARK: Failure

    @Test("A failed step stops the rest of the plan and is reported")
    func failedStepStopsTheRemainingSteps() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.exit(1, standardError: "Error: git could not be upgraded"))
        harness.runner.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "openssl"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        let planned = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:git", installed: "2.50.0", available: "2.50.1"),
            steps: [
                ExecutionHarness.brewUpgradeGit,
                PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "openssl"]),
            ]
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([planned]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let update = try #require(report.executed.first)
        #expect(update.result.outcome == .failed)
        #expect(update.result.steps.count == 1, "the second step must not run after the first failed")
        #expect(update.result.steps.first?.errorExcerpt == "Error: git could not be upgraded")
        #expect(update.result.error?.exitStatus == 1)
        #expect(update.verification == nil, "a failed update is not verified")
        #expect(report.hasFailures)
        #expect(harness.runner.recordedRequests.count == 1)

        let entry = try #require(try harness.history.load().first)
        #expect(entry.outcome == .failed)
        #expect(entry.errorSummary?.isEmpty == false)
        #expect(entry.versionAfter == nil)
    }

    @Test("A command the guard refuses fails the item and never reaches the machine")
    func guardRefusalFailsTheItem() async throws {
        let harness = try ExecutionHarness()
        harness.modifyingRules = []
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.result.outcome == .failed)
        #expect(report.executed.first?.result.error?.kind == .policyDenied)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    @Test("An earlier failure stops MacUp short of a high-risk change")
    func failureStopsBeforeHighRiskChanges() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.exit(1, standardError: "failed"))
        harness.runner.register(path: "/opt/homebrew/bin/brew", ["upgrade", "--formula", "openssl"], .success())
        // The high-risk item is set to update on its own, and the user has
        // turned off confirming major changes, so nothing but the earlier
        // failure can be what stops it.
        let loaded = try harness.save(configuration(
            ["brew:git": .auto, "brew:openssl": .auto],
            confirmMajorUpdates: false
        ))
        let risky = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("brew:openssl", installed: "3.5.0", available: "4.0.0", signals: [.mayAffectDependents]),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/brew", ["upgrade", "--formula", "openssl"])]
        )
        #expect(risky.plan.risk.level == .high, "the second item has to be high risk for this test to mean anything")

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(), risky]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.summary.failed == 1)
        #expect(report.skipped.map(\.item.rawValue) == ["brew:openssl"])
        #expect(report.skipped.first?.reason.contains("high risk") == true)
        #expect(harness.runner.recordedRequests.count == 1)
    }

    @Test("Stopping on failure leaves the remaining items alone")
    func stopOnFailureHaltsTheRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.exit(1, standardError: "failed"))
        harness.runner.register(path: "/opt/homebrew/bin/npm", ["install", "-g", "typescript"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto, "npm:typescript": .auto]))
        let npm = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.4.2", available: "5.4.3", kind: .globalPackage),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/npm", ["install", "-g", "typescript"])]
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(), npm]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli, stopOnFailure: true),
            environment: harness.environment
        )

        #expect(report.executed.map(\.item.rawValue) == ["brew:git"])
        #expect(report.skipped.first?.reason.contains("failed") == true)
        #expect(harness.runner.recordedRequests.count == 1)
    }

    @Test("A command that times out is reported as timed out, not as a failure to launch")
    func timeoutIsReported() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.throwing(MacUpError(.timeout, "The command did not finish in time and was stopped.")))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.result.outcome == .timedOut)
        #expect(report.summary.failed == 1)
        #expect(try harness.history.load().first?.outcome == .timedOut)
    }

    @Test("A cancelled run reports cancelled rather than pretending success")
    func cancellationIsReported() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.throwing(MacUpError(.cancelled, "The command was cancelled.")))
        harness.runner.register(path: "/opt/homebrew/bin/npm", ["install", "-g", "typescript"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto, "npm:typescript": .auto]))
        let npm = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.4.2", available: "5.4.3", kind: .globalPackage),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/npm", ["install", "-g", "typescript"])]
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan(), npm]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.cancelled)
        #expect(report.executed.first?.result.outcome == .cancelled)
        #expect(report.summary.succeeded == 0)
        #expect(report.summary.failed == 0)
        #expect(report.skipped.map(\.item.rawValue) == ["npm:typescript"], "nothing runs after a cancellation")
        #expect(harness.runner.recordedRequests.count == 1)
    }

    @Test("A cancelled task launches nothing")
    func cancelledTaskLaunchesNothing() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        let plan = PlannedUpdateFactory.report([gitPlan()])
        let engine = harness.engine()
        let environment = harness.environment

        // Wait for the cancellation before starting, so the test is about what
        // the engine does with a cancelled task rather than about timing.
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await engine.run(
                plan,
                configuration: loaded,
                options: ExecutionOptions(origin: .cli),
                environment: environment
            )
        }
        task.cancel()
        let report = await task.value

        #expect(report.cancelled)
        #expect(report.executed.isEmpty)
        #expect(harness.runner.recordedRequests.isEmpty)
    }

    // MARK: Verification

    @Test("An update that did not reach its target version says so")
    func targetNotReachedIsReported() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [ScriptedUpdateProvider.reporting(observed: "2.50.0")]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let update = try #require(report.executed.first)
        #expect(update.result.outcome == .succeeded)
        #expect(update.verification?.outcome == .targetNotReached)
        #expect(update.verification?.observedVersion == "2.50.0")
        #expect(report.summary.verified == 0)
        #expect(report.summary.unverified == 1)
        #expect(try harness.history.load().first?.verification == .targetNotReached)
    }

    @Test("A success MacUp could not confirm is not reported as confirmed")
    func unconfirmableSuccessIsNotConfirmed() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [
            ScriptedUpdateProvider.failing(MacUpError(.commandFailed, "Homebrew did not report a version.")),
        ]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.outcome == .failed)
        #expect(report.summary.verified == 0)
        #expect(report.summary.unverified == 1)
    }

    @Test("A provider that cannot verify yet is reported as not performed")
    func providerWithoutVerificationIsHonest() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [
            ScriptedUpdateProvider.failing(MacUpError(.unsupported, "Homebrew cannot verify updates yet.")),
        ]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.outcome == .notPerformed)
        #expect(report.summary.unverified == 1)
    }

    @Test("An item with no provider loaded is not confirmed either")
    func missingProviderIsNotConfirmed() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [ScriptedUpdateProvider.confirming(.npm)]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.outcome == .notPerformed)
        #expect(report.executed.first?.verification?.message.contains("Homebrew") == true)
    }

    @Test("Verification may read, and only what a check may read")
    func verificationRunsOnlyReadOnlyLookups() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        harness.runner.register(path: "/opt/homebrew/bin/brew", ["--version"], .success("Homebrew 7.0.6"))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        // A provider that looks the version up, and then tries to change
        // something. What happened to the second attempt is reported in the
        // message, so the assertions stay in the test.
        let provider = ScriptedUpdateProvider { _, candidate, context in
            let read = try await context.runner.run(CommandRequest(
                executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                arguments: ["--version"],
                effect: .readOnly
            ))
            var refusedTheChange = false
            do {
                _ = try await context.runner.run(CommandRequest(
                    executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                    arguments: ["upgrade", "--formula", "git"],
                    effect: .modifying
                ))
            } catch {
                refusedTheChange = (error as? MacUpError)?.kind == .policyDenied
            }
            return VerificationResult(
                item: candidate.id,
                outcome: .verified,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: candidate.availableVersion.raw,
                message: "\(read.standardOutputText.trimmingCharacters(in: .newlines)) refused=\(refusedTheChange)"
            )
        }

        let report = await harness.engine(providers: [provider]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.outcome == .verified)
        #expect(report.executed.first?.verification?.message == "Homebrew 7.0.6 refused=true")
        // The upgrade ran once, for the plan's step, and not again for verification.
        #expect(harness.runner.recordedInvocations.map(\.arguments) == [["upgrade", "--formula", "git"], ["--version"]])
    }

    // MARK: History

    @Test("Every skip is recorded with the reason for it")
    func skipsAreRecordedWithTheirReason() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .ignore]))

        _ = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .scheduled, intent: .unattended),
            environment: harness.environment
        )

        let entry = try #require(try harness.history.load().first)
        #expect(entry.outcome == .skipped)
        #expect(entry.origin == .scheduled)
        #expect(entry.skipReason?.contains("ignored") == true)
        #expect(entry.command == nil, "nothing ran, so there is no command to record")
        #expect(entry.versionTarget == "2.50.1")
    }

    @Test("What the planner already refused travels through to the report")
    func plannerSkipsAreCarriedThrough() async throws {
        let harness = try ExecutionHarness()
        let loaded = try harness.save(configuration([:]))
        let refused = SkippedUpdate(
            item: try PackageID(parsing: "macos:macOS 27.2"),
            displayName: "macOS 27.2",
            reason: "A macOS update always needs your confirmation."
        )

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([], skipped: [refused]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.skipped == [refused])
        #expect(report.summary.skipped == 1)
    }

    @Test("An unwritable history does not stop an update MacUp was asked to make")
    func unwritableHistoryDoesNotBlockTheUpdate() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        // A file where the state directory should be: history cannot be written.
        try Data().write(to: URL(fileURLWithPath: harness.paths.stateDirectory))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.summary.succeeded == 1)
    }
}
