import Foundation
import MacUpCore

/// The human form of `macup uninstall` and `macup self-uninstall`: what can
/// be uninstalled, what an uninstall would remove, and what it did.
///
/// Every path, name, and version is provider or file-system output, so it goes
/// through ``TextStyle/safe(_:)`` or ``TextStyle/path(_:)`` before it reaches
/// the terminal.
struct UninstallRenderer {
    let style: TextStyle

    // MARK: What can be uninstalled

    func catalog(_ catalog: UninstallCatalog) -> String {
        var lines = [style.bold("MacUp uninstall") + style.dim(" · read-only · nothing was removed"), ""]

        lines.append(style.bold("Apps") + style.dim(" · \(catalog.apps.count)"))
        if catalog.apps.isEmpty { lines.append("  " + style.dim("None found.")) }
        let names = catalog.apps.map { style.safe($0.name) }
        let width = min(names.map(\.count).max() ?? 0, 40)
        for (index, app) in catalog.apps.enumerated() {
            var facts = [app.version.map { style.safe($0) }, app.source.displayName].compactMap { $0 }
            if !app.removability.isRemovable { facts.append(app.removability.reason.map { style.text($0) } ?? "not removable") }
            lines.append("  " + TextStyle.pad(names[index], to: width) + "  " + style.dim(facts.joined(separator: " · ")))
        }

        for provider in [ProviderID.homebrew, .npm, .mise] {
            let packages = catalog.packages(of: provider)
            lines.append("")
            lines.append(style.bold(provider.displayName) + style.dim(" · \(packages.count)"))
            if let state = catalog.state(of: provider), let message = state.message, packages.isEmpty {
                lines.append("  " + style.dim(style.text(message)))
            }
            let targets = packages.map { style.safe($0.target) }
            let targetWidth = min(targets.map(\.count).max() ?? 0, 48)
            for (index, package) in packages.enumerated() {
                let facts = [package.version.map { style.safe($0) }, package.kind.displayName, package.note.map { style.text($0) }]
                    .compactMap { $0 }
                lines.append("  " + TextStyle.pad(targets[index], to: targetWidth) + "  " + style.dim(facts.joined(separator: " · ")))
            }
        }

        if !catalog.manualInstalls.isEmpty {
            lines.append("")
            lines.append(style.bold("Needs you, not MacUp"))
            for install in catalog.manualInstalls {
                lines.append("  " + style.safe(install.name) + style.dim(" · " + style.path(install.path)))
                lines.append("      " + style.text(install.reason))
                lines += install.steps.map { "      " + style.text($0) }
            }
        }
        lines.append("")
        lines.append(style.dim("`macup uninstall <name or package ID> --dry-run` shows what an uninstall would remove."))
        return lines.joined(separator: "\n")
    }

    // MARK: What an uninstall would do

