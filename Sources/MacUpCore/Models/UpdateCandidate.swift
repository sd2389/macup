/// An available update, normalized across providers.
///
/// A candidate is information, not permission: whether MacUp may act on it
/// is decided later by policy evaluation and planning.
public struct UpdateCandidate: Sendable, Hashable, Codable, Identifiable {
    public var id: PackageID
    public var kind: ItemKind
    public var displayName: String
    /// `nil` when the provider does not report the installed version
    /// (for example non-OS macOS updates).
    public var installedVersion: InstalledVersion?
    public var availableVersion: AvailableVersion
    public var versionChange: VersionChange
    public var signals: [RiskSignal]
    public var risk: RiskAssessment
    public var ownership: OwnershipChain?
    /// Display-safe context worth showing next to the item.
    public var notes: [String]
    /// Provider-specific, display-safe facts with stable keys.
    public var details: [String: String]

    public init(
        id: PackageID,
        kind: ItemKind,
        displayName: String,
        installedVersion: InstalledVersion?,
        availableVersion: AvailableVersion,
        versionScheme: VersionScheme = .standard,
        signals: Set<RiskSignal> = [],
        ownership: OwnershipChain? = nil,
        notes: [String] = [],
        details: [String: String] = [:]
    ) {
        let change = installedVersion.map {
            VersionComparator.classify(from: $0.raw, to: availableVersion.raw, scheme: versionScheme)
        } ?? .unknown
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.versionChange = change
        self.signals = signals.sorted()
        self.risk = RiskAssessor.assess(change: change, signals: signals)
        self.ownership = ownership
        self.notes = notes
        self.details = details
    }

    public var provider: ProviderID { id.provider }

    /// Returns a copy with a different installed version, the change and the
    /// risk worked out again from it.
    public func replacingInstalledVersion(_ version: InstalledVersion, scheme: VersionScheme) -> UpdateCandidate {
        UpdateCandidate(
            id: id,
            kind: kind,
            displayName: displayName,
            installedVersion: version,
            availableVersion: availableVersion,
            versionScheme: scheme,
            signals: Set(signals),
            ownership: ownership,
            notes: notes,
            details: details
        )
    }

    /// Returns a copy with extra signals and notes, reassessing risk.
    public func adding(signals extraSignals: Set<RiskSignal> = [], notes extraNotes: [String] = []) -> UpdateCandidate {
        var copy = self
        let combined = Set(signals).union(extraSignals)
        copy.signals = combined.sorted()
        copy.risk = RiskAssessor.assess(change: versionChange, signals: combined)
        copy.notes += extraNotes.filter { !copy.notes.contains($0) }
        return copy
    }
}
