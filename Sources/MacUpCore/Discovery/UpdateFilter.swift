import Foundation

// Finding things in a long update list: one filter, one set of sort orders,
// and one way of counting what a filter hides. The Updates screen and
// `macup check`/`macup plan` both use these, so the two surfaces cannot
// disagree about what a filter keeps or how a list is ordered.

extension RiskSignal {
    /// The signals that mark an update as needing a closer look before it
    /// runs, whatever its risk level says: something about this particular
    /// install is out of the ordinary.
    ///
    /// The Updates screen's Needs Attention filter and `macup check
    /// --attention` both read this set, so a new signal that belongs under
    /// that heading is added here and nowhere else.
    public static let needingAttention: Set<RiskSignal> = [.buildsFromSource, .installationIncomplete]
}

extension UpdateCandidate {
    /// Whether this update carries one of ``RiskSignal/needingAttention``.
    public var needsAttention: Bool {
        signals.contains(where: RiskSignal.needingAttention.contains)
    }
}

/// How an update list is ordered.
///
/// Every order is total: ties fall back to the provider order, then to the
/// package ID, so the same updates always come out the same way, on screen
/// and in a script.
public enum UpdateSortOrder: String, Sendable, Hashable, Codable, CaseIterable {
    /// Grouped by provider in MacUp's provider order, then by package ID.
    /// This is the order a check reports updates in.
    case provider
    /// Highest risk first: high, unknown, moderate, low. Unknown sits just
    /// below high because MacUp could not rule high out.
    case risk
    /// By name, ignoring case, with numbers in numeric order.
    case name
    /// Largest version change first: major, minor, patch, build, revision,
    /// pre-release, then a downgrade, then no change at all, then a change
    /// MacUp could not classify.
    case change

    public var displayName: String {
        switch self {
        case .provider: "Provider"
        case .risk: "Risk, highest first"
        case .name: "Name"
        case .change: "Size of change, largest first"
        }
    }

    /// Whether `lhs` comes before `rhs` in this order.
    public func areInIncreasingOrder(_ lhs: UpdateCandidate, _ rhs: UpdateCandidate) -> Bool {
        switch self {
        case .provider:
            break
        case .risk:
            let (left, right) = (Self.rank(lhs.risk.level), Self.rank(rhs.risk.level))
            if left != right { return left < right }
        case .name:
            switch lhs.displayName.compare(rhs.displayName, options: [.caseInsensitive, .numeric]) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }
        case .change:
            let (left, right) = (Self.rank(lhs.versionChange), Self.rank(rhs.versionChange))
            if left != right { return left < right }
        }
        if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
        return lhs.id < rhs.id
    }

    static func rank(_ level: RiskLevel) -> Int {
        switch level {
        case .high: 0
        case .unknown: 1
        case .moderate: 2
        case .low: 3
        }
    }

    static func rank(_ change: VersionChange) -> Int {
        switch change {
        case .major: 0
        case .minor: 1
        case .patch: 2
        case .build: 3
        case .revision: 4
        case .prerelease: 5
        case .downgrade: 6
        case .none: 7
        case .unknown: 8
        }
    }
}

/// Which updates a list shows.
///
/// The values within one criterion are alternatives and the criteria combine:
/// high *or* unknown risk, *and* set to Ask First. An empty criterion keeps
/// everything. A filter only narrows what is shown, never what MacUp found,
/// and what it leaves out is counted (``UpdateListing/hidden``), so a screen
/// or a report can always say how much it is hiding (CLAUDE.md §21).
public struct UpdateFilter: Sendable, Hashable {
    /// Words to look for in the name, the package ID, and the provider's
    /// name. Every word has to appear in at least one of them; case and
    /// accents are ignored.
    public var searchText: String
    public var providers: Set<ProviderID>
    public var riskLevels: Set<RiskLevel>
    /// The policy in effect, once the item, provider, and default rules are
    /// resolved. `inherit` matches nothing: no item's policy in effect is
    /// `inherit`.
    public var policies: Set<UpdatePolicy>
    /// Only updates carrying a signal in ``RiskSignal/needingAttention``.
    public var needsAttentionOnly: Bool

    public init(
        searchText: String = "",
        providers: Set<ProviderID> = [],
        riskLevels: Set<RiskLevel> = [],
        policies: Set<UpdatePolicy> = [],
        needsAttentionOnly: Bool = false
    ) {
        self.searchText = searchText
        self.providers = providers
        self.riskLevels = riskLevels
        self.policies = policies
        self.needsAttentionOnly = needsAttentionOnly
    }

    /// Whether this filter can hide anything at all.
    public var isActive: Bool { hasSearch || hasCriteria }

    /// Whether there are search words, as opposed to only whitespace.
    public var hasSearch: Bool { !searchTerms.isEmpty }

