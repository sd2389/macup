import AppKit
import MacUpCore
import SwiftUI

/// What MacUp is configured with, and where that configuration lives.
///
/// The switches moved to the Features screen, where one row per feature is
/// easier to find than a section part-way down a long form. Editing providers
/// and policies arrives with update policies.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

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

            Section("Privacy") {
                Text("MacUp has no telemetry and no account. Nothing about your Mac leaves it, except the requests your package managers make themselves.")
            }

            Section("Diagnostics") {
                LabeledContent("Login shell", value: model.shell?.displayPath ?? "Not read yet")
                LabeledContent("Shell environment", value: model.environmentProblem == nil ? (model.shell == nil ? "Not read yet" : "Read successfully") : "Could not be read")
            }

            Section {
                Button("Open Features") {
                    // Settings is its own window, so changing the section is
                    // invisible unless the main window is brought forward.
                    model.section = .features
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Text("Automatic checks, approval, and face match are on the Features screen. The rest is read-only in this version; to change it, edit the configuration file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Sized, not fixed: a fixed height clips the form at larger text
        // sizes, which is exactly who needs the extra room (CLAUDE.md §21).
        .frame(minWidth: 520, idealWidth: 580, minHeight: 420, idealHeight: 700)
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