    func plan(_ plan: UninstallPlan, selection: UninstallSelection, dryRun: Bool) -> String {
        var lines = [
            style.bold(plan.subject.kind == .macUp ? "MacUp self-uninstall" : "MacUp uninstall")
                + style.dim(dryRun ? " · dry run · nothing will be removed" : " · review · nothing has been removed yet"),
            "",
        ]
        let subject = plan.subject
        let heading = [style.safe(subject.name), subject.version.map { style.safe($0) }].compactMap { $0 }.joined(separator: " ")
        var described = [subject.kind.displayName]
        if subject.source != subject.kind.displayName { described.append(style.text(subject.source)) }
        lines.append(style.bold(heading) + style.dim(" · " + described.joined(separator: " · ")))
        if let bundle = subject.bundlePath { lines.append("  " + style.path(bundle)) }
        if !plan.rationale.isEmpty { lines.append("  " + style.dim(style.text(plan.rationale))) }

        if !plan.blockers.isEmpty {
            lines.append("")
            lines.append(style.bold("MacUp will not uninstall this now"))
            for blocker in plan.blockers {
                lines.append("  " + style.text(blocker.message))
                if let dependents = blocker.dependents, !dependents.isEmpty {
                    lines.append("      Needed by: " + dependents.map { style.safe($0.rawValue) }.joined(separator: ", "))
                }
                lines += blocker.steps.map { "      " + style.text($0) }
            }
        }

        if !plan.steps.isEmpty {
            lines.append("")
            lines.append(style.bold("\(plan.runner?.displayName ?? "The package manager") will run"))
            for step in plan.steps {
                lines.append("  " + style.path(step.invocation.displayString))
                lines.append("      " + style.dim(style.text(step.summary)))
            }
        }
        if !plan.actions.isEmpty {
            lines.append("")
            lines.append(style.bold("MacUp will also"))
            lines += plan.actions.map { "  " + style.text($0.summary) }
        }

        if !plan.removals.isEmpty {
            lines.append("")
            lines.append(style.bold("Files"))
            for category in LeftoverCategory.allCases {
                let group = plan.removals.filter { $0.category == category }
                guard !group.isEmpty else { continue }
                lines.append("  " + style.bold(category.title))
                if let note = category.note { lines.append("  " + style.dim(note)) }
                for removal in group {
                    let mark = selection.contains(removal.path) || removal.isRequired ? "[x]" : "[ ]"
                    let size = UninstallSizeText.text(removal.sizeBytes, partial: removal.sizeIsPartial)
                    lines.append("    \(mark) " + style.path(removal.path) + style.dim("  " + size))
                    if let warning = removal.warning { lines.append("        " + style.text(warning)) }
                }
            }
        }

        if !plan.cannotRemove.isEmpty {
            lines.append("")
            lines.append(style.bold("MacUp cannot remove these; here is how to do it yourself"))
            for manual in plan.cannotRemove {
                lines.append("  " + style.path(manual.path) + style.dim("  " + style.text(manual.reason)))
                lines += manual.steps.enumerated().map { index, step in "      \(index + 1). " + style.text(step) }
            }
        }

        if !plan.warnings.isEmpty {
            lines.append("")
            lines += plan.warnings.map { style.text("Note: " + $0) }
        }

        let totals = plan.totals(for: selection.paths)
        lines.append("")
        var summary = "Selected: \(TextStyle.plural(totals.count, "item")), "
            + UninstallSizeText.text(totals.bytes, partial: totals.bytesArePartial) + "."
        if totals.keptCount > 0 {
            summary += " Left in place: \(TextStyle.plural(totals.keptCount, "item")), "
                + UninstallSizeText.text(totals.keptBytes) + "."
        }
        lines.append(summary)
        if dryRun {
            lines.append(style.dim(plan.subject.kind == .macUp
                ? "Nothing was removed. Run `macup self-uninstall` without --dry-run to remove MacUp."
                : "Nothing was removed. Add what is left in place with --include <path>, --include-data, "
                    + "or --all, and run without --dry-run to uninstall."))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: What it did

    func report(_ report: UninstallReport, rollback: RollbackCapability?) -> String {
        let name = style.safe(report.subject.name)
        let summary = report.summary
        var lines: [String] = []
        switch report.outcome {
        case .uninstalled:
            lines.append(style.bold("Uninstalled \(name)") + style.dim(" · \(TextStyle.plural(summary.removed, "item")) "
                + report.mode.pastTense + " (" + UninstallSizeText.text(summary.removedBytes) + ")"))
        case .incomplete:
            lines.append(style.bold("Uninstalled \(name), but not everything") + style.dim(" · see below"))
        case .failed:
            lines.append(style.bold("Could not uninstall \(name)"))
        case .refused:
            lines.append(style.bold("Did not uninstall \(name)"))
        case .cancelled:
            lines.append(style.bold("Stopped") + style.dim(" · what was already done is listed below"))
        }
        lines += report.refusals.map { "  " + style.text($0) }

        for command in report.commands {
            let status = command.exitStatus.map { "exit \($0)" } ?? "did not finish"
            lines.append("  Ran: " + style.path(command.command) + style.dim("  " + status))
            if let excerpt = command.errorExcerpt { lines += excerpt.split(separator: "\n").map { "      " + style.text(String($0)) } }
        }
        for action in report.actions {
            lines.append("  " + (action.succeeded ? "Done: " : "Not done: ") + style.text(action.message))
        }

        let removed = report.removals.filter { $0.status == .removed }
        if !removed.isEmpty {
            lines.append("")
            lines.append(report.mode == .delete ? "Deleted permanently:" : "Moved to the Trash:")
            lines += removed.map { "  " + style.path($0.path) }
        }
        let problems = report.removals.filter { $0.status == .skipped || $0.status == .failed }
        if !problems.isEmpty {
            lines.append("")
            lines.append("Not removed:")
            for outcome in problems {
                lines.append("  " + style.path(outcome.path) + style.dim("  " + style.text(outcome.reason ?? outcome.status.rawValue)))
            }
        }
        if !report.kept.isEmpty {
            lines.append("")
            lines.append("Left in place, as you chose:")
            lines += report.kept.map { "  " + style.path($0.path) + style.dim("  " + $0.category.title) }
        }
        if !report.notAttempted.isEmpty {
            lines.append("")
            lines.append("Not attempted:")
            lines += report.notAttempted.map { "  " + style.text($0) }
        }
        if !report.checks.isEmpty {
            lines.append("")
            for check in report.checks {
                let mark = check.passed == true ? "Confirmed: " : check.passed == false ? "Not confirmed: " : "Could not check: "
                lines.append("  " + mark + style.text(check.summary) + (check.detail.map { style.dim(" " + style.text($0)) } ?? ""))
            }
        }
        if let error = report.error {
            lines.append("")
            lines.append("error: " + style.text(error.message))
        }
        if let rollback, report.outcome != .refused {
            lines.append("")
            lines.append(style.dim("Undo: " + style.text(rollback.explanation)))
        }
        lines.append(style.dim("This uninstall is recorded in `macup history`."))
        return lines.joined(separator: "\n")
    }
}
