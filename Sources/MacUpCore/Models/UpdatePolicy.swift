/// What MacUp may do with an item's updates (CLAUDE.md §6).
///
/// Precedence is per-item rule, then provider rule, then the global default.
/// Policy evaluation arrives in Phase 2; Phase 1 only stores and validates it.
public enum UpdatePolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// May be updated without asking, including by scheduled maintenance.
    case auto
    /// Shown for review; updated only when the user approves.
    case ask
    /// Never updated and never proposed.
    case ignore
    /// Held at its current version.
    case pin
    /// Use the next rule in precedence order.
    case inherit

    public var displayName: String {
        switch self {
        case .auto: "Auto Update"
        case .ask: "Ask First"
        case .ignore: "Ignore"
        case .pin: "Pin"
        case .inherit: "Inherit"
        }
    }
}

/// Capabilities a provider declares. Providers declare only what they implement.
public enum ProviderCapability: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Locate the provider and report its version.
    case detect
    /// List installed items.
    case inventory
    /// List available updates without changing anything.
    case outdated
    /// Refresh package metadata on explicit request (`macup check --refresh`).
    case refreshMetadata
    /// Build exact execution plans (Phase 2).
    case planUpdates
    /// Update one selected item at a time (Phase 3).
    case updateSelectedItems
    /// Verify the installed version after an update (Phase 3).
    case verifyUpdates
    /// Say what installed software depends on an item, when someone asks.
    /// Never part of a check.
    case listDependents

    public static func < (lhs: ProviderCapability, rhs: ProviderCapability) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
