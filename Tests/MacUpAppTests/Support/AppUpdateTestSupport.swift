import Foundation
import MacUpCore
import MacUpTestSupport

@testable import MacUpAppCore

/// A provider that reports the updates a test names, plans them with one exact
/// command, and answers verification the way the test says.
///
/// It stands in for Homebrew so that its plans match a reviewed
/// ``ModifyingCommandRule`` and travel through the same ``ExecutionGuard`` the
/// real provider's do. It launches nothing itself: the only command that can
/// run is the one a test registered with ``FakeCommandRunner``, which refuses
/// everything else, so no test can reach a package manager on the host.
final class StubPlanningProvider: UpdateProvider, @unchecked Sendable {
    /// The installation this provider claims. A path no test ever launches.
    static let executable = "/stub/bin/brew"

    /// The command the stub plans for one item. A test registers exactly this
    /// with the fake runner, so neither side has to guess what the other will
    /// do.
    static func arguments(for name: String) -> [String] {
        ["upgrade", "--formula", "--yes", name]
    }

    let id: ProviderID
    let capabilities: Set<ProviderCapability>

    private let lock = NSLock()
    private var _candidates: [UpdateCandidate]
    private var _installation: ProviderInstallation?
    private var _planFailures: [PackageID: MacUpError] = [:]
    private var _verification: VerificationResult.Outcome = .verified
    private var _observedVersion: String?
    private var _verificationFailure: MacUpError?
    /// Held part-way through detection so a test can cancel a batch that has
    /// started but has not yet launched a command.
    var detectRendezvous: Rendezvous?

    init(
        id: ProviderID = .homebrew,
        candidates: [UpdateCandidate] = [],
        canApplyUpdates: Bool = true,
        prefix: String? = nil
    ) {
        self.id = id
        var capabilities: Set<ProviderCapability> = [
            .detect, .inventory, .outdated, .planUpdates, .verifyUpdates,
        ]
        // A provider that reports updates without being able to apply them is
        // what macOS is: MacUp lists them and leaves installing to the user.
        if canApplyUpdates { capabilities.insert(.updateSelectedItems) }
        self.capabilities = capabilities
        _candidates = candidates
        _installation = ProviderInstallation(
            executable: ResolvedExecutable(
                path: Self.executable,
                canonicalPath: Self.executable,
                source: .standardLocation
            ),
            version: "4.0.0",
            facts: prefix.map { [ProviderFact(key: "prefix", label: "Prefix", value: $0)] } ?? []
        )
    }

    /// Makes one item unplannable, as a provider that cannot describe a change
    /// does. The planner must report it rather than guess.
    func refusePlan(for item: PackageID, _ error: MacUpError) {
        lock.withLock { _planFailures[item] = error }
    }

    /// What verification will answer. `observed` is the version MacUp reads
    /// back when the outcome is not `verified`.
    func verifies(_ outcome: VerificationResult.Outcome, observed: String? = nil) {
        lock.withLock {
            _verification = outcome
            _observedVersion = observed
        }
    }

    /// Makes verification itself fail, which must never read as confirmed.
    func failsVerification(_ error: MacUpError) {
        lock.withLock { _verificationFailure = error }
    }

    /// Makes the provider undetectable, as an installation that has moved
    /// since the plan was built would be. The engine must skip its plans.
    func becomesUndetectable() {
        lock.withLock { _installation = nil }
    }

    func detect(context: ProviderContext) async -> ProviderStatus {
        if let rendezvous = detectRendezvous { await rendezvous.arriveAndWait() }
        guard let installation = lock.withLock({ _installation }) else {
            return ProviderStatus(provider: id, availability: .unavailable)
        }
        return ProviderStatus(provider: id, availability: .available, installation: installation)
    }

