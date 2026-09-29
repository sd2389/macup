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
        ModifyingCommandRule("brew", ["upgrade"], options: ["--formula"], positionalCount: 1),
        ModifyingCommandRule("npm", ["install"], options: ["-g"], positionalCount: 1),
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

/// A provider that can describe a change but not carry one out.
private struct DescribeOnlyProvider: UpdateProvider {
    let id = ProviderID.homebrew
    let capabilities: Set<ProviderCapability> = [.detect, .planUpdates]

    func detect(context: ProviderContext) async -> ProviderStatus {
        ProviderStatus(provider: id, availability: .available, installation: ScriptedUpdateProvider.stubInstallation)
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> { ProviderListing() }
    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> { ProviderListing() }
}

/// A provider that states an environment of its own.
///
/// Homebrew is the real case: `HOMEBREW_NO_INSTALL_CLEANUP` and
/// `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK` have no command-line flag, so two
/// of the things a Homebrew plan promises exist only in the environment. If
/// the engine assembled its own, a reviewed plan would run as something else.
private struct EnvironmentStatingProvider: UpdateProvider {
    let id = ProviderID.homebrew
    let capabilities: Set<ProviderCapability> = [.detect, .planUpdates, .updateSelectedItems, .verifyUpdates]

    func detect(context: ProviderContext) async -> ProviderStatus {
        ProviderStatus(
            provider: id,
            availability: .available,
            installation: ScriptedUpdateProvider.stubInstallation
        )
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> { ProviderListing() }
    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> { ProviderListing() }

    func executionEnvironment(context: ProviderContext) -> [String: String] {
        ["PATH": "/opt/homebrew/bin", "HOMEBREW_NO_INSTALL_CLEANUP": "1"]
    }

    func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        VerificationResult(
            item: candidate.id,
            outcome: .verified,
            expectedVersion: candidate.availableVersion.raw,
            observedVersion: candidate.availableVersion.raw,
            message: "Confirmed."
        )
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
        #expect(report.summary.verified == 0, "a failed update is never counted as confirmed")
        #expect(report.hasFailures)
        #expect(harness.runner.recordedRequests.count == 1)

        let entry = try #require(try harness.history.load().first)
        #expect(entry.outcome == .failed)
        #expect(entry.errorSummary?.isEmpty == false)
    }

    // MARK: What an unsuccessful attempt left

    /// A provider whose read-back finds the item still at the version it
    /// started from and no longer linked, as an interrupted `brew upgrade`
    /// leaves it. It answers only while its task has not been cancelled, as
    /// the real runner's read-only commands do, so a test that gets an answer
    /// has proved the read-back was not cancelled with the run.
    private static let stillOld = ScriptedUpdateProvider(id: .homebrew) { _, candidate, _ in
        guard !Task.isCancelled else {
            return VerificationResult(
                item: candidate.id,
                outcome: .failed,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: nil,
                message: "Cancelled before it could read anything."
            )
        }
        return VerificationResult(
            item: candidate.id,
            outcome: .targetNotReached,
            expectedVersion: candidate.availableVersion.raw,
            observedVersion: candidate.installedVersion?.raw,
            observedState: "No version of git is linked, so its commands are not on your PATH.",
            message: "git is still \(candidate.installedVersion?.raw ?? "unknown")."
        )
    }

    @Test("Which results MacUp reads the item back after")
    func readsBackAfterAnyCommandThatRan() {
        let id = try! PackageID(parsing: "brew:git")
        let step = ExecutionResult.StepResult(command: "/opt/homebrew/bin/brew upgrade --formula git", exitStatus: 1, durationSeconds: 1)
        func result(_ outcome: ExecutionResult.Outcome, ran: Bool) -> ExecutionResult {
            ExecutionResult(planID: UUID(), item: id, outcome: outcome, startedAt: .distantPast, finishedAt: .distantPast, steps: ran ? [step] : [])
        }
        #expect(ExecutionEngine.readsBack(after: result(.succeeded, ran: true)))
        for outcome in [ExecutionResult.Outcome.failed, .timedOut, .cancelled] {
            #expect(ExecutionEngine.readsBack(after: result(outcome, ran: true)), "\(outcome) after a command ran")
            #expect(!ExecutionEngine.readsBack(after: result(outcome, ran: false)), "\(outcome) before any command ran")
        }
        #expect(!ExecutionEngine.readsBack(after: result(.skipped, ran: false)))
    }

