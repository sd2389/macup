import AppKit
import MacUpCore
import SwiftUI

/// Everything an uninstall would do, for someone to choose from before
/// anything happens: how the files go (at the top, chosen each time), what the
/// package manager runs, every file with its size and whether it is included,
/// and what only they can remove. Then what it did.
struct UninstallReviewSheet: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirming = false

    var body: some View {
        @Bindable var state = model.uninstaller
        VStack(spacing: 0) {
            header
            // First, as the owner asked: how the files go is chosen before
            // what goes, and it starts at the Trash every time.
            VStack(alignment: .leading, spacing: 6) {
                Picker("How to remove", selection: $state.mode) {
                    Text(RemovalMode.trash.displayName).tag(RemovalMode.trash)
                    Text(RemovalMode.delete.displayName).tag(RemovalMode.delete)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(state.isRunning || state.report != nil)
                .accessibilityLabel("How to remove the files")
                Text(state.mode == .trash
                    ? "Everything goes to the Trash, so you can put it back until you empty it."
                    : "Everything is deleted straight away. This cannot be undone.")
                    .font(.callout)
                    .foregroundStyle(state.mode == .delete ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            Form {
                if let problem = state.problem {
                    Section {
                        Label(problem.displaySafe, systemImage: "xmark.octagon")
                        Text("Nothing was removed.").foregroundStyle(.secondary)
                    }
                }
                if let report = state.report {
                    UninstallResultSections(report: report, rollback: state.plan?.rollback(for: report.mode))
                } else if let plan = state.plan {
                    if state.isRunning { runningSection }
                    UninstallPlanSections(plan: plan)
                } else {
                    Section { ProgressView("Working out what to remove…") }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 700)
        .confirmationDialog(confirmationTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(model.uninstaller.mode == .delete ? "Delete Permanently" : "Move to Trash",
                   role: model.uninstaller.mode == .delete ? .destructive : nil) {
                model.runUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let state = model.uninstaller
        guard let plan = state.plan else { return "Uninstall" }
        let name = plan.subject.name.displaySafe
        if let report = state.report {
            switch report.outcome {
            case .uninstalled: return plan.subject.kind == .macUp ? "MacUp is removed" : "Uninstalled \(name)"
            case .incomplete: return "Uninstalled \(name), but not everything"
            case .failed: return "Could not uninstall \(name)"
            case .refused: return "Did not uninstall \(name)"
            case .cancelled: return "Stopped"
            }
        }
        if state.isRunning { return "Uninstalling \(name)" }
        return plan.subject.kind == .macUp ? "Remove MacUp" : "Uninstall \(name)"
    }

    private var subtitle: String {
        let state = model.uninstaller
        if state.report != nil { return "Everything below is in History too." }
        guard let plan = state.plan else { return "Nothing has been removed." }
        if !plan.canRun { return "MacUp will not uninstall this now. Nothing has been removed." }
        return "Nothing is removed until you confirm. What belongs to it is ticked; your data is not."
    }

    private var runningSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(model.uninstaller.progressLine?.displaySafe ?? "Starting…")
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var footer: some View {
        let state = model.uninstaller
        let totals = model.uninstallTotals
        return HStack {
            if let totals, state.report == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totals.count) \(totals.count == 1 ? "item" : "items"), \(UninstallSizeText.text(totals.bytes, partial: totals.bytesArePartial))")
                        .monospacedDigit()
                    if totals.keptCount > 0 {
                        Text("\(totals.keptCount) left in place, \(UninstallSizeText.text(totals.keptBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer()
            if state.isRunning {
                Button("Stop After This File") { model.stopUninstall() }
                    .help("Remove nothing more. What was already removed is reported.")
            } else if let report = state.report {
                if report.subject.kind == .macUp && report.outcome == .uninstalled {
                    Button("Quit MacUp") { NSApp.terminate(nil) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Done") { model.endUninstallReview() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Button("Cancel") { model.endUninstallReview() }
                    .keyboardShortcut(.cancelAction)
                Button(state.plan?.subject.kind == .macUp ? "Remove MacUp…" : "Uninstall…") { isConfirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(state.plan?.canRun != true || state.isPlanning)
                    .help(state.plan?.canRun == false
                        ? "MacUp will not uninstall this now; the reason is above."
                        : "Asks once more before anything is removed.")
            }
        }
        .padding(20)
    }

    private var confirmationTitle: String {
        guard let totals = model.uninstallTotals, let plan = model.uninstaller.plan else { return "Uninstall?" }
        let count = "\(totals.count) \(totals.count == 1 ? "item" : "items")"
        let size = UninstallSizeText.text(totals.bytes, partial: totals.bytesArePartial)
        return model.uninstaller.mode == .delete
            ? "Delete \(count) (\(size)) permanently?"
            : "Uninstall \(plan.subject.name.displaySafe) and move \(count) (\(size)) to the Trash?"
    }

    private var confirmationMessage: String {
        model.uninstaller.mode == .delete
            ? "This cannot be undone. Nothing you left unticked is touched."
            : "You can put them back from the Trash until you empty it. Nothing you left unticked is touched."
    }
}

/// The plan: what stops it, what runs, what goes, and what only you can do.
private struct UninstallPlanSections: View {
    @Environment(AppModel.self) private var model
    let plan: UninstallPlan

    var body: some View {
        if !plan.blockers.isEmpty {
            Section {
                ForEach(Array(plan.blockers.enumerated()), id: \.offset) { _, blocker in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(blocker.message.displaySafe, systemImage: "hand.raised")
                        if let dependents = blocker.dependents, !dependents.isEmpty {
                            Text("Needed by: " + dependents.map { $0.rawValue.displaySafe }.joined(separator: ", "))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(blocker.steps.enumerated()), id: \.offset) { _, step in
                            Text(step.displaySafe).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("MacUp Will Not Uninstall This Now")
            }
        }

        if !plan.steps.isEmpty {
            Section {
                ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.invocation.displayString.displayPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                        Text(step.summary.displaySafe).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("\(plan.runner?.displayName ?? "The Package Manager") Will Run")
            }
        }

        if !plan.actions.isEmpty {
            Section("MacUp Will Also") {
                ForEach(plan.actions) { action in Text(action.summary.displaySafe) }
            }
        }

        if !plan.removals.isEmpty {
            Section {
                HStack {
                    Button("Select Everything") { model.selectEverythingForUninstall() }
                        .help("Tick everything MacUp can remove, your data included: nothing left behind.")
                    Button("Only What Belongs to It") { model.selectDefaultsForUninstall() }
                        .help("Tick only what clearly belongs to it, and leave your data in place.")
                }
                .disabled(model.uninstaller.isRunning)
            } footer: {
                Text("Select Everything leaves nothing behind, including your data. What only you can remove is listed further down.")
                    .leadingFooter()
            }
            ForEach(LeftoverCategory.allCases, id: \.self) { category in
                let group = plan.removals.filter { $0.category == category }
                if !group.isEmpty {
                    Section {
                        ForEach(group) { removal in UninstallRemovalRow(removal: removal) }
                    } header: {
                        Text(category.title)
                    } footer: {
                        if let note = category.note {
                            Text(note).leadingFooter()
                        }
                    }
                }
            }
        }

        // The maker's own remover, when it left one: the one thing in this
        // sheet that removes the whole app properly.
        if let vendor = plan.vendorUninstaller {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vendor.path.displayPath).font(.callout.monospaced()).textSelection(.enabled)
                    Text(vendor.summary.displaySafe).font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(vendor.steps.enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step.displaySafe)").font(.callout).textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("This App Ships Its Own Uninstaller")
            } footer: {
                Text("MacUp does not run it: what it removes would not be in this plan or in MacUp's history.")
                    .leadingFooter()
            }
        }

        if !plan.cannotRemove.isEmpty {
            Section {
                ForEach(plan.cannotRemove) { manual in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manual.path.displayPath).font(.callout.monospaced()).textSelection(.enabled)
                        Text(manual.reason.displaySafe).font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(manual.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step.displaySafe)").font(.callout).textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if plan.cannotRemove.contains(where: { !$0.commands.isEmpty }) {
                    AdminScriptRow()
                }
            } header: {
                Text("MacUp Cannot Remove These")
            } footer: {
                Text("MacUp never asks for an administrator's password. These are the steps to remove them yourself.")
                    .leadingFooter()
            }
        }

        if !plan.warnings.isEmpty {
            Section {
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning.displaySafe, systemImage: "info.circle")
                }
            }
        }
    }
}

private struct UninstallRemovalRow: View {
    @Environment(AppModel.self) private var model
    let removal: PlannedRemoval

    var body: some View {
        Toggle(isOn: Binding(
            get: { removal.isRequired || model.isIncludedInUninstall(removal.path) },
            set: { model.setIncludedInUninstall($0, path: removal.path) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(removal.path.displayPath)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(UninstallSizeText.text(removal.sizeBytes, partial: removal.sizeIsPartial)
                    + (removal.isRequired ? " · always removed" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = removal.warning {
                    Text(warning.displaySafe).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .disabled(removal.isRequired || model.uninstaller.isRunning)
        .accessibilityLabel("\(removal.path.displayPath), \(UninstallSizeText.text(removal.sizeBytes))")
        .help(removal.reason.displaySafe)
    }
}

/// What the uninstall did.
private struct UninstallResultSections: View {
    let report: UninstallReport
    let rollback: RollbackCapability?

    var body: some View {
        let removed = report.removals.filter { $0.status == .removed }
        let problems = report.removals.filter { $0.status == .skipped || $0.status == .failed }
        if !report.refusals.isEmpty {
            Section("Why Nothing Was Removed") {
                ForEach(report.refusals, id: \.self) { Text($0.displaySafe) }
            }
        }
        if !report.commands.isEmpty || !report.actions.isEmpty {
            Section("What Ran") {
                ForEach(Array(report.commands.enumerated()), id: \.offset) { _, command in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(command.command.displayPath).font(.callout.monospaced()).textSelection(.enabled)
                        Text(command.exitStatus.map { "Exit status \($0)" } ?? "Did not finish")
                            .font(.caption).foregroundStyle(.secondary)
                        if let excerpt = command.errorExcerpt {
                            Text(excerpt.displaySafe).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(Array(report.actions.enumerated()), id: \.offset) { _, action in
                    Label(action.message.displaySafe, systemImage: action.succeeded ? "checkmark.circle" : "xmark.circle")
                }
            }
        }
        if !removed.isEmpty {
            Section(report.mode == .delete ? "Deleted Permanently" : "Moved to the Trash") {
                ForEach(removed, id: \.path) { outcome in
                    Text(outcome.path.displayPath).font(.callout).textSelection(.enabled)
                }
            }
        }
        if !problems.isEmpty {
            Section("Not Removed") {
                ForEach(problems, id: \.path) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.path.displayPath).font(.callout)
                        Text((outcome.reason ?? outcome.status.rawValue).displaySafe).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !report.kept.isEmpty {
            Section("Left in Place, as You Chose") {
                ForEach(report.kept, id: \.path) { kept in
                    Text(kept.path.displayPath).font(.callout)
                }
            }
        }
        if !report.checks.isEmpty {
            Section("Checked Afterwards") {
                ForEach(Array(report.checks.enumerated()), id: \.offset) { _, check in
                    Label(check.summary.displaySafe,
                          systemImage: check.passed == true ? "checkmark.circle" : check.passed == false ? "xmark.circle" : "questionmark.circle")
                }
            }
        }
        if let error = report.error {
            Section { Label(error.message.displaySafe, systemImage: "exclamationmark.triangle") }
        }
        if let rollback, report.outcome != .refused {
            Section { Text(rollback.explanation.displaySafe).foregroundStyle(.secondary) }
        }
    }
}

/// The way out of the dead end: MacUp writes the administrator-only part of
/// the plan as a script, shows it, and leaves the running to the person.
///
/// Nothing here escalates. MacUp writes one file of its own, puts a command
/// on the clipboard, and can open Terminal — `sudo` asks for the password
/// there, and MacUp never sees it, stores it, or runs as root
/// (docs/TRUST_AND_SECURITY.md, "Privilege").
private struct AdminScriptRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let script = model.uninstaller.adminScript {
                Text("MacUp wrote these as one script, \(script.items.count == 1 ? "1 item" : "\(script.items.count) items"):")
                    .font(.callout)
                Text(script.path.displayPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("Read it first. Running it removes those items permanently — root does not use the Trash.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(script.command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Review Script…") { model.uninstaller.isReadingAdminScript = true }
                    Button("Copy Command") { model.copyAdminScriptCommand() }
                    Button("Show in Finder") { model.revealAdminScript() }
                    Button("Open Terminal") { model.openTerminalForAdminScript() }
                        .help("Opens Terminal with the command copied. sudo asks you for your password; MacUp never sees it.")
                }
                if !script.refused.isEmpty {
                    Text("Not in the script, so the steps above are the only way for \(script.refused.count == 1 ? "1 item" : "\(script.refused.count) items").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("MacUp can write these as one script you read and then run with sudo. It never asks for your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Write Administrator Script…") { model.writeAdminScript() }
            }
            if let problem = model.uninstaller.adminScriptProblem {
                Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: Binding(
            get: { model.uninstaller.isReadingAdminScript },
            set: { model.uninstaller.isReadingAdminScript = $0 }
        )) {
            AdminScriptReader(text: model.uninstaller.adminScript?.text ?? "")
        }
    }
}

/// The script itself, to read before running it. Text only: this window has
/// no button that runs anything.
private struct AdminScriptReader: View {
    @Environment(\.dismiss) private var dismiss
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Administrator Script").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(minWidth: 620, minHeight: 480)
    }
}
