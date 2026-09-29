import Foundation
import MacUpCore

/// Human-readable output for `macup update`.
///
/// One row per item MacUp attempted, saying what happened and whether MacUp
/// could confirm it afterwards, then every item it left alone with the reason.
/// An update MacUp could not read back is reported as unconfirmed rather than
/// as done, because the field a person checks after an update is worthless if
/// it is generous (CLAUDE.md §25).
struct ExecutionRenderer {
    let report: ExecutionReport
    let style: TextStyle
    let verbose: Bool

    func render() -> String {
        var lines: [String] = []
        if !report.executed.isEmpty {
            lines.append(style.bold("Results"))
            lines += results()
        }
        if !report.skipped.isEmpty {
            lines.append("")
            lines.append(style.bold("Left alone") + style.dim(" · " + TextStyle.plural(report.skipped.count, "item")))
            lines += SkipTable(items: report.skipped, style: style, verbose: verbose).renderLines()
        }
        lines.append("")
        lines += summary()
        return lines.joined(separator: "\n")
    }

    /// What to print after a dry run: the plan was the output, so this only
    /// has to say that nothing ran and how much would have.
    static func dryRunFooter(plan: PlanReport, report: ExecutionReport, style: TextStyle) -> [String] {
        var lines: [String] = []
        let commands = plan.planned.reduce(0) { $0 + $1.plan.steps.count }
        lines.append(style.bold("Nothing was launched.") + " "
            + TextStyle.plural(commands, "command") + " would have run.")

        // A real run re-reads policy immediately before each item, so it can
        // still refuse one the plan allowed. The dry run does the same read,
        // and saying so is more use than a footer that promises the plan.
        let refused = report.skipped.filter { skip in
            skip.decision?.action == .deny && plan.planned.contains { $0.item == skip.item }
        }
        if !refused.isEmpty {
            lines.append("Re-reading your policy changed the answer for "
                + TextStyle.plural(refused.count, "item") + ", which a real run would leave alone:")
            lines += refused.map { "  " + style.safe($0.item.rawValue) + ": " + style.text($0.reason) }
        }
        lines.append("Remove --dry-run to run this plan.")
        return lines
    }

    // MARK: Rows

    private func results() -> [String] {
        let ids = report.executed.map { style.safe($0.item.rawValue) }
        let versions = report.executed.map {
            PlanText.versions(current: $0.plan.currentVersion?.raw, proposed: $0.plan.proposedVersion.raw, style: style)
        }
        let idWidth = ids.map(\.count).max() ?? 0
        let versionWidth = versions.map(\.count).max() ?? 0

        var lines: [String] = []
        for (index, update) in report.executed.enumerated() {
            lines.append("  " + TextStyle.pad(ids[index], to: idWidth)
                + "  " + TextStyle.pad(versions[index], to: versionWidth)
                + "  " + outcome(update))
            lines += detail(update).map { "      " + style.dim($0) }
        }
        return lines
    }

    private func outcome(_ update: ExecutedUpdate) -> String {
        switch update.result.outcome {
        case .succeeded: return "updated" + verification(update)
        case .failed: return "failed"
        case .timedOut: return "timed out"
        case .cancelled: return "cancelled part-way"
        case .skipped: return "not run"
        }
    }

    private func verification(_ update: ExecutedUpdate) -> String {
        guard let verification = update.verification else { return " · not confirmed" }
        switch verification.outcome {
        case .verified:
            return " · confirmed " + style.safe(verification.observedVersion ?? update.plan.proposedVersion.raw)
        case .targetNotReached:
            return " · but " + style.safe(verification.observedVersion ?? "another version")
                + " is installed, not " + style.safe(verification.expectedVersion ?? update.plan.proposedVersion.raw)
        case .failed:
            return " · MacUp could not confirm it"
        case .notPerformed:
            return " · not confirmed"
        }
    }

    private func detail(_ update: ExecutedUpdate) -> [String] {
        var lines: [String] = []
        if let verification = update.verification, verification.outcome != .verified {
            lines.append(style.text(verification.message))
        }
        if let state = update.verification?.observedState {
            lines.append(style.text(state))
        }
        if let error = update.result.error {
            lines.append(style.text(error.message))
            if let suggestion = error.recoverySuggestion {
                lines.append(style.text(suggestion))
            }
        }
        for step in update.result.steps where verbose || step.exitStatus != 0 {
            let status = step.exitStatus.map { "exit status \($0)" } ?? "no exit status"
            lines.append("Ran: " + style.path(step.command) + " (\(status), \(String(format: "%.1fs", step.durationSeconds)))")
            if let excerpt = step.errorExcerpt {
                lines += excerpt.split(separator: "\n").prefix(verbose ? 12 : 4).map { style.text(String($0)) }
            }
        }
        return lines
    }

    // MARK: Summary

    private func summary() -> [String] {
        var lines: [String] = []
        let counts = report.summary
        if counts.attempted == 0 {
            lines.append(style.bold("Nothing was changed."))
        } else {
            var parts = ["\(counts.succeeded) of \(TextStyle.plural(counts.attempted, "item")) updated"]
            if counts.failed > 0 { parts.append("\(counts.failed) failed") }
            if counts.skipped > 0 { parts.append(TextStyle.plural(counts.skipped, "item") + " left alone") }
            lines.append(style.bold(parts.joined(separator: " · ") + "."))
        }

        if counts.unverified > 0 {
            lines.append("\(TextStyle.plural(counts.unverified, "update")) ran but MacUp could not confirm the new "
                + "version. The change may still have worked; MacUp will not say it did.")
        }
        if report.cancelled {
            lines.append("The run was cancelled. Everything above is what MacUp had already done; nothing else was started.")
        }
        if counts.failed > 0 {
            // MacUp reads a failed item back rather than assuming it is as it
            // was: a package manager that stops part-way can leave it changed.
            lines.append("MacUp read each failed item back afterwards; what it found is above, with the provider's own "
                + "output.")
        }
        if counts.attempted > 0 {
            lines.append(style.dim("Recorded in MacUp's history. `macup history` shows it."))
        }
        return lines
    }
}
