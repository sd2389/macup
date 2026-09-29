/// Coarse risk levels. Risk drives policy (CLAUDE.md §10): unknown risk means
/// Ask First. There is deliberately no numeric score.
public enum RiskLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case low
    case moderate
    case high
    case unknown

    public var displayName: String {
        switch self {
        case .low: "low risk"
        case .moderate: "moderate risk"
        case .high: "high risk"
        case .unknown: "unknown risk"
        }
    }

    fileprivate var rank: Int? {
        switch self {
        case .low: 0
        case .moderate: 1
        case .high: 2
        case .unknown: nil
        }
    }
}

/// A fact about an update that raises its risk, reported by the provider.
/// The ones that also mark it as needing attention are listed in
/// ``RiskSignal/needingAttention``.
public enum RiskSignal: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case runtimeOrToolchain
    case operatingSystemUpdate
    case restartRequired
    case administratorAuthorizationMayBeRequired
    case targetVersionNotGuaranteed
    case mayRewriteConfiguration
    case mayAffectDependents
    case pinnedByProvider
    case packageManagerSelfUpdate
    /// The provider has nothing ready-made for this machine and will compile
    /// it, which is slow and can fail part-way.
    case buildsFromSource
    /// An earlier install of this item never finished.
    case installationIncomplete
    /// The item is running now as a background service. The update changes
    /// the files it starts from while the running copy stays on the old version.
    case runsAsService
    /// A database moving to a new major version, which may convert its data
    /// files the first time it starts, in a way the old version cannot read.
    case mayMigrateData

    public var explanation: String {
        switch self {
        case .runtimeOrToolchain: "Changes a language runtime or toolchain"
        case .operatingSystemUpdate: "Updates the operating system"
        case .restartRequired: "Requires a restart"
        case .administratorAuthorizationMayBeRequired: "May require administrator authorization"
        case .targetVersionNotGuaranteed: "The provider cannot guarantee the target version"
        case .mayRewriteConfiguration: "May change configuration or lockfiles"
        case .mayAffectDependents: "May affect other software that depends on it"
        case .pinnedByProvider: "Pinned in the provider; updating would override the pin"
        case .packageManagerSelfUpdate: "Updates a package manager itself"
        case .buildsFromSource: "Will be built from source, which can take a long time"
        case .installationIncomplete: "An earlier install of it did not finish"
        case .runsAsService: "Runs as a background service, which keeps the old version until it restarts"
        case .mayMigrateData: "A database whose new major version may convert its data files, which cannot be undone"
        }
    }

    /// The least risk an update carrying this signal can have.
    public var minimumLevel: RiskLevel {
        switch self {
        case .operatingSystemUpdate, .restartRequired, .administratorAuthorizationMayBeRequired, .pinnedByProvider,
             .installationIncomplete, .mayMigrateData:
            .high
        case .runtimeOrToolchain, .targetVersionNotGuaranteed, .mayRewriteConfiguration,
             .mayAffectDependents, .packageManagerSelfUpdate, .buildsFromSource, .runsAsService:
            .moderate
        }
    }

    public static func < (lhs: RiskSignal, rhs: RiskSignal) -> Bool {
        let order = allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// A risk level with the human-readable reasons behind it.
public struct RiskAssessment: Sendable, Hashable, Codable {
    public var level: RiskLevel
    public var reasons: [String]

    public init(level: RiskLevel, reasons: [String]) {
        self.level = level
        self.reasons = reasons
    }
}

/// Derives risk from the version change and provider signals.
///
/// - patch, build, revision → low; minor → moderate; major, pre-release,
///   downgrade → high
/// - signals raise the level to at least their ``RiskSignal/minimumLevel``
/// - an unclassifiable version change stays `unknown` unless a signal makes
///   the update high risk regardless
public enum RiskAssessor {
    public static func assess(change: VersionChange, signals: Set<RiskSignal>) -> RiskAssessment {
        var reasons: [String] = []
        let changeLevel: RiskLevel
        switch change {
        case .patch:
            changeLevel = .low
            reasons.append("Patch-level version change")
        case .build:
            changeLevel = .low
            reasons.append("Build-number change")
        case .revision:
            changeLevel = .low
            reasons.append("Packaging revision of the same version")
        case .minor:
            changeLevel = .moderate
            reasons.append("Minor version change")
        case .major:
            changeLevel = .high
            reasons.append("Major version change")
        case .prerelease:
            changeLevel = .high
            reasons.append("Involves a pre-release version")
        case .downgrade:
            changeLevel = .high
            reasons.append("The offered version is older than the installed version")
        case .none:
            changeLevel = .unknown
            reasons.append("Installed and offered versions look identical")
        case .unknown:
            changeLevel = .unknown
            reasons.append("The version change could not be classified")
        }

        let orderedSignals = signals.sorted()
        reasons += orderedSignals.map(\.explanation)

        let signalRank = orderedSignals.compactMap(\.minimumLevel.rank).max()
        let level: RiskLevel
        if changeLevel == .high || signalRank == RiskLevel.high.rank {
            level = .high
        } else if let changeRank = changeLevel.rank {
            level = [RiskLevel.low, .moderate, .high][max(changeRank, signalRank ?? 0)]
        } else {
            level = .unknown
        }
        return RiskAssessment(level: level, reasons: reasons)
    }
}
