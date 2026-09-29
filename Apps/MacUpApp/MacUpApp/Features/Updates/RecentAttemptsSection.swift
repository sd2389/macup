import MacUpCore
import SwiftUI

/// The last few times MacUp tried to change the selected item, each with its
/// headline, and the way into History for the rest.
///
/// It is here so that an update which failed or was stopped before is in
/// front of whoever is about to try it again, with what that attempt left.
/// Everything shown comes from ``AppModel/recentAttempts(for:limit:)``, which
/// reads the item's own entries rather than the newest few of everyone's.
struct RecentAttemptsSection: View {
    @Environment(AppModel.self) private var model
    let item: PackageID
    let name: String
    @State private var attempts = RecentAttempts()

    var body: some View {
        Section {
            if let problem = attempts.problem {
                Label(problem.displayPath, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if attempts.entries.isEmpty {
                Text("MacUp has not tried to change \(name.displaySafe) yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(attempts.entries) { entry in
                    AttemptRow(entry: entry)
                }
                Button("Show All in History") { model.showHistory(for: item) }
                    .help("Open History showing only \(item.rawValue.displaySafe)")
            }
        } header: {
            Text("Recent Attempts")
        }
        // Read again for another item, and after a run, which is when the
        // item's history changes.
        .task(id: Reading(item: item, run: model.executionReport?.finishedAt)) {
            attempts = model.recentAttempts(for: item)
        }
    }

    private struct Reading: Hashable {
        let item: PackageID
        let run: Date?
    }
}

private struct AttemptRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HistoryHeadlineLabel(headline: entry.headline)
            Text("\(entry.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(entry.versionSummary.displaySafe)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let state = entry.stateAfter {
                Text(state.displaySafe)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}
