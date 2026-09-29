import Foundation
import MacUpCore

/// Human-readable output for `macup plan`.
///
/// A plan is the review MacUp asks to be read before anything runs, so it
/// shows the exact executable and arguments for every change, the policy that
/// let each one in, and the reason behind every item it would leave alone
/// (CLAUDE.md §11). Nothing here is softened: an item that needs confirmation
/// says so on its own line rather than only in the summary.
struct PlanRenderer {
    /// Why this plan is on screen. The table is the same either way; what
    /// differs is the promise the heading and the footer make about what
    /// happens next.
    enum Purpose {
        /// `macup plan`, which stops here.
        case review
        /// `macup update --dry-run`, which will launch nothing.
        case dryRun
        /// The plan `macup update` is about to act on.
        case beforeRunning
    }

    let report: PlanReport
    let style: TextStyle
    let verbose: Bool
    var purpose = Purpose.review

    func render() -> String {
        var lines = [style.bold(heading) + style.dim(" · " + subtitle)]
        if report.cancelled {
            lines.append("Cancelled before the check behind this plan finished; it may be incomplete.")
        }
        if let filter = FilterText.heading(report.filter) {
            lines.append(filter)
        }
        if let configuration = report.configuration, !configuration.valid {
            lines.append("")
            lines.append("Configuration \(style.path(configuration.path)) has errors, so MacUp will change nothing "
                + "until they are fixed. Run `macup config show` for details.")
        }

        let order = report.filter?.sort ?? .provider
        if order != .provider {
            // One list in the order asked for, rather than one per provider.
            if !report.planned.isEmpty {
                lines.append("")
                lines.append(style.bold("Changes") + style.dim(" · " + FilterText.sortedHeading(order)))
                lines += PlanTable(items: report.planned, style: style, verbose: verbose).renderLines()
            }
        } else {
            for provider in ProviderID.known + otherProviders {
                let planned = report.planned(for: provider)
                guard !planned.isEmpty else { continue }
                lines.append("")
                lines.append(style.bold(provider.displayName))
                lines += PlanTable(items: planned, style: style, verbose: verbose).renderLines()
            }
        }

        if !report.skipped.isEmpty {
            lines.append("")
            lines.append(style.bold("Not changing") + style.dim(" · " + TextStyle.plural(report.skipped.count, "item")))
            lines += SkipTable(items: report.skipped, style: style, verbose: verbose).renderLines()
        }

        lines.append("")
        lines += summary()
        return lines.joined(separator: "\n")
    }

    private var heading: String {
        switch purpose {
        case .review: "MacUp plan"
        case .dryRun: "MacUp update · dry run"
        case .beforeRunning: "MacUp update"
        }
    }

    private var subtitle: String {
        switch purpose {
        case .review: "read-only · nothing has been changed"
        case .dryRun: "nothing will be launched"
        case .beforeRunning: "what MacUp is about to do"
        }
    }

    /// Providers the plan mentions that this version of MacUp does not know
    /// about, so a plan never hides an item because its provider is unfamiliar.
    private var otherProviders: [ProviderID] {
        let known = Set(ProviderID.known)
        return Set(report.planned.map(\.provider)).subtracting(known).sorted()
    }

    private func summary() -> [String] {
        var lines: [String] = []
        let summary = report.summary
        // A plan the filter emptied is not a plan with nothing in it.
        if report.planned.isEmpty && report.skipped.isEmpty && (report.filter?.hidden ?? 0) == 0 {
            lines.append(style.bold("No updates to plan."))
            lines.append("Nothing was changed. `macup check` shows what MacUp looked at.")
            return lines
        }

        // The counts are the whole plan's, whatever the filter shows, so no
        // decision in it is ever left out of them.
        var parts: [String] = []
        if summary.allowed > 0 { parts.append(TextStyle.plural(summary.allowed, "change") + " ready to run") }
        if summary.needsConfirmation > 0 {
            parts.append(TextStyle.plural(summary.needsConfirmation, "change")
                + (summary.needsConfirmation == 1 ? " needs" : " need") + " your confirmation")
        }
        if summary.deniedByPolicy > 0 { parts.append(TextStyle.plural(summary.deniedByPolicy, "item") + " left alone by policy") }
        if summary.unplannable > 0 { parts.append(TextStyle.plural(summary.unplannable, "item") + " MacUp cannot plan") }
        lines.append(style.bold(parts.isEmpty ? "Nothing to change." : parts.joined(separator: " · ") + "."))
        if let hidden = FilterText.hidden(report.filter, command: "macup plan") {
            lines.append(hidden)
        }

        let failedProviders = report.providers.filter { !$0.errors.isEmpty }
        if !failedProviders.isEmpty {
            lines.append("\(TextStyle.plural(failedProviders.count, "provider")) reported errors, so this plan may be "
                + "missing updates. Run `macup check --verbose` to see them.")
        }
        // Only a review promises what happens next; inside `macup update`
        // the answer is on the lines that follow this one.
        if purpose == .review {
            lines.append("Nothing has been changed. `macup update` runs this plan; `macup update --dry-run` shows it "
                + "again without running anything.")
            if summary.needsConfirmation > 0 {
                lines.append(style.dim("MacUp asks before it runs the items marked \"needs your confirmation\"."))
            }
        }
        return lines
    }
}

