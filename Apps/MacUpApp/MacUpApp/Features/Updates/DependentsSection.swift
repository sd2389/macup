import MacUpCore
import SwiftUI

/// What Depends on It, in an update's details: the installed software an
/// upgrade of this formula could affect.
///
/// Asked of Homebrew only when someone presses the button, because working
/// the answer out reads the install record of every formula. Shown only for
/// items MacUp can ask about, so there is never a button that can only
/// produce a refusal. The same lookup as `macup dependents`.
struct DependentsSection: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate

    var body: some View {
        if model.canListDependents(of: update.id) {
            Section {
                content
            } header: {
                Text("What Depends on It")
            } footer: {
                Text(footer).leadingFooter()
            }
        }
    }

    private var name: String { update.displayName.displaySafe }

    @ViewBuilder
    private var content: some View {
        let lookup = model.dependents
        if lookup.runningItem == update.id {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking Homebrew what needs \(name)…")
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelDependents() }
                    .help("Stop asking. Nothing is changed either way.")
            }
        } else {
            if let report = lookup.reports[update.id] {
                answer(report)
            }
            Button(lookup.reports[update.id]?.outcome == .listed ? "Ask Again" : "Show What Depends on It") {
                model.showDependents(of: update.id)
            }
            .disabled(lookup.runningItem != nil)
            .help(lookup.runningItem == nil
                ? "Ask Homebrew which installed formulae and casks need \(update.displayName). It reads; it changes nothing."
                : "MacUp is already asking about another item.")
        }
    }

    @ViewBuilder
    private func answer(_ report: DependentsReport) -> some View {
        switch report.outcome {
        case .listed:
            let dependents = report.dependents ?? []
            if dependents.isEmpty {
                Label("Nothing installed with Homebrew needs \(name).", systemImage: "checkmark.circle")
            } else {
                Text(dependents.count == 1
                    ? "1 installed item needs \(name), directly or through another formula:"
                    : "\(dependents.count) installed items need \(name), directly or through another formula:")
                ForEach(dependents, id: \.self) { dependent in
                    LabeledContent(dependent.name.displaySafe) {
                        Text(dependent.namespace == .brewCask ? "Cask" : "Formula").foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
                Text(dependents.count == 1
                    ? "When MacUp upgrades \(name), it asks Homebrew to leave this one alone rather than upgrade or rebuild it. It uses the new \(name) the next time it starts."
                    : "When MacUp upgrades \(name), it asks Homebrew to leave these alone rather than upgrade or rebuild them. They use the new \(name) the next time they start.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if report.resultsIncomplete {
                Label("Homebrew also named something MacUp could not read, so this list may be missing it.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        case .cancelled:
            Label("Stopped before Homebrew answered, so MacUp cannot say what needs \(name).", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .unsupported, .notInstalled, .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    (report.error?.message ?? "MacUp could not find out what depends on \(update.displayName).").displaySafe,
                    systemImage: "exclamationmark.triangle"
                )
                if let detail = report.error?.detail {
                    Text(detail.displayLines).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                if let suggestion = report.error?.recoverySuggestion {
                    Text(suggestion.displaySafe).font(.callout).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        if let report = model.dependents.reports[update.id], report.outcome == .listed {
            return "Homebrew's answer at \(report.finishedAt.formatted(date: .omitted, time: .shortened)), from the install records of what is installed. Asking reads; it changes nothing."
        }
        return "Working this out takes Homebrew a moment, so MacUp asks only when you do. Asking reads; it changes nothing."
    }
}
