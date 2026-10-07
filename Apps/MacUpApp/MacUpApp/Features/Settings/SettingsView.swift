import AppKit
import MacUpCore
import SwiftUI

/// What MacUp is configured with, where that configuration lives, and the
/// rules that decide what it may change.
///
/// Every rule here is written through ``PolicyEditor``, the one place MacUp
/// changes a policy, so this screen and `macup policy set` cannot disagree
/// (CLAUDE.md §12). The feature switches live on the Features screen, where one
/// row per feature is easier to find than a section part-way down a long form.
/// Updating MacUp itself. MacUp opens no network connection, so this says
/// nothing until a check has run: when Homebrew installed MacUp, Homebrew's
/// own outdated list is the answer, and a copy that was downloaded by hand is
/// pointed at its releases page and left alone.
private struct MacUpUpdateSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            if let status = model.selfUpdateStatus {
                Text(status.headline.displaySafe).fixedSize(horizontal: false, vertical: true)
                ForEach(status.installations) { installation in
                    LabeledContent(installation.displayName) {
                        Text(installation.path?.displayPath ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if status.hasUpdate {
                    Button("Update MacUp…") { Task { await model.reviewSelfUpdate() } }
                        .help("Shows the same review as any other update, with the exact command, before anything runs.")
                } else if !status.isManagedByHomebrew {
                    Button("Open Releases Page") {
                        if let url = URL(string: status.releasesURL) { NSWorkspace.shared.open(url) }
                    }
                    .help("Opens your browser. MacUp never downloads or replaces itself.")
                }
            } else {
                Text("MacUp checks for its own update with the same check it runs for everything else. Check for updates once, and this says where MacUp came from and whether Homebrew has a newer version.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("MacUp Updates")
        } footer: {
            Text("MacUp opens no connection of its own. When Homebrew installed MacUp, updating it is an ordinary Homebrew update with the same plan, confirmation, and history. The same thing is `macup self-update`.")
                .leadingFooter()
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let loaded = model.configuration
        let rules = model.policyRules
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

            if let change = model.lastPolicyChange {
                Section("Last change") {
                    Label(change.summary.displaySafe, systemImage: "checkmark.circle")
                    LabeledContent("Written to", value: change.path.displaySafe)
                    ForEach(change.warnings, id: \.self) { warning in
                        Label(warning.displaySafe, systemImage: "exclamationmark.triangle")
                    }
                }
            }
            if let problem = model.policyProblem {
                Section("Nothing was changed") {
                    Label(problem.displaySafe, systemImage: "xmark.octagon")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Default policy") {
                    Picker("Default policy", selection: defaultPolicy) {
                        Text(UpdatePolicy.auto.displayName).tag(UpdatePolicy.auto)
                        Text(UpdatePolicy.ask.displayName).tag(UpdatePolicy.ask)
                        Text(UpdatePolicy.ignore.displayName).tag(UpdatePolicy.ignore)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(model.isChangingPolicy)
                    .accessibilityLabel("Default update policy")
                }
            } header: {
                Text("Update Policies")
            } footer: {
                // Pin and Inherit are absent on purpose: the global default has
                // nothing above it to inherit from, and pinning everything is
                // not a default, so the configuration validator refuses both.
                Text("What an item gets when no rule of its own and no provider rule applies. A rule for one item wins over its provider's rule, which wins over this.")
                    .leadingFooter()
            }

            Section {
                ForEach(rules.providers) { rule in
                    ProviderRuleRow(rule: rule, inherited: rules.defaultPolicy)
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("A provider that is off is never run and never proposes an update.")
                    .leadingFooter()
            }

            Section {
                if rules.items.isEmpty {
                    Text("No item has a rule of its own, so every item follows its provider or the default above.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules.items) { rule in
                        ItemRuleRow(rule: rule)
                    }
                }
                ForEach(rules.unreadableItemKeys, id: \.self) { key in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.displaySafe).font(.body.monospaced())
                            Text("MacUp could not read this as a package ID, so it is not applying it. It is listed here rather than dropped.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
                    }
                }
            } header: {
                Text("Item Rules")
            } footer: {
                Text(rules.automaticModificationsAllowed
                    ? "Clearing a rule makes that item follow its provider again."
                    : "MacUp could not read every rule in this file, so it will not change any of them until that is fixed.")
                    .leadingFooter()
            }

            MacUpUpdateSection()

            Section("Privacy") {
                Text("MacUp has no telemetry and no account. Nothing about your Mac leaves it, except the requests your package managers make themselves.")
            }

            Section("Diagnostics") {
                LabeledContent("Login shell", value: model.shell?.displayPath ?? "Not read yet")
                LabeledContent("Shell environment", value: model.environmentProblem == nil ? (model.shell == nil ? "Not read yet" : "Read successfully") : "Could not be read")
                Button("Open Doctor") { show(.doctor) }
                Button("Export Diagnostics…") { model.beginDiagnosticsExport() }
                    .help("Make a redacted file to attach to a bug report. You see all of it before anything is saved.")
            }

            Section {
                Button("Open Features") { show(.features) }
                Text("Automatic checks, approval, and face match are on the Features screen.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Uninstall MacUp…") {
                    show(.uninstall)
                    Task { await model.reviewSelfUninstall() }
                }
                .help("See everything MacUp put on this Mac before anything is removed.")
            } header: {
                Text("Uninstall MacUp")
            } footer: {
                Text("Removes the app, the macup command, MacUp's settings and history, its scheduled check, and its Keychain items, with nothing left behind. Nothing it manages for you is touched.")
                    .leadingFooter()
            }
        }
        .formStyle(.grouped)
        // Sized, not fixed: a fixed height clips the form at larger text
        // sizes, which is exactly who needs the extra room (CLAUDE.md §21).
        .frame(minWidth: 540, idealWidth: 600, minHeight: 440, idealHeight: 720)
        .onAppear { model.loadConfiguration() }
        .sheet(isPresented: Binding(
            get: { model.diagnosticsExport != nil },
            set: { if !$0 { model.endDiagnosticsExport() } }
        )) {
            if let export = model.diagnosticsExport {
                DiagnosticsExportSheet(export: export)
            }
        }
    }

    private var defaultPolicy: Binding<UpdatePolicy> {
        Binding(
            get: { model.policyRules.defaultPolicy },
            set: { policy in Task { await model.setDefaultPolicy(policy) } }
        )
    }

    /// Settings is its own window, so changing the section is invisible unless
    /// the main window is brought forward.
    private func show(_ section: AppModel.Section) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
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

/// One provider: whether MacUp runs it, and what its items inherit.
private struct ProviderRuleRow: View {
    let rule: PolicyListing.ProviderRule
    let inherited: UpdatePolicy

    var body: some View {
        LabeledContent {
            ProviderPolicyControls(rule: rule, inherited: inherited)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.provider.displayName)
                    Text(rule.enabled ? "Items get \(rule.effectivePolicy.displayName)" : "Never run")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: rule.provider.symbolName).accessibilityHidden(true)
            }
        }
    }
}

/// One item rule, with the way to remove it.
private struct ItemRuleRow: View {
    @Environment(AppModel.self) private var model
    let rule: PolicyListing.ItemRule

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                ItemPolicyPicker(item: rule.item)
                // An entry that inherits and keeps a skipped version or a
                // note has no rule of its own to clear; the menu and the
                // Updates screen change those.
                Button("Clear") { Task { await model.clearPolicy(for: rule.item) } }
                    .disabled(
                        model.isChangingPolicy
                            || (rule.policy == .inherit && (rule.skipVersion != nil || rule.note != nil))
                    )
                    .accessibilityLabel("Clear the rule for \(rule.item.name)")
                    .help("Remove this rule so the item follows its provider again")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.item.name.displaySafe)
                    Text(rule.item.rawValue.displaySafe).font(.caption).foregroundStyle(.secondary)
                    if let skipped = rule.skipVersion {
                        Label("Skips \(skipped.displaySafe)", systemImage: "forward.end")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = rule.note { ItemNoteText(note: note) }
                }
            } icon: {
                Image(systemName: rule.provider.symbolName).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
