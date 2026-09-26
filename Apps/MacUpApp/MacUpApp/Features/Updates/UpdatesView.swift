import MacUpCore
import SwiftUI

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: PackageID?
    @State private var showsInspector = true

    var body: some View {
        let report = model.report
        let updates = report?.updates ?? []
        Group {
            if let report, !updates.isEmpty {
                List(selection: $selection) {
                    ForEach(report.providers.filter { !report.updates(for: $0.provider).isEmpty }, id: \.provider) { provider in
                        Section(provider.displayName) {
                            ForEach(report.updates(for: provider.provider)) { update in
                                UpdateRow(update: update).tag(update.id)
                            }
                        }
                    }
                }
                .onAppear { if selection == nil { selection = updates.first?.id } }
            } else {
                ContentUnavailableView(
                    "No Updates",
                    systemImage: "checkmark.circle",
                    description: Text(report == nil ? "Run a check to see available updates." : "Everything MacUp checks is up to date.")
                )
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let update = updates.first(where: { $0.id == selection }) {
                    UpdateDetail(update: update)
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Select an update to see its details."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details")
            }
        }
    }
}

private struct UpdateRow: View {
    let update: UpdateCandidate

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(update.displayName.displaySafe).fontWeight(.medium)
                Text(update.id.rawValue.displaySafe).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(update.installedVersion?.raw.displaySafe ?? "Unknown") → \(update.availableVersion.raw.displaySafe)")
                    .monospacedDigit()
                RiskLabel(level: update.risk.level).font(.caption)
            }
        }
        .padding(.vertical, 3)
        // Run the row separator under the whole row, not just the last label.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

private struct UpdateDetail: View {
    let update: UpdateCandidate

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(update.displayName.displaySafe).font(.title3.weight(.semibold))
                    Text(update.id.rawValue.displaySafe).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Section("Version") {
                LabeledContent("Installed", value: update.installedVersion?.raw.displaySafe ?? "Unknown")
                LabeledContent("Available", value: update.availableVersion.raw.displaySafe)
                LabeledContent("Change", value: update.versionChange.displayName.capitalizedFirst)
            }

            Section("Risk") {
                RiskLabel(level: update.risk.level)
                ForEach(update.risk.reasons, id: \.self) { reason in
                    Text(reason.displaySafe).foregroundStyle(.secondary)
                }
            }

            if let ownership = update.ownership, !ownership.links.isEmpty {
                Section("Managed By") {
                    ForEach(Array(ownership.links.enumerated()), id: \.offset) { _, link in
                        LabeledContent(link.label.displaySafe) {
                            Text(link.path?.displayPath ?? "").textSelection(.enabled)
                        }
                    }
                }
            }

            if !update.notes.isEmpty {
                Section("Notes") {
                    ForEach(update.notes, id: \.self) { note in
                        Text(note.displayPath)
                    }
                }
            }

            if !update.details.isEmpty {
                Section("Details") {
                    ForEach(update.details.sorted { $0.key < $1.key }, id: \.key) { key, value in
                        LabeledContent(label(for: key)) {
                            Text(display(key: key, value: value)).textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                Text("MacUp doesn't install updates yet. This version only reports them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(for key: String) -> String {
        switch key {
        case "sizeKiB": return "Download size"
        case "configPath": return "Configuration file"
        case "configScope": return "Configuration scope"
        default:
            let words = key.replacingOccurrences(of: "field.", with: "").reduce(into: "") { result, character in
                if character.isUppercase && !result.isEmpty { result += " " }
                result.append(character)
            }
            return words.lowercased().capitalizedFirst
        }
    }

    private func display(key: String, value: String) -> String {
        if key == "sizeKiB", let kibibytes = Int64(value) {
            return ByteCountFormatter.string(fromByteCount: kibibytes * 1024, countStyle: .file)
        }
        return value.displayPath
    }
}
