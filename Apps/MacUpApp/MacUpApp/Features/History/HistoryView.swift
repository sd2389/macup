import MacUpCore
import SwiftUI

/// What MacUp attempted, newest first, and what came of it.
///
/// History is a trust feature (CLAUDE.md §16), so it shows the attempts that
/// failed and the items MacUp decided to leave alone, with the reason, exactly
/// as it shows the ones that worked. Each entry opens with one headline saying
/// what happened and, when MacUp read the item back afterwards, what the
/// attempt left. A line the file could not decode is reported rather than
/// quietly dropped.
///
/// The screen can be narrowed to one item, as the Updates screen opens it, and
/// searched; both go through the same ``HistoryFilter`` as `macup history`.
struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let reading = model.history
        let item = model.historyFilter.items.sorted().first
        Group {
            if let problem = model.historyProblem {
                ContentUnavailableView {
                    Label("History Could Not Be Read", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.displayPath)
                } actions: {
                    Button("Try Again") { model.loadHistory() }
                }
            } else if let reading, !reading.entries.isEmpty || item != nil {
                Form {
                    ForEach(reading.findings, id: \.self) { finding in
                        Section {
                            FindingRow(finding: finding)
                        }
                    }
                    if let item {
                        Section {
                            ItemFilterRow(item: item)
                        }
                    }
                    entries(reading, item: item)
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
        .searchable(text: $model.historyFilter.search, prompt: "Item, provider, or outcome")
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

    private func entries(_ reading: HistoryReading, item: PackageID?) -> some View {
        let entries = model.visibleHistory
        let searching = !model.historyFilter.searchWords.isEmpty
        return Section {
            if entries.isEmpty {
                Text(searching
                    ? "No entry matches “\(model.historyFilter.search.displaySafe)”. A search looks at each entry's package ID, provider, and outcome."
                    : "MacUp has recorded no attempt at \(item?.rawValue.displaySafe ?? "this item"), and no decision to leave it alone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry)
                }
            }
        } header: {
            Text(searching
                ? "\(entries.count) of \(Self.count(reading.entries.count))"
                : Self.count(entries.count))
        } footer: {
            Text("Newest first. Nothing here is a secret: commands, versions, and errors are recorded with anything secret-shaped removed.")
                .leadingFooter()
        }
    }

    private static func count(_ entries: Int) -> String {
        entries == 1 ? "1 entry" : "\(entries) entries"
    }
}

/// Says the screen is showing one item, with the way back to everything.
private struct ItemFilterRow: View {
    @Environment(AppModel.self) private var model
    let item: PackageID

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("Showing only \(item.rawValue.displaySafe)")
            } icon: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            Spacer(minLength: 8)
            Button("Show All History") { model.showAllHistory() }
                .help("Show every item's entries again")
        }
    }
}

/// One entry: which item and when, the one headline that says what happened,
/// the versions — with what MacUp found afterwards when it looked — and the
/// labelled facts about the attempt. The error text recorded with it is
/// detail under all of that, never a second status.
private struct HistoryRow: View {
    let entry: HistoryEntry
    @State private var showsCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.item.name.displaySafe).fontWeight(.semibold)
                Text(entry.item.rawValue.displaySafe)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                Text(timestamp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }

            HistoryHeadlineLabel(headline: entry.headline)
                .font(.callout.weight(.medium))
            Text(entry.versionSummary.displaySafe)
                .font(.callout)
                .monospacedDigit()
            if let state = entry.stateAfter {
                Text(state.displaySafe)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = entry.skipReason {
                Text(reason.displayPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.circumstances.joined(separator: " · ").displaySafe)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = entry.errorSummary {
                Text("Details: \(error.displayPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .accessibilityLabel(summary.displaySafe)
    }

    private var timestamp: String {
        entry.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    /// The row as one sentence for VoiceOver, with the versions spoken as
    /// words rather than as arrows.
    private var summary: String {
        var versions = "From \(entry.versionBefore ?? "an unknown version") to \(entry.versionTarget ?? "an unknown version")"
        if let after = entry.versionAfter { versions += ", now \(after)" }
        var parts = ["\(entry.item.name), \(entry.item.rawValue), \(timestamp)", entry.headline.text, versions]
        if let state = entry.stateAfter { parts.append(state) }
        if let reason = entry.skipReason { parts.append(reason) }
        parts.append(entry.circumstances.joined(separator: ", "))
        return parts.joined(separator: ". ") + "."
    }
}
