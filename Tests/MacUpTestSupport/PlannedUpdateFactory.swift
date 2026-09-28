import Foundation
import MacUpCore

/// Builds the plan shapes execution tests need, so a test can describe the
/// plan it cares about without a real provider's planning code.
public enum PlannedUpdateFactory {
    public static func candidate(
        _ id: String,
        installed: String? = "1.0.0",
        available: String = "1.0.1",
        kind: ItemKind = .formula,
        signals: Set<RiskSignal> = [],
        displayName: String? = nil
    ) -> UpdateCandidate {
        let packageID = try! PackageID(parsing: id)
        return UpdateCandidate(
            id: packageID,
            kind: kind,
            displayName: displayName ?? packageID.name,
            installedVersion: installed.map { InstalledVersion($0) },
            availableVersion: AvailableVersion(available),
            signals: signals
        )
    }

    public static func step(
        _ executable: String,
        _ arguments: [String],
        effect: CommandEffect = .modifying,
        summary: String? = nil,
        expectsNetwork: Bool = true,
        mayRequirePrivilege: Bool = false,
        timeoutSeconds: Double = 600
    ) -> ExecutionStep {
        ExecutionStep(
            summary: summary ?? "Run \((executable as NSString).lastPathComponent) \(arguments.joined(separator: " "))",
            invocation: CommandInvocation(executable: executable, arguments: arguments),
            effect: effect,
            expectsNetwork: expectsNetwork,
            mayRequirePrivilege: mayRequirePrivilege,
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func plan(
        for candidate: UpdateCandidate,
        steps: [ExecutionStep],
        verification: [VerificationStep] = [],
        risk: RiskAssessment? = nil,
        mayRequireRestart: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> ExecutionPlan {
        ExecutionPlan(
            createdAt: createdAt,
            item: candidate.id,
            currentVersion: candidate.installedVersion,
            proposedVersion: candidate.availableVersion,
            risk: risk ?? candidate.risk,
            rationale: "\(candidate.displayName) has a newer version available.",
            steps: steps,
            expectsNetwork: steps.contains(where: \.expectsNetwork),
            mayRequirePrivilege: steps.contains(where: \.mayRequirePrivilege),
            mayRequireRestart: mayRequireRestart,
            mayChangeUserConfiguration: false,
            verification: verification,
            rollback: .notImplemented
        )
    }

    /// A candidate, a plan, and the policy decision that let it in. `action`
    /// and `policy` describe what the planner decided; the engine asks again.
    public static func planned(
        _ candidate: UpdateCandidate,
        steps: [ExecutionStep],
        verification: [VerificationStep] = [],
        action: PolicyDecision.Action = .allow,
        policy: UpdatePolicy = .auto,
        risk: RiskAssessment? = nil,
        mayRequireRestart: Bool = false
    ) -> PlannedUpdate {
        PlannedUpdate(
            candidate: candidate,
            decision: PolicyDecision(
                item: candidate.id,
                action: action,
                policy: policy,
                source: .item,
                reason: "\(candidate.displayName) was planned for this test."
            ),
            plan: plan(
                for: candidate,
                steps: steps,
                verification: verification,
                risk: risk,
                mayRequireRestart: mayRequireRestart
            )
        )
    }

    public static func report(
        _ planned: [PlannedUpdate],
        skipped: [SkippedUpdate] = [],
        intent: PolicyIntent = .interactive,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> PlanReport {
        PlanReport(createdAt: createdAt, intent: intent, planned: planned, skipped: skipped)
    }
}
