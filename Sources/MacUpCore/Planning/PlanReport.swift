import Foundation

/// An update MacUp knows exactly how to perform, with the policy decision
/// that let it into the plan.
public struct PlannedUpdate: Sendable, Hashable, Codable, Identifiable {
    public var candidate: UpdateCandidate
    public var decision: PolicyDecision
    public var plan: ExecutionPlan

    public init(candidate: UpdateCandidate, decision: PolicyDecision, plan: ExecutionPlan) {
        self.candidate = candidate
        self.decision = decision
        self.plan = plan
    }

    public var id: PackageID { candidate.id }
    public var item: PackageID { candidate.id }
    public var provider: ProviderID { candidate.provider }
    /// Whether the user must confirm this specific item before it runs.
    public var needsConfirmation: Bool { decision.action == .confirm }
}

/// An update MacUp will not perform, and the reason it will not.
///
/// Every candidate that does not become a ``PlannedUpdate`` appears here:
/// a plan never loses an item silently.
public struct SkippedUpdate: Sendable, Hashable, Codable, Identifiable {
    public var item: PackageID
    public var displayName: String
    public var currentVersion: String?
    public var proposedVersion: String?
    /// The policy decision behind the skip, when policy was the reason.
    public var decision: PolicyDecision?
    /// One display-safe sentence explaining the skip.
    public var reason: String
    /// The error behind the skip, when MacUp could not build a plan.
    public var error: MacUpError?

    public init(
        item: PackageID,
        displayName: String,
        currentVersion: String? = nil,
        proposedVersion: String? = nil,
        decision: PolicyDecision? = nil,
        reason: String,
        error: MacUpError? = nil
    ) {
        self.item = item
        self.displayName = displayName
        self.currentVersion = currentVersion
        self.proposedVersion = proposedVersion
        self.decision = decision
        self.reason = reason
        self.error = error
    }

    public var id: PackageID { item }
    public var provider: ProviderID { item.provider }
}

/// What a plan run should cover.
public struct PlanRequest: Sendable, Hashable {
    /// Limit the plan to these items; `nil` plans every candidate found.
    public var selection: Set<PackageID>?
    public var intent: PolicyIntent
    /// Refresh provider metadata before looking for updates.
    public var refreshMetadata: Bool

    public init(selection: Set<PackageID>? = nil, intent: PolicyIntent = .interactive, refreshMetadata: Bool = false) {
        self.selection = selection
        self.intent = intent
        self.refreshMetadata = refreshMetadata
    }
}

/// The result of `macup plan` and of `macup update --dry-run`: every change
/// MacUp would make, with the exact commands, and every change it would not.
///
/// Schema version 1. New fields may be added within a version; renaming or
/// removing one requires a new version (docs/CLI.md).
public struct PlanReport: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    public struct Summary: Sendable, Hashable, Codable {
        /// Plans that may run without asking.
        public var allowed: Int
        /// Plans that need the user to confirm the item.
        public var needsConfirmation: Int
        /// Candidates policy refused.
        public var deniedByPolicy: Int
        /// Candidates MacUp could not turn into a plan.
        public var unplannable: Int

        public init(allowed: Int, needsConfirmation: Int, deniedByPolicy: Int, unplannable: Int) {
            self.allowed = allowed
            self.needsConfirmation = needsConfirmation
            self.deniedByPolicy = deniedByPolicy
            self.unplannable = unplannable
        }
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var createdAt: Date
    public var intent: PolicyIntent
    public var planned: [PlannedUpdate]
    public var skipped: [SkippedUpdate]
    public var summary: Summary
    public var configuration: ConfigurationSummary?
    /// Items named on the command line that no provider offered an update for.
    public var unmatchedSelection: [PackageID]
    /// Provider reports behind the plan, so a failed provider is visible.
    public var providers: [ProviderReport]
    public var cancelled: Bool
    /// Set when `planned` and `skipped` were narrowed or reordered
    /// (``filtered(_:sortedBy:candidates:)``), and absent otherwise, so an
    /// unfiltered plan encodes as it always has.
    public var filter: ReportFilter?

    public init(
        createdAt: Date,
        intent: PolicyIntent,
        planned: [PlannedUpdate],
        skipped: [SkippedUpdate],
        configuration: ConfigurationSummary? = nil,
        unmatchedSelection: [PackageID] = [],
        providers: [ProviderReport] = [],
        cancelled: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "plan"
        self.macupVersion = MacUp.version
        self.createdAt = createdAt
        self.intent = intent
        self.planned = planned
        self.skipped = skipped
        self.configuration = configuration
        self.unmatchedSelection = unmatchedSelection
        self.providers = providers
        self.cancelled = cancelled
        self.summary = Summary(
            allowed: planned.filter { $0.decision.action == .allow }.count,
            needsConfirmation: planned.filter { $0.decision.action == .confirm }.count,
            deniedByPolicy: skipped.filter { $0.decision?.action == .deny }.count,
            unplannable: skipped.filter { $0.decision?.action != .deny }.count
        )
    }

    public var isEmpty: Bool { planned.isEmpty }
    /// Plans that may run with no further confirmation.
    public var allowed: [PlannedUpdate] { planned.filter { $0.decision.action == .allow } }
    /// Plans waiting on the user.
    public var needingConfirmation: [PlannedUpdate] { planned.filter { $0.decision.action == .confirm } }

    public func planned(for provider: ProviderID) -> [PlannedUpdate] {
        planned.filter { $0.provider == provider }
    }
}
