import AppKit
import MacUpCore
import SwiftUI

/// A read-only view of the configuration. Editing arrives with update policies.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let loaded = model.configuration
        let configuration = loaded?.configuration ?? .defaults
        Form {
            Section("Configuration") {
                LabeledContent("File") {
                    Text(loaded?.path.displayPath ?? "").textSelection(.enabled)
                }
                LabeledContent("Status", value: status(loaded))
                ForEach(Array((loaded?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                    Label(
                        issue.path.isEmpty ? issue.message.displaySafe : "\(issue.path.displaySafe): \(issue.message.displaySafe)",
                        systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
                    )
                }
                HStack {
                    Button("Show in Finder") {
                        if let path = loaded?.path {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    .disabled(loaded?.source != .file)
                    Button("Reload") { model.loadConfiguration() }
                }
            }

            Section("Providers") {
                ForEach(ProviderID.known, id: \.self) { provider in
                    LabeledContent(provider.displayName, value: configuration.settings(for: provider).enabled ? "On" : "Off")
                }
            }

            Section("Update Policies") {
                LabeledContent("Default", value: configuration.global.defaultPolicy.displayName)
                ForEach(configuration.items.sorted { $0.key < $1.key }, id: \.key) { id, item in
                    LabeledContent(id.displaySafe, value: item.policy.displayName)
                }
            }

            Section("Scheduling") {
                LabeledContent(
                    "Scheduled checks",
                    value: configuration.schedule.enabled
                        ? "\(configuration.schedule.frequency.rawValue.capitalizedFirst) at \(configuration.schedule.time)"
                        : "Off"
                )
            }

            Section("Privacy") {
                Text("MacUp has no telemetry and no account. Nothing about your Mac leaves it, except the requests your package managers make themselves.")
            }

            Section("Diagnostics") {
                LabeledContent("Login shell", value: model.shell?.displayPath ?? "Not read yet")
                LabeledContent("Shell environment", value: model.environmentProblem == nil ? (model.shell == nil ? "Not read yet" : "Read successfully") : "Could not be read")
            }

            Section {
                Text("Settings are read-only in this version. To change them, edit the configuration file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .onAppear { model.loadConfiguration() }
    }

    private func status(_ loaded: LoadedConfiguration?) -> String {
        guard let loaded else { return "Not loaded" }
        switch (loaded.source, loaded.hasErrors) {
        case (.defaults, _): return "No file, using defaults"
        case (.file, true): return "Has errors; automatic changes are off"
        case (.file, false): return "Valid"
        }
    }
}
