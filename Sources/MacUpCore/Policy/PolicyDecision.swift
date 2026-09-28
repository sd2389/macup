/// Whether someone is present to confirm a change.
///
/// The distinction is a trust requirement, not a convenience: a scheduled run
/// may only touch items the user marked `auto` (CLAUDE.md §15).
public enum PolicyIntent: String, Sendable, Hashable, Codable, CaseIterable {
    /// A person asked for this and can confirm. `ask` items may run once confirmed.
    case interactive
    /// No one is watching (a scheduled run). Only `auto` items may run.
    case unattended
}

/// What policy says about one item, and why.
///
/// A decision always carries a human-readable reason: MacUp never refuses or
/// allows a change without being able to say why (CLAUDE.md §6).
public struct PolicyDecision: Sendable, Hashable, Codable {
    public enum Action: String, Sendable, Hashable, Codable, CaseIterable {
        /// May run without asking.
        case allow
        /// May run only after the user confirms this specific item.
        case confirm
        /// Must not run.
        case deny
    }

    /// Which rule decided, in precedence order plus the reasons that override them.
    public enum Source: String, Sendable, Hashable, Codable, CaseIterable {
        /// A per-item rule in the configuration.
        case item
        /// The provider's rule in the configuration.
        case provider
        /// The global default policy.
        case global
        /// The provider is turned off in the configuration.
        case providerDisabled
        /// The provider itself holds the item back (for example `brew pin`).
        case providerPin
        /// Risk raised the bar (unknown risk, a major change, an OS update).
        case risk
        /// The configuration could not be trusted, so nothing automatic may run.
        case configuration
        /// A scheduled run may only touch `auto` items.
        case unattended
    }

    public var item: PackageID
    public var action: Action
    /// The policy in effect after precedence. Never `.inherit`.
    public var policy: UpdatePolicy
    public var source: Source
    /// One display-safe sentence explaining the decision.
    public var reason: String
    /// True when risk turned an otherwise automatic update into a confirmation.
    public var escalated: Bool

    public init(
        item: PackageID,
        action: Action,
        policy: UpdatePolicy,
        source: Source,
        reason: String,
        escalated: Bool = false
    ) {
        self.item = item
        self.action = action
        self.policy = policy
        self.source = source
        self.reason = reason
        self.escalated = escalated
    }

    public var allowsExecution: Bool { action != .deny }
}
