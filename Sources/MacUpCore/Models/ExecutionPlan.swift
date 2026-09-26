import Foundation

/// Where a modification request came from. Recorded in history.
public enum ExecutionOrigin: String, Sendable, Hashable, Codable, CaseIterable {
    case cli
    case gui
    case scheduled
}

/// One command within an execution plan.
public struct ExecutionStep: Sendable, Hashable, Codable {
    public var summary: String
    /// The exact executable and arguments that will run.
    public var invocation: CommandInvocation
    public var effect: CommandEffect
    public var expectsNetwork: Bool
    public var mayRequirePrivilege: Bool
    public var timeoutSeconds: Double

    public init(
        summary: String,
        invocation: CommandInvocation,
        effect: CommandEffect,
        expectsNetwork: Bool,
        mayRequirePrivilege: Bool,
        timeoutSeconds: Double
    ) {
        self.summary = summary
        self.invocation = invocation
        self.effect = effect
        self.expectsNetwork = expectsNetwork
        self.mayRequirePrivilege = mayRequirePrivilege
        self.timeoutSeconds = timeoutSeconds
    }
}

/// How MacUp will confirm an update worked.
public struct VerificationStep: Sendable, Hashable, Codable {
    public var summary: String
    /// A read-only command whose output is checked, when verification runs one.
    public var invocation: CommandInvocation?
    public var expectedVersion: String?

    public init(summary: String, invocation: CommandInvocation? = nil, expectedVersion: String? = nil) {
        self.summary = summary
        self.invocation = invocation
        self.expectedVersion = expectedVersion
    }
}

/// Whether an action can be undone. MacUp never claims rollback without an
/// implemented, tested strategy for that specific provider action.
public struct RollbackCapability: Sendable, Hashable, Codable {
    public enum Availability: String, Sendable, Hashable, Codable {
        case available
        case unavailable
        case unknown
    }

    public var availability: Availability
    public var explanation: String

    public init(availability: Availability, explanation: String) {
        self.availability = availability
        self.explanation = explanation
    }

    public static let notImplemented = RollbackCapability(
        availability: .unavailable,
        explanation: "MacUp has no tested rollback strategy for this action."
    )
}

/// Everything MacUp intends to do for one item, shown before anything runs
/// (CLAUDE.md §11). Built in Phase 2; executed in Phase 3.
public struct ExecutionPlan: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var item: PackageID
    public var currentVersion: InstalledVersion?
    public var proposedVersion: AvailableVersion
    public var risk: RiskAssessment
    public var rationale: String
    public var steps: [ExecutionStep]
    public var expectsNetwork: Bool
    public var mayRequirePrivilege: Bool
    public var mayRequireRestart: Bool
    public var mayChangeUserConfiguration: Bool
    public var verification: [VerificationStep]
    public var rollback: RollbackCapability

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        item: PackageID,
        currentVersion: InstalledVersion?,
        proposedVersion: AvailableVersion,
        risk: RiskAssessment,
        rationale: String,
        steps: [ExecutionStep],
        expectsNetwork: Bool,
        mayRequirePrivilege: Bool,
        mayRequireRestart: Bool,
        mayChangeUserConfiguration: Bool,
        verification: [VerificationStep],
        rollback: RollbackCapability
    ) {
        self.id = id
        self.createdAt = createdAt
        self.item = item
        self.currentVersion = currentVersion
        self.proposedVersion = proposedVersion
        self.risk = risk
        self.rationale = rationale
        self.steps = steps
        self.expectsNetwork = expectsNetwork
        self.mayRequirePrivilege = mayRequirePrivilege
        self.mayRequireRestart = mayRequireRestart
        self.mayChangeUserConfiguration = mayChangeUserConfiguration
        self.verification = verification
        self.rollback = rollback
    }

    public var provider: ProviderID { item.provider }
}