    func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        ProviderListing()
    }

    func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        ProviderListing(lock.withLock { _candidates })
    }

    func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        if let failure = lock.withLock({ _planFailures[candidate.id] }) { throw failure }
        guard let installation = context.installation else {
            throw MacUpError(.providerUnavailable, "This test's provider recorded no installation.")
        }
        let signals = Set(candidate.signals)
        return ExecutionPlan(
            createdAt: context.now(),
            item: candidate.id,
            currentVersion: candidate.installedVersion,
            proposedVersion: candidate.availableVersion,
            risk: candidate.risk,
            rationale: "\(candidate.displayName) has a newer version available.",
            steps: [ExecutionStep(
                summary: "Update \(candidate.displayName)",
                invocation: CommandInvocation(
                    executable: installation.executable.path,
                    arguments: Self.arguments(for: candidate.id.name)
                ),
                effect: .modifying,
                expectsNetwork: true,
                mayRequirePrivilege: signals.contains(.administratorAuthorizationMayBeRequired),
                timeoutSeconds: 600
            )],
            expectsNetwork: true,
            mayRequirePrivilege: signals.contains(.administratorAuthorizationMayBeRequired),
            mayRequireRestart: signals.contains(.restartRequired),
            mayChangeUserConfiguration: signals.contains(.mayRewriteConfiguration),
            verification: [VerificationStep(
                summary: "Read back the installed version",
                expectedVersion: candidate.availableVersion.raw
            )],
            rollback: .notImplemented
        )
    }

    func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        let (outcome, observed, failure) = lock.withLock {
            (_verification, _observedVersion, _verificationFailure)
        }
        if let failure { throw failure }
        let expected = candidate.availableVersion.raw
        switch outcome {
        case .verified:
            return VerificationResult(
                item: candidate.id,
                outcome: .verified,
                expectedVersion: expected,
                observedVersion: expected,
                message: "\(candidate.displayName) is now \(expected)."
            )
        case .targetNotReached:
            return VerificationResult(
                item: candidate.id,
                outcome: .targetNotReached,
                expectedVersion: expected,
                observedVersion: observed,
                message: "\(candidate.displayName) is \(observed ?? "a different version"), not \(expected)."
            )
        case .failed, .notPerformed:
            return VerificationResult(
                item: candidate.id,
                outcome: outcome,
                expectedVersion: expected,
                observedVersion: nil,
                message: "MacUp could not read back \(candidate.displayName)'s version."
            )
        }
    }
}

/// A diagnostic that reports exactly the findings a test wrote, so the Doctor
/// screen can be tested without a machine to diagnose.
struct StubDiagnosticCheck: DiagnosticCheck {
    let id: String
    let title: String
    var findings: [DiagnosticFinding] = []

    init(id: String = "test.check", title: String = "A test check", findings: [DiagnosticFinding] = []) {
        self.id = id
        self.title = title
        self.findings = findings
    }

    func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] { findings }
}

extension DiagnosticFinding {
    /// A finding of one severity, for asserting how Doctor groups and orders
    /// what it found.
    static func test(
        _ severity: Severity,
        id: String,
        title: String,
        recommendation: String? = nil
    ) -> DiagnosticFinding {
        DiagnosticFinding(
            id: id,
            severity: severity,
            provider: nil,
            title: title,
            detail: "What MacUp observed while testing.",
            recommendation: recommendation
        )
    }
}

extension AppModelHarness {
    /// Registers the exact command one item's plan will run, so the fake
    /// runner answers it instead of refusing it.
    func allowUpdate(of name: String, _ response: FakeCommandRunner.Response = .success()) {
        runner.register(
            path: StubPlanningProvider.executable,
            StubPlanningProvider.arguments(for: name),
            response
        )
    }

    /// Writes a rule straight into the throwaway configuration, for tests that
    /// need MacUp to start from a rule rather than to set one.
    @discardableResult
    func rule(_ policy: UpdatePolicy, for item: PackageID) throws -> PolicyChange {
        let change = try PolicyEditor(paths: paths).setPolicy(policy, for: item)
        model.loadConfiguration()
        return change
    }

    /// Checks, plans, and opens the review sheet for everything found.
    func reviewEverything() async {
        await model.checkNow()
        await model.reviewUpdates()
    }

    /// Applies the reviewed plan and waits for the batch to finish, however it
    /// finishes.
    func applyAndWait() async {
        model.applyReviewedPlan()
        await model.applyTask?.value
    }

    /// Reads MacUp's history straight from the throwaway home, so a test can
    /// assert what was recorded without going through the model.
    func recordedHistory() throws -> [HistoryEntry] {
        try HistoryStore(paths: paths).load()
    }
}
