import ArgumentParser
import MacUpCore

extension RiskLevel: ExpressibleByArgument {}
extension UpdateSortOrder: ExpressibleByArgument {}

/// `--risk`, `--policy`, `--attention`, and `--sort`, shared by `macup check`
/// and `macup plan` so both narrow and order a list the same way, through
/// ``UpdateFilter`` in MacUpCore, as the app's Updates screen does.
///
/// A filter changes what is printed, never what MacUp found: the counts in
/// the output still describe everything, and the output always says how many
/// updates the filter left out.
struct UpdateListOptions: ParsableArguments {
    /// The policies a filter can match. Not ``UpdatePolicy`` itself, because
    /// `inherit` is a way of writing a rule, never the policy in effect, so a
    /// filter on it could only ever hide everything.
    enum PolicyInEffect: String, CaseIterable, ExpressibleByArgument {
        case auto, ask, ignore, pin

        var policy: UpdatePolicy {
            switch self {
            case .auto: .auto
            case .ask: .ask
            case .ignore: .ignore
            case .pin: .pin
            }
        }
    }

    @Option(name: .customLong("risk"), help: "Only updates of this risk. Repeatable.")
    var riskLevels: [RiskLevel] = []

    @Option(name: .customLong("policy"), help: "Only updates whose policy in effect is this. Repeatable.")
    var policies: [PolicyInEffect] = []

    @Flag(
        name: .customLong("attention"),
        help: "Only updates that need a closer look: an earlier install that did not finish, or a build from source."
    )
    var needsAttentionOnly = false

    @Option(help: "Order the list by provider (the default), by risk (highest first), by name, or by size of version change (largest first).")
    var sort: UpdateSortOrder?

    /// Whether any of these options was given. Without them a command's
    /// output, human or JSON, is exactly what it was before they existed.
    var isRequested: Bool {
        !riskLevels.isEmpty || !policies.isEmpty || needsAttentionOnly || sort != nil
    }

    var filter: UpdateFilter {
        UpdateFilter(
            riskLevels: Set(riskLevels),
            policies: Set(policies.map(\.policy)),
            needsAttentionOnly: needsAttentionOnly
        )
    }

    /// The check as it should be printed. Policy is resolved from the same
    /// configuration the check ran under, exactly as a plan would resolve it.
    func apply(to report: CheckReport, configuration: LoadedConfiguration) -> CheckReport {
        guard isRequested else { return report }
        return report.filtered(
            filter,
            sortedBy: sort ?? .provider,
            effectivePolicies: PolicyEngine(configuration).effectivePolicies(for: report.updates)
        )
    }

    /// The plan as it should be printed. `candidates` are the updates the
    /// check behind the plan found.
    func apply(to plan: PlanReport, candidates: [UpdateCandidate]) -> PlanReport {
        guard isRequested else { return plan }
        return plan.filtered(filter, sortedBy: sort ?? .provider, candidates: candidates)
    }
}

/// What a filtered list says about its filter, shared by `macup check` and
/// `macup plan` so the two word it the same way.
enum FilterText {
    /// The line under a command's heading: what the list is narrowed to and
    /// how it is ordered. Nil when the report was not filtered.
    static func heading(_ filter: ReportFilter?) -> String? {
        guard let filter else { return nil }
        var sentences: [String] = []
        let criteria = filter.criteria.summary
        if !criteria.isEmpty { sentences.append("Filter: \(TerminalText.sanitize(criteria)).") }
        if filter.sort != .provider { sentences.append("Sorted by \(filter.sort.displayName.lowercased()).") }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// How many entries the filter hid and how to see them all. Nil when
    /// nothing narrowed the list, or there was nothing to narrow.
    static func hidden(_ filter: ReportFilter?, command: String) -> String? {
        guard let filter, filter.criteria.isActive, filter.shown + filter.hidden > 0 else { return nil }
        guard filter.hidden > 0 else { return "The filter hides none of them." }
        return TextStyle.plural(filter.hidden, "update") + " hidden by the filter. Run `\(command)` without "
            + "--risk, --policy, or --attention to see all \(filter.shown + filter.hidden)."
    }

    /// The heading of a list that is not grouped by provider.
    static func sortedHeading(_ order: UpdateSortOrder) -> String {
        "sorted by " + order.displayName.lowercased()
    }
}
