/// A display-safe fact about a provider installation, such as its global
/// prefix. Keys are stable identifiers; labels are for people.
public struct ProviderFact: Sendable, Hashable, Codable {
    public var key: String
    public var label: String
    public var value: String

    public init(key: String, label: String, value: String) {
        self.key = key
        self.label = label
        self.value = value
    }
}

/// The exact installation of a provider that MacUp will use.
public struct ProviderInstallation: Sendable, Hashable, Codable {
    public var executable: ResolvedExecutable
    public var version: String?
    public var facts: [ProviderFact]

    public init(executable: ResolvedExecutable, version: String?, facts: [ProviderFact] = []) {
        self.executable = executable
        self.version = version
        self.facts = facts
    }

    public func fact(_ key: String) -> String? {
        facts.first { $0.key == key }?.value
    }
}

/// The outcome of detecting one provider.
public struct ProviderStatus: Sendable, Hashable, Codable {
    public enum Availability: String, Sendable, Hashable, Codable {
        /// Found and usable.
        case available
        /// Not installed, or not found where MacUp looks.
        case unavailable
        /// Turned off in MacUp's configuration; nothing was run.
        case disabled
        /// Found but not usable (for example a broken installation).
        case failed
    }

    public var provider: ProviderID
    public var availability: Availability
    public var installation: ProviderInstallation?
    public var findings: [DiagnosticFinding]
    /// Why the provider is unavailable or failed.
    public var error: MacUpError?

    public init(
        provider: ProviderID,
        availability: Availability,
        installation: ProviderInstallation? = nil,
        findings: [DiagnosticFinding] = [],
        error: MacUpError? = nil
    ) {
        self.provider = provider
        self.availability = availability
        self.installation = installation
        self.findings = findings
        self.error = error
    }

    public static func disabled(_ provider: ProviderID) -> ProviderStatus {
        ProviderStatus(provider: provider, availability: .disabled)
    }
}

/// A deterministic diagnostic observation. Findings explain; they never fix.
public struct DiagnosticFinding: Sendable, Hashable, Codable, Identifiable {
    public enum Severity: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
        case info
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// Stable code such as `homebrew.multipleInstallations`.
    public var id: String
    public var severity: Severity
    public var provider: ProviderID?
    public var title: String
    public var detail: String?
    public var recommendation: String?
    /// The one change MacUp can make for this finding, when there is one it
    /// is sure about. Most findings have none: Doctor explains, and only
    /// offers to act where the thing to change is MacUp's own (ADR-024).
    public var fix: DiagnosticFix?

    public init(
        id: String,
        severity: Severity,
        provider: ProviderID?,
        title: String,
        detail: String? = nil,
        recommendation: String? = nil,
        fix: DiagnosticFix? = nil
    ) {
        self.id = id
        self.severity = severity
        self.provider = provider
        self.title = title
        self.detail = detail
        self.recommendation = recommendation
        self.fix = fix
    }
}

/// Something Doctor can put right, described before it is done.
///
/// Every fix changes something that belongs to MacUp — its configuration,
/// or the launchd agent it installed — and nothing that belongs to a package
/// manager (ADR-024). There is no general "fix everything": a finding either
/// carries one of these, or it keeps saying what to do by hand.
public struct DiagnosticFix: Sendable, Hashable, Codable {
    /// What a fix does. A closed list, so a fix is never an arbitrary
    /// command and nothing outside this file can invent one.
    public enum Action: Sendable, Hashable, Codable {
        /// Drop rules naming software no provider reports as installed.
        case clearItemRules([String])
        /// Forget a provider's configured executable path, so MacUp resolves
        /// the tool itself again.
        case clearProviderPath(ProviderID)
        /// Write and load the launchd agent the configuration asks for.
        case installScheduleAgent
        /// Remove an installed agent the configuration no longer asks for.
        case removeScheduleAgent
    }

    public var action: Action
    /// What the fix does, in one line, for a button or a prompt.
    public var summary: String
    /// Exactly what it changes: the keys, the file, the command.
    public var detail: String

    public init(action: Action, summary: String, detail: String) {
        self.action = action
        self.summary = summary
        self.detail = detail
    }
}
