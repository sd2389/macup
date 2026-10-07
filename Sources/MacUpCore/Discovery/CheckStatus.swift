/// One summary of the latest check for glanceable places (the menu bar, a
/// headline). It never claims more than MacUp knows: "up to date" only for a
/// finished check in which every provider succeeded and nothing was left out.
public enum CheckStatus: Sendable, Hashable {
    case notChecked
    case checking
    case upToDate
    case updatesAvailable(Int)
    /// The check did not see everything; `updates` counts what it did find.
    case incomplete(updates: Int, reasons: [String])

    public init(report: CheckReport?, isChecking: Bool, environmentProblem: String? = nil) {
        if isChecking {
            self = .checking
            return
        }
        guard let report else {
            self = .notChecked
            return
        }
        var reasons: [String] = []
        if report.cancelled {
            reasons.append("The last check was cancelled before it finished.")
        }
        for provider in report.providers where provider.hasErrors {
            reasons.append("\(provider.displayName) could not be checked.")
        }
        for provider in report.providers where !provider.hasErrors && provider.resultsIncomplete {
            reasons.append(provider.unreadableUpdates > 0
                ? "\(provider.displayName) listed \(TextCount.plural(provider.unreadableUpdates, "update")) MacUp could not read."
                : "\(provider.displayName) may be missing results.")
        }
        if environmentProblem != nil {
            reasons.append("Your shell environment could not be read, so some tools may not have been found.")
        }
        let updates = report.summary.updatesAvailable
        if !reasons.isEmpty {
            self = .incomplete(updates: updates, reasons: reasons)
        } else if updates > 0 {
            self = .updatesAvailable(updates)
        } else {
            self = .upToDate
        }
    }

    public var headline: String {
        switch self {
        case .notChecked: "Not checked yet"
        case .checking: "Checking…"
        case .upToDate: "Everything is up to date"
        case .updatesAvailable(let count): TextCount.plural(count, "update") + " available"
        case .incomplete(0, _): "Check incomplete"
        case .incomplete(let count, _): TextCount.plural(count, "update") + " found; check incomplete"
        }
    }

    /// An SF Symbol name. Never the success checkmark unless the check is complete.
    public var symbolName: String {
        switch self {
        case .notChecked: "circle.dashed"
        case .checking: "arrow.triangle.2.circlepath"
        case .upToDate: "checkmark.circle"
        case .updatesAvailable: "arrow.down.circle"
        case .incomplete: "exclamationmark.triangle"
        }
    }

    public var reasons: [String] {
        if case .incomplete(_, let reasons) = self { return reasons }
        return []
    }
}