    /// Whether anything other than the search narrows the list.
    public var hasCriteria: Bool {
        !providers.isEmpty || !riskLevels.isEmpty || !policies.isEmpty || needsAttentionOnly
    }

    /// Whether `update` stays in the list. `policy` is the policy in effect
    /// for it; an update whose policy is not known does not match a policy
    /// criterion, since MacUp cannot say it is the policy asked for.
    public func matches(_ update: UpdateCandidate, policy: UpdatePolicy?) -> Bool {
        matches(update, policy: policy, terms: searchTerms)
    }

    /// Splits `updates` into what this filter keeps, in `order`, and what it
    /// leaves out, in the order given.
    public func apply(
        to updates: [UpdateCandidate],
        sortedBy order: UpdateSortOrder,
        effectivePolicies: [PackageID: UpdatePolicy]
    ) -> UpdateListing {
        let terms = searchTerms
        var shown: [UpdateCandidate] = []
        var hidden: [UpdateCandidate] = []
        for update in updates {
            if matches(update, policy: effectivePolicies[update.id], terms: terms) {
                shown.append(update)
            } else {
                hidden.append(update)
            }
        }
        return UpdateListing(shown: shown.sorted(by: order.areInIncreasingOrder), hidden: hidden, order: order)
    }

    /// The criteria in words, such as "high or unknown risk, Ask First,
    /// needs attention". Empty when nothing narrows the list.
    public var summary: String {
        var parts: [String] = []
        if hasSearch {
            parts.append("matching “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
        }
        if !providers.isEmpty {
            parts.append(providers.sorted().map(\.displayName).joined(separator: " or "))
        }
        if !riskLevels.isEmpty {
            let levels = riskLevels.sorted { UpdateSortOrder.rank($0) < UpdateSortOrder.rank($1) }
            parts.append(levels.map(\.rawValue).joined(separator: " or ") + " risk")
        }
        if !policies.isEmpty {
            parts.append(UpdatePolicy.allCases.filter(policies.contains).map(\.displayName).joined(separator: " or "))
        }
        if needsAttentionOnly {
            parts.append("needs attention")
        }
        return parts.joined(separator: ", ")
    }

    private var searchTerms: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func matches(_ update: UpdateCandidate, policy: UpdatePolicy?, terms: [String]) -> Bool {
        if !providers.isEmpty, !providers.contains(update.provider) { return false }
        if !riskLevels.isEmpty, !riskLevels.contains(update.risk.level) { return false }
        if !policies.isEmpty {
            guard let policy, policies.contains(policy) else { return false }
        }
        if needsAttentionOnly, !update.needsAttention { return false }
        guard !terms.isEmpty else { return true }
        let fields = [update.displayName, update.id.rawValue, update.provider.displayName, update.provider.rawValue]
        return terms.allSatisfy { term in
            fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// An update list once a filter and an order have been applied: what is
/// shown, and what is hidden. Hidden updates are kept, not dropped, so the
/// count of them is always there to report.
public struct UpdateListing: Sendable, Hashable {
    /// Updates listed together under one heading.
    public struct Group: Sendable, Hashable, Identifiable {
        /// The provider, when the list is grouped by provider.
        public var provider: ProviderID?
        public var updates: [UpdateCandidate]

        public var id: String { provider?.rawValue ?? "" }
    }

    /// What the filter kept, in ``order``.
    public var shown: [UpdateCandidate]
    /// What the filter left out, in the order it was given.
    public var hidden: [UpdateCandidate]
    public var order: UpdateSortOrder

    public init(shown: [UpdateCandidate], hidden: [UpdateCandidate], order: UpdateSortOrder) {
        self.shown = shown
        self.hidden = hidden
        self.order = order
    }

    public var hiddenCount: Int { hidden.count }

    /// The shown updates as a list presents them: one group per provider,
    /// in provider order, when sorted by provider; otherwise one group in
    /// the chosen order.
    public var groups: [Group] {
        guard !shown.isEmpty else { return [] }
        guard order == .provider else { return [Group(provider: nil, updates: shown)] }
        var groups: [Group] = []
        for update in shown {
            if groups.last?.provider == update.provider {
                groups[groups.count - 1].updates.append(update)
            } else {
                groups.append(Group(provider: update.provider, updates: [update]))
            }
        }
        return groups
    }

    public func hiddenCount(for provider: ProviderID) -> Int {
        hidden.filter { $0.provider == provider }.count
    }
}

/// What a report was narrowed to, recorded in the report itself so that
/// nobody reading it can mistake part of the list for all of it.
///
/// A `macup check` or `macup plan` document carries one only when `--risk`,
/// `--policy`, `--attention`, or `--sort` was given; without them the
/// document is exactly what it was before these options existed (docs/CLI.md).
public struct ReportFilter: Sendable, Hashable, Codable {
    /// Risk levels kept; empty when risk did not narrow the list.
    public var riskLevels: [RiskLevel]
    /// Policies in effect kept; empty when policy did not narrow the list.
    public var policies: [UpdatePolicy]
    public var needsAttentionOnly: Bool
    /// Providers kept, when the filter named any. Nothing on the command line
    /// sets this: `macup check --provider` decides which providers are
    /// checked at all, so nothing it leaves out was ever found.
    public var providers: [ProviderID]?
    /// Search words, when the filter had any. Nothing on the command line
    /// sets this either.
    public var search: String?
    public var sort: UpdateSortOrder
    /// Entries the filter kept: updates in a check, planned and skipped
    /// items in a plan.
    public var shown: Int
    /// Entries the filter left out. The report's `summary` still counts them.
    public var hidden: Int

    public init(_ filter: UpdateFilter, sort: UpdateSortOrder, shown: Int, hidden: Int) {
        riskLevels = RiskLevel.allCases.filter(filter.riskLevels.contains)
        policies = UpdatePolicy.allCases.filter(filter.policies.contains)
        needsAttentionOnly = filter.needsAttentionOnly
        providers = filter.providers.isEmpty ? nil : filter.providers.sorted()
        search = filter.hasSearch ? filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        self.sort = sort
        self.shown = shown
        self.hidden = hidden
    }

    /// The criteria this report was filtered by.
    public var criteria: UpdateFilter {
        UpdateFilter(
            searchText: search ?? "",
            providers: Set(providers ?? []),
            riskLevels: Set(riskLevels),
            policies: Set(policies),
            needsAttentionOnly: needsAttentionOnly
        )
    }
}

extension PolicyEngine {
    /// The policy in effect for each update, which is what a policy filter
    /// matches against. The same answer ``decide(_:intent:)`` puts in a
    /// decision's `policy`, without judging risk.
    public func effectivePolicies(for updates: [UpdateCandidate]) -> [PackageID: UpdatePolicy] {
        Dictionary(updates.map { ($0.id, effectivePolicy(for: $0.id).policy) }, uniquingKeysWith: { first, _ in first })
    }
}

extension CheckReport {
    /// This report with `updates` narrowed to what `filter` keeps, in
    /// `order`, and ``filter`` saying how many it left out.
    ///
    /// Everything else — the summary, every provider's counts, whether the
    /// check was complete — still describes the whole check, so a filtered
    /// report can never read as a Mac with fewer updates than it has.
    public func filtered(
        _ filter: UpdateFilter,
        sortedBy order: UpdateSortOrder,
        effectivePolicies: [PackageID: UpdatePolicy]
    ) -> CheckReport {
        let listing = filter.apply(to: updates, sortedBy: order, effectivePolicies: effectivePolicies)
        var report = self
        report.updates = listing.shown
        report.filter = ReportFilter(filter, sort: order, shown: listing.shown.count, hidden: listing.hiddenCount)
        return report
    }
}

extension PlanReport {
    /// This plan with `planned` and `skipped` narrowed to what `filter`
    /// keeps, each in `order`, and ``filter`` saying how many entries it
    /// left out. The summary still describes the whole plan, so no decision
    /// in it is ever hidden from the counts.
    ///
    /// A skipped item records the item rather than the update behind it, so
    /// the updates come from the check the plan was built from. An entry
    /// whose update is not among them is kept and listed last: MacUp does not
    /// hide what it cannot judge. The policy matched is the one the plan's
    /// own decision names.
    public func filtered(
        _ filter: UpdateFilter,
        sortedBy order: UpdateSortOrder,
        candidates: [UpdateCandidate]
    ) -> PlanReport {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func keep<Entry>(
            _ entries: [Entry],
            candidate: (Entry) -> UpdateCandidate?,
            policy: (Entry) -> UpdatePolicy?
        ) -> [Entry] {
            var judged: [(entry: Entry, candidate: UpdateCandidate)] = []
            var unjudged: [Entry] = []
            for entry in entries {
                guard let update = candidate(entry) else {
                    unjudged.append(entry)
                    continue
                }
                if filter.matches(update, policy: policy(entry)) { judged.append((entry, update)) }
            }
            return judged.sorted { order.areInIncreasingOrder($0.candidate, $1.candidate) }.map(\.entry) + unjudged
        }

        var report = self
        report.planned = keep(planned, candidate: { $0.candidate }, policy: { $0.decision.policy })
        report.skipped = keep(skipped, candidate: { byID[$0.item] }, policy: { $0.decision?.policy })
        let shown = report.planned.count + report.skipped.count
        report.filter = ReportFilter(
            filter,
            sort: order,
            shown: shown,
            hidden: planned.count + skipped.count - shown
        )
        return report
    }
}
