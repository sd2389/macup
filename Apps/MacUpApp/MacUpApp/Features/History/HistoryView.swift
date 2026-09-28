import MacUpCore
import SwiftUI

/// What MacUp attempted, newest first, and what came of it.
///
/// History is a trust feature (CLAUDE.md §16), so it shows the attempts that
/// failed and the items MacUp decided to leave alone, with the reason, exactly
/// as it shows the ones that worked. A line the file could not decode is
/// reported rather than quietly dropped.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let reading = model.history
        Group {
            if let problem = model.historyProblem {
                ContentUnavailableView {
                    Label("History Could Not Be Read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.displayPath)
                } actions: {
                    Button("Try Again") { model.loadHistory() }
                }
            } else if let reading, !reading.entries.isEmpty {
                Form {
                    ForEach(reading.findings, id: \.self) { finding in
                        Section {
                            FindingRow(finding: finding)
                        }
                    }
                    Section {
                        ForEach(reading.entries) { entry in
                            HistoryRow(entry: entry)
                        }
                    } header: {
                        Text(reading.entries.count == 1 ? "1 entry" : "\(reading.entries.count) entries")
                    } footer: {
                        Text("Newest first. Nothing here is a secret: commands, versions, and errors are recorded with anything secret-shaped removed.")
                            .leadingFooter()
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label("Nothing Recorded Yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("MacUp has not attempted a change on this Mac. Every attempt it makes — and every item it decides to leave alone — is recorded here.")
                } actions: {
                    Button("Reload") { model.loadHistory() }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.loadHistory()
                } label: {
                    Label("Reload", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Read MacUp's history file again")
            }
        }
        .onAppear { model.loadHistory() }
    }
}

extension ExecutionOrigin {
    var displayName: String {
        switch self {
        case .cli: "Command line"
        case .gui: "MacUp app"
        case .scheduled: "Scheduled check"
        }
    }

    var symbolName: String {
        switch self {
        case .cli: "terminal"
        case .gui: "macwindow"
        case .scheduled: "clock"
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.item.name.displaySafe).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Label(entry.provider.displayName, systemImage: entry.provider.symbolName)
                Label(entry.origin.displayName, systemImage: entry.origin.symbolName)
                if let duration = entry.durationSeconds {
                    Label(
                        "\(duration.formatted(.number.precision(.fractionLength(1)))) s",
                        systemImage: "timer"
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(versions).font(.callout).monospacedDigit()
            OutcomeLabel(outcome: entry.outcome, verification: entry.verification).font(.callout)

            if let reason = entry.skipReason {
                Text(reason.displayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = entry.errorSummary {
                Label(error.displayPath, systemImage: "xmark.octagon")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = entry.command {
                DisclosureGroup("What MacUp ran", isExpanded: $showsCommand) {
                    Text(command.displayPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }

    /// Before, target, and what MacUp found afterwards. The third value is
    /// separate from the second because a run that reached a different version
    /// than the plan asked for is exactly what this row exists to show.
    ///
    /// When there is no third value the row says which kind of nothing it is:
    /// an attempt MacUp could not confirm is not the same as one it never
    /// made, and reading them the same way would flatter the failures.
    private var versions: String {
        let before = entry.versionBefore?.displaySafe ?? "Unknown"
        let target = entry.versionTarget?.displaySafe ?? "Unknown"
        if let after = entry.versionAfter?.displaySafe {
            return "\(before) → \(target) → now \(after)"
        }
        switch entry.outcome {
        case .succeeded: return "\(before) → \(target) (MacUp could not confirm the version afterwards)"
        case .skipped: return "\(before) → \(target) (not attempted)"
        case .failed, .timedOut, .cancelled: return "\(before) → \(target) (did not complete)"
        }
    }

    private var summary: String {
        let result = OutcomeLabel.wording(entry.outcome, entry.verification).text
        return "\(entry.item.rawValue), \(entry.timestamp.formatted(date: .abbreviated, time: .shortened)), "
            + "from \(entry.origin.displayName). \(versions). \(result)."
    }
}