/// The rows for planned updates: what would change, and exactly how.
struct PlanTable {
    let items: [PlannedUpdate]
    let style: TextStyle
    let verbose: Bool

    func renderLines() -> [String] {
        let ids = items.map { style.safe($0.item.rawValue) }
        let versions = items.map { PlanText.versions($0.plan, style: style) }
        let idWidth = ids.map(\.count).max() ?? 0
        let riskWidth = items.map(\.plan.risk.level.displayName.count).max() ?? 0
        let versionWidth = versions.map(\.count).max() ?? 0

        var lines: [String] = []
        for (index, planned) in items.enumerated() {
            lines.append("  " + TextStyle.pad(ids[index], to: idWidth)
                + "  " + TextStyle.pad(versions[index], to: versionWidth)
                + "  " + PlanText.risk(planned.plan.risk.level, width: riskWidth, style: style)
                + "  " + style.text(PlanText.decision(planned)))
            if planned.needsConfirmation || verbose {
                lines.append("      " + style.dim("Why: " + style.text(planned.decision.reason)))
            }
            if let note = planned.decision.note {
                lines.append("      " + style.dim("Note: " + style.safe(note)))
            }
            if verbose {
                lines.append("      " + style.dim(style.text(planned.plan.rationale)))
            }
            for reason in verbose ? planned.plan.risk.reasons : Array(planned.plan.risk.reasons.prefix(highRisk(planned) ? 1 : 0)) {
                lines.append("      " + style.dim("Risk: " + style.text(reason)))
            }
            for step in planned.plan.steps {
                lines.append("      " + style.dim("Runs: ") + style.path(step.invocation.displayString))
            }
            let effects = PlanText.effects(planned.plan, verbose: verbose)
            if !effects.isEmpty {
                lines.append("      " + style.dim(effects.joined(separator: " · ")))
            }
            if verbose {
                for step in planned.plan.verification {
                    lines.append("      " + style.dim("Confirms afterwards: " + style.text(step.summary)))
                }
                lines.append("      " + style.dim("Undo: " + style.text(planned.plan.rollback.explanation)))
            }
        }
        return lines
    }

    private func highRisk(_ planned: PlannedUpdate) -> Bool {
        planned.plan.risk.level == .high || planned.plan.risk.level == .unknown
    }
}

/// The rows for items MacUp would not change, with the reason on every one.
struct SkipTable {
    let items: [SkippedUpdate]
    let style: TextStyle
    let verbose: Bool

    func renderLines() -> [String] {
        let ids = items.map { style.safe($0.item.rawValue) }
        let versions = items.map { PlanText.versions($0, style: style) }
        let idWidth = ids.map(\.count).max() ?? 0
        let versionWidth = versions.map(\.count).max() ?? 0
        var lines: [String] = []
        for (index, skipped) in items.enumerated() {
            // A reason can be several lines — a dry run's reason is the
            // commands it would have run — so only the first shares the row.
            let reason = style.text(skipped.reason).split(separator: "\n", omittingEmptySubsequences: false)
            lines.append("  " + TextStyle.pad(ids[index], to: idWidth)
                + "  " + TextStyle.pad(versions[index], to: versionWidth)
                + "  " + (reason.first.map(String.init) ?? ""))
            lines += reason.dropFirst().map { "      " + style.dim(String($0)) }
            if let note = skipped.decision?.note {
                lines.append("      " + style.dim("Note: " + style.safe(note)))
            }
            if let error = skipped.error, verbose {
                if let detail = error.detail {
                    lines += detail.split(separator: "\n").prefix(6).map { "      " + style.dim(style.text(String($0))) }
                }
                if let suggestion = error.recoverySuggestion {
                    lines.append("      " + style.dim(style.text(suggestion)))
                }
            }
        }
        return lines
    }
}

/// Wording shared by the plan, the dry run, and the result of an update, so
/// the same fact is never described two different ways.
enum PlanText {
    /// A risk label padded to a column width. Padding is measured from the
    /// words, not from the styled string, because ANSI codes have a length
    /// but no width on screen.
    static func risk(_ level: RiskLevel, width: Int, style: TextStyle) -> String {
        let padding = max(0, width - level.displayName.count)
        return style.risk(level) + String(repeating: " ", count: padding)
    }

    static func versions(_ plan: ExecutionPlan, style: TextStyle) -> String {
        versions(current: plan.currentVersion?.raw, proposed: plan.proposedVersion.raw, style: style)
    }

    static func versions(_ skipped: SkippedUpdate, style: TextStyle) -> String {
        versions(current: skipped.currentVersion, proposed: skipped.proposedVersion, style: style)
    }

    static func versions(current: String?, proposed: String?, style: TextStyle) -> String {
        let from = style.safe(current ?? "unknown")
        guard let proposed else { return from }
        return from + " → " + style.safe(proposed)
    }

    /// The effective policy and what it means for this item. Worded in
    /// MacUpCore, which `macup explain` and the app share.
    static func decision(_ planned: PlannedUpdate) -> String {
        planned.decision.actionSummary
    }

    /// What a change would touch beyond the package itself. Only the notable
    /// ones by default; a verbose plan states every field, including the
    /// reassuring ones, because CLAUDE.md §11 requires the plan to carry them.
    static func effects(_ plan: ExecutionPlan, verbose: Bool) -> [String] {
        plan.effectSummaries(includingReassuring: verbose)
    }
}