    @Test("After a failed command MacUp reads the item back and records what it left")
    func failureIsReadBack() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.exit(1, standardError: "Error: git could not be linked"))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [Self.stillOld]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let update = try #require(report.executed.first)
        #expect(update.result.outcome == .failed)
        #expect(update.verification?.outcome == .targetNotReached)
        #expect(update.verification?.observedVersion == "2.50.0")
        #expect(report.summary == .init(attempted: 1, succeeded: 0, failed: 1, skipped: 0, verified: 0, unverified: 0))

        let entry = try #require(try harness.history.load().first)
        #expect(entry.outcome == .failed)
        #expect(entry.verification == .targetNotReached)
        #expect(entry.versionAfter == "2.50.0")
        #expect(entry.stateAfter == "No version of git is linked, so its commands are not on your PATH.")
        #expect(entry.headline.text == "Failed — git was not updated")
        // The upgrade ran once and nothing else changing was attempted.
        #expect(harness.runner.recordedRequests.filter { $0.effect == .modifying }.count == 1)
    }

    @Test("A failure whose read-back finds the new version is still a failure, never a confirmation")
    func failureAtTheTargetIsNotConfirmed() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.exit(1, standardError: "Error: a post-install step failed"))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine().run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.outcome == .verified)
        #expect(report.summary.verified == 0)
        #expect(report.summary.unverified == 0)
        #expect(report.summary.failed == 1)
        let entry = try #require(try harness.history.load().first)
        #expect(entry.outcome == .failed)
        #expect(entry.versionAfter == "2.50.1")
        #expect(entry.headline.kind == .failed)
        #expect(entry.headline.text == "Failed, but git is at the new version")
    }

    @Test("Stopping in the middle of a command still reads the item back, and nothing after it starts")
    func stopMidCommandIsReadBack() async throws {
        let harness = try ExecutionHarness()
        // The command is cut short the way an older MacUp cut one short when
        // Stop was pressed: it ends cancelled, part-way through.
        harness.registerBrewUpgrade(.throwing(MacUpError(.cancelled, "The command was cancelled.")))
        harness.runner.register(path: "/opt/homebrew/bin/npm", ["install", "-g", "typescript"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto, "npm:typescript": .auto]))
        let npm = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.4.2", available: "5.4.3", kind: .globalPackage),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/npm", ["install", "-g", "typescript"])]
        )
        var environment = harness.environment
        environment.runner = StopPressingRunner(base: harness.runner)

        let report = await harness.engine(providers: [Self.stillOld, ScriptedUpdateProvider.confirming(.npm)]).run(
            PlannedUpdateFactory.report([gitPlan(), npm]),
            configuration: loaded,
            options: ExecutionOptions(origin: .gui),
            environment: environment
        )

        let git = try #require(report.executed.first)
        #expect(git.result.outcome == .cancelled)
        #expect(git.verification?.outcome == .targetNotReached, "the read-back ran to the end despite the stop")
        #expect(report.cancelled)
        #expect(report.skipped.map(\.item.rawValue) == ["npm:typescript"])
        #expect(!harness.runner.recordedRequests.contains { $0.executable.path.hasSuffix("/npm") })

        let entry = try #require(try harness.history.load().first { $0.item.rawValue == "brew:git" })
        #expect(entry.outcome == .cancelled)
        #expect(entry.versionAfter == "2.50.0")
        #expect(entry.stateAfter == "No version of git is linked, so its commands are not on your PATH.")
        #expect(entry.errorSummary == "The command was cancelled.")
        #expect(entry.headline.text == "Stopped — git was not updated")
    }

    @Test("A command that ran past its time limit is read back too")
    func timeoutIsReadBack() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade(.throwing(MacUpError(
            .timeout,
            "The command did not finish within 10 minutes, so MacUp interrupted it the way Ctrl+C would and waited for it to exit."
        )))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [Self.stillOld]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.result.outcome == .timedOut)
        let entry = try #require(try harness.history.load().first)
        #expect(entry.versionAfter == "2.50.0")
        #expect(entry.verification == .targetNotReached)
        #expect(entry.headline.text == "Timed out — git was not updated")
    }

    @Test("An attempt stopped before its first command reads nothing back, because nothing ran")
    func nothingRanNothingReadBack() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))
        let provider = StopDuringDetectionProvider()

        let report = await harness.engine(providers: [provider]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .gui),
            environment: harness.environment
        )

        let git = try #require(report.executed.first)
        #expect(git.result.outcome == .cancelled)
        #expect(git.result.steps.isEmpty)
        #expect(git.verification == nil)
        #expect(!provider.wasAskedToVerify)
        #expect(harness.runner.recordedRequests.isEmpty)

        let entry = try #require(try harness.history.load().first)
        #expect(entry.command == nil)
        #expect(entry.versionAfter == nil)
        #expect(entry.verification == nil)
        #expect(entry.headline.text == "Stopped before anything ran")
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

    @Test("Stopping while an item's command runs lets that item finish and be confirmed, and starts nothing else")
    func stopDuringACommandFinishesThatItem() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        harness.runner.register(path: "/opt/homebrew/bin/npm", ["install", "-g", "typescript"], .success())
        let loaded = try harness.save(configuration(["brew:git": .auto, "npm:typescript": .auto]))
        let npm = PlannedUpdateFactory.planned(
            PlannedUpdateFactory.candidate("npm:typescript", installed: "5.4.2", available: "5.4.3", kind: .globalPackage),
            steps: [PlannedUpdateFactory.step("/opt/homebrew/bin/npm", ["install", "-g", "typescript"])]
        )
        // Verification that, like the real runner's read-only commands, gives
        // up the moment its task is cancelled.
        let provider = ScriptedUpdateProvider(id: .homebrew) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: Task.isCancelled ? .failed : .verified,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: Task.isCancelled ? nil : candidate.availableVersion.raw,
                message: Task.isCancelled ? "Cancelled." : "Confirmed."
            )
        }
        var environment = harness.environment
        // The user presses Stop while brew is running; the command, as the
        // real runner now guarantees, runs to the end regardless.
        environment.runner = StopPressingRunner(base: harness.runner)

        let report = await harness.engine(providers: [provider, ScriptedUpdateProvider.confirming(.npm)]).run(
            PlannedUpdateFactory.report([gitPlan(), npm]),
            configuration: loaded,
            options: ExecutionOptions(origin: .gui),
            environment: environment
        )

        let git = try #require(report.executed.first)
        #expect(git.result.outcome == .succeeded, "the running item is not reported as cancelled")
        #expect(git.verification?.outcome == .verified, "and it is still confirmed after Stop")
        #expect(report.cancelled)
        #expect(report.skipped.map(\.item.rawValue) == ["npm:typescript"])
        #expect(!harness.runner.recordedRequests.contains { $0.executable.path.hasSuffix("/npm") })
        let entry = try #require(try harness.history.load().first { $0.item.rawValue == "brew:git" })
        #expect(entry.outcome == .succeeded)
        #expect(entry.verification == .verified)
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

    @Test("A step runs with the environment its own provider states")
    func stepsRunWithTheProvidersEnvironment() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        _ = await harness.engine(providers: [EnvironmentStatingProvider()]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        let request = try #require(harness.runner.recordedRequests.first)
        #expect(request.environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        #expect(request.environment["GITHUB_TOKEN"] == nil)
    }

    @Test("An item whose provider MacUp does not have loaded is never run")
    func missingProviderIsNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [ScriptedUpdateProvider.confirming(.npm)]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        // Without the provider there is nothing to say which environment the
        // command needs, and nothing to read the new version back, so MacUp
        // does not run it at all rather than run it half-understood.
        #expect(report.executed.isEmpty)
        #expect(harness.runner.recordedRequests.isEmpty)
        #expect(report.skipped.first?.reason.contains("Homebrew") == true)
    }

    @Test("A provider that cannot apply updates has none of its plans run")
    func providerWithoutTheCapabilityIsNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [DescribeOnlyProvider()]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(harness.runner.recordedRequests.isEmpty)
        #expect(report.skipped.first?.reason.contains("cannot apply it") == true)
    }

    @Test("A provider MacUp can no longer find has none of its plans run")
    func undetectableProviderIsNeverRun() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        let report = await harness.engine(providers: [ScriptedUpdateProvider.undetectable()]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.isEmpty)
        #expect(harness.runner.recordedRequests.isEmpty)
        #expect(report.skipped.first?.reason.contains("could not find") == true)
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

    @Test("Verification may not refresh provider metadata either")
    func verificationRefusesAMetadataRefresh() async throws {
        let harness = try ExecutionHarness()
        harness.registerBrewUpgrade()
        harness.runner.register(path: "/opt/homebrew/bin/brew", ["update"], .success("Already up-to-date"))
        let loaded = try harness.save(configuration(["brew:git": .auto]))

        // `brew update` is on the allowlist a check uses, for
        // `macup check --refresh`. An update the user reviewed never said it
        // would refresh anything, so it may not happen here.
        let provider = ScriptedUpdateProvider { _, candidate, context in
            var refused = false
            do {
                _ = try await context.runner.run(CommandRequest(
                    executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
                    arguments: ["update"],
                    effect: .metadataRefresh
                ))
            } catch {
                refused = (error as? MacUpError)?.kind == .policyDenied
            }
            return VerificationResult(
                item: candidate.id,
                outcome: .verified,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: candidate.availableVersion.raw,
                message: "refused=\(refused)"
            )
        }

        let report = await harness.engine(providers: [provider]).run(
            PlannedUpdateFactory.report([gitPlan()]),
            configuration: loaded,
            options: ExecutionOptions(origin: .cli),
            environment: harness.environment
        )

        #expect(report.executed.first?.verification?.message == "refused=true")
        #expect(harness.runner.recordedInvocations.map(\.arguments) == [["upgrade", "--formula", "git"]])
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

/// A provider MacUp finds, but whose detection is when Stop is pressed: the
/// run is cancelled after the item was allowed and before its first command.
/// Records whether MacUp then asked it to read anything back.
private final class StopDuringDetectionProvider: UpdateProvider, @unchecked Sendable {
    let id = ProviderID.homebrew
    let capabilities: Set<ProviderCapability> = [.detect, .planUpdates, .updateSelectedItems, .verifyUpdates]
    private let lock = NSLock()
    private var askedToVerify = false

    var wasAskedToVerify: Bool { lock.withLock { askedToVerify } }

    func detect(context: ProviderContext) async -> ProviderStatus {
        withUnsafeCurrentTask { $0?.cancel() }
        return ProviderStatus(provider: id, availability: .available, installation: ScriptedUpdateProvider.stubInstallation)
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> { ProviderListing() }
    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> { ProviderListing() }

    func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        lock.withLock { askedToVerify = true }
        return VerificationResult(
            item: candidate.id,
            outcome: .verified,
            expectedVersion: candidate.availableVersion.raw,
            observedVersion: candidate.availableVersion.raw,
            message: "Nothing ran, so this should never have been asked."
        )
    }
}

/// Cancels the run from inside the first modifying command, as pressing Stop
/// mid-command does, then lets the command finish.
private struct StopPressingRunner: CommandRunning {
    let base: any CommandRunning

    func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        if request.effect == .modifying {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return try await base.run(request, output: output)
    }
}
