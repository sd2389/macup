import Foundation

/// Everything MacUp knows about one item, in one place: what `macup explain`
/// prints, and what the app's Copy Details puts on the clipboard.
///
/// It is built by reading only. The check behind it is the read-only check,
/// the plan in it is a description that nothing launches, and history is only
/// read. ``ItemExplainer`` builds one; ``ExplanationText`` words it.
///
/// Schema version 1. New fields may be added within a version; renaming or
/// removing one requires a new version (docs/CLI.md).
public struct ItemExplanation: Sendable, Hashable, Codable {
    public static let schemaVersion = 1

    /// What MacUp found when it looked for the item.
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        /// The provider offers an update.
        case updateAvailable
        /// Installed, and the provider offers no update.
        case upToDate
        /// Installed, but MacUp could not find out whether an update is available.
        case updateUnknown
        /// The provider was checked and knows nothing about the item.
        case notFound
        /// The provider is turned off in MacUp's configuration, so MacUp did not look.
        case providerDisabled
        /// MacUp could not find the provider on this Mac.
        case providerNotFound
        /// MacUp could not finish checking the provider, so it cannot say.
        case checkFailed

        /// True when MacUp has nothing current to say about the item: no
        /// provider it looked at reports it. Everything else is an item
        /// MacUp found, or one it could not rule out.
        public var isUnknownItem: Bool {
            switch self {
            case .notFound, .providerDisabled, .providerNotFound: true
            case .updateAvailable, .upToDate, .updateUnknown, .checkFailed: false
            }
        }
    }

    /// The rule MacUp applies to the item and, when there is an update, what
    /// it decided about it.
    public struct Policy: Sendable, Hashable, Codable {
        /// The policy in effect after precedence. Never `inherit`.
        public var policy: UpdatePolicy
        /// Which rule supplies it: `item`, `provider`, or `global`.
        public var source: PolicyDecision.Source
        /// Where that rule lives in the configuration file, such as
        /// `items.brew:git.policy`.
        public var rule: String
        /// What policy decided about the available update, and why. `nil`
        /// when there is no update to decide about.
        public var decision: PolicyDecision?

        public init(policy: UpdatePolicy, source: PolicyDecision.Source, rule: String, decision: PolicyDecision? = nil) {
            self.policy = policy
            self.source = source
            self.rule = rule
            self.decision = decision
        }
    }

    /// The item's most recent history entries.
    public struct History: Sendable, Hashable, Codable {
        /// Newest first, at most ``limit``.
        public var entries: [HistoryEntry]
        public var limit: Int
        /// History holds older entries for the item than the ones shown.
        public var moreAvailable: Bool
        /// Lines MacUp could not decode while looking. Any of them may have
        /// been about this item.
        public var unreadableLines: Int
        /// Why history could not be read, when it could not.
        public var problem: String?

        public init(
            entries: [HistoryEntry] = [],
            limit: Int,
            moreAvailable: Bool = false,
            unreadableLines: Int = 0,
            problem: String? = nil
        ) {
            self.entries = entries
            self.limit = limit
            self.moreAvailable = moreAvailable
            self.unreadableLines = unreadableLines
            self.problem = problem
        }
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var createdAt: Date
    public var item: PackageID
    public var status: Status
    /// One sentence saying what MacUp found. Built from provider output, so a
    /// renderer sanitizes it like any other untrusted text.
    public var summary: String
    /// The update, as `macup check` reports it.
    public var update: UpdateCandidate?
    /// What differs between the installed and the available version.
    public var versionDifference: VersionDifference?
    /// Where to read about the available version, when the provider says.
    public var releaseInfoLink: ReleaseInfoLink?
    /// The item as its provider lists it installed, when the check kept the
    /// installed items.
    public var installed: ManagedItem?
    public var policy: Policy
    /// What MacUp would run for the update. `nil` when it would run nothing.
    public var plan: ExecutionPlan?
    /// Why MacUp would run nothing for an update it found.
    public var skipped: SkippedUpdate?
    public var history: History
    /// The provider's part of the check: which installation MacUp used and
    /// anything that failed. Its installed items are left out.
    public var providerReport: ProviderReport?
    public var configuration: ConfigurationSummary
    public var cancelled: Bool

    public init(
        createdAt: Date,
        item: PackageID,
        status: Status,
        summary: String,
        update: UpdateCandidate? = nil,
        installed: ManagedItem? = nil,
        policy: Policy,
        plan: ExecutionPlan? = nil,
        skipped: SkippedUpdate? = nil,
        history: History,
        providerReport: ProviderReport? = nil,
        configuration: ConfigurationSummary,
        cancelled: Bool = false
    ) {
        self.schemaVersion = Self.schemaVersion
        self.kind = "explain"
        self.macupVersion = MacUp.version
        self.createdAt = createdAt
        self.item = item
        self.status = status
        self.summary = summary
        self.update = update
        self.versionDifference = update?.versionDifference
        self.releaseInfoLink = update?.releaseInfoLink
        self.installed = installed
        self.policy = policy
        self.plan = plan
        self.skipped = skipped
        self.history = history
        var report = providerReport
        report?.items = nil
        self.providerReport = report
        self.configuration = configuration
        self.cancelled = cancelled
    }

    /// The exact command line of each step MacUp would run, one per line:
    /// the plan's display form, shell-quoted so it reads as one command, with
    /// anything secret-shaped removed. `nil` when MacUp would run nothing.
    ///
    /// This is what the app's Copy Command puts on the clipboard. MacUp itself
    /// never runs it from this string; it launches the plan's executable and
    /// argument array.
    public var commandText: String? {
        guard let plan, !plan.steps.isEmpty else { return nil }
        let redactor = Redactor()
        return plan.steps.map { redactor.redact($0.invocation.displayString) }.joined(separator: "\n")
    }

    /// What to run next when MacUp knows nothing about the item, or could
    /// not check it.
    public var suggestion: String? {
        switch status {
        case .notFound:
            let listsInstalled = providerReport?.capabilities.contains(.inventory) ?? false
            return listsInstalled
                ? "`macup check --inventory` lists every item MacUp can see."
                : "`macup check` lists the updates MacUp found."
        case .providerDisabled:
            return "`macup provider enable \(item.provider.rawValue)` turns \(item.provider.displayName) back on."
        case .providerNotFound:
            return "`macup provider list` shows which providers MacUp found, and where."
        case .checkFailed, .updateUnknown:
            return "`macup check --verbose` shows what went wrong."
        case .updateAvailable, .upToDate:
            return nil
        }
    }
}
