/// What kind of thing a provider manages.
public enum ItemKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A Homebrew formula.
    case formula
    /// A Homebrew cask.
    case cask
    /// A globally installed npm package.
    case globalPackage
    /// A runtime or tool managed by mise.
    case tool
    /// A macOS software update.
    case systemUpdate
}

/// One step in "who manages this?", for example `npm → Node 24.19.0 → mise`.
public struct OwnershipLink: Sendable, Hashable, Codable {
    public var label: String
    /// The executable, installation, or configuration file behind this link.
    public var path: String?

    public init(label: String, path: String? = nil) {
        self.label = label
        self.path = path
    }
}

/// The chain of tools responsible for an item, outermost first.
public struct OwnershipChain: Sendable, Hashable, Codable {
    public var links: [OwnershipLink]

    public init(_ links: [OwnershipLink]) {
        self.links = links
    }

    public var summary: String {
        links.map(\.label).joined(separator: " → ")
    }
}

/// Something a provider reports as installed.
public struct ManagedItem: Sendable, Hashable, Codable, Identifiable {
    public var id: PackageID
    public var kind: ItemKind
    public var displayName: String
    /// Every installed version the provider reports.
    public var installedVersions: [InstalledVersion]
    /// The version in use, when the provider distinguishes one
    /// (a linked Homebrew keg, the active mise version).
    public var activeVersion: InstalledVersion?
    public var pinnedByProvider: Bool
    public var ownership: OwnershipChain?
    /// Provider-specific, display-safe facts with stable keys.
    public var details: [String: String]

    public init(
        id: PackageID,
        kind: ItemKind,
        displayName: String,
        installedVersions: [InstalledVersion],
        activeVersion: InstalledVersion? = nil,
        pinnedByProvider: Bool = false,
        ownership: OwnershipChain? = nil,
        details: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.installedVersions = installedVersions
        self.activeVersion = activeVersion
        self.pinnedByProvider = pinnedByProvider
        self.ownership = ownership
        self.details = details
    }

    public var provider: ProviderID { id.provider }
}
