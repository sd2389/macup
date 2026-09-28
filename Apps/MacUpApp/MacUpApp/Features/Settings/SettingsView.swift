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

            Section("Privacy") {
                Text("MacUp has no telemetry and no account. Nothing about your Mac leaves it, except the requests your package managers make themselves.")
            }

            Section("Diagnostics") {
                LabeledContent("Login shell", value: model.shell?.displayPath ?? "Not read yet")
                LabeledContent("Shell environment", value: model.environmentProblem == nil ? (model.shell == nil ? "Not read yet" : "Read successfully") : "Could not be read")
                Button("Open Doctor") { show(.doctor) }
            }

            Section {
                Button("Open Features") { show(.features) }
                Text("Automatic checks, approval, and face match are on the Features screen.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Sized, not fixed: a fixed height clips the form at larger text
        // sizes, which is exactly who needs the extra room (CLAUDE.md §21).
        .frame(minWidth: 540, idealWidth: 600, minHeight: 440, idealHeight: 720)
        .onAppear { model.loadConfiguration() }
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
    @Environment(AppModel.self) private var model
    let rule: PolicyListing.ProviderRule
    let inherited: UpdatePolicy

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Menu {
                    Picker("Policy", selection: policy) {
                        Text("Use the Default (\(inherited.displayName))").tag(UpdatePolicy.inherit)
                        Text(UpdatePolicy.auto.displayName).tag(UpdatePolicy.auto)
                        Text(UpdatePolicy.ask.displayName).tag(UpdatePolicy.ask)
                        Text(UpdatePolicy.ignore.displayName).tag(UpdatePolicy.ignore)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(rule.effectivePolicy.displayName, systemImage: rule.effectivePolicy.symbolName)
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.isChangingPolicy || !rule.enabled)
                .accessibilityLabel(
                    "Update policy for \(rule.provider.displayName), currently \(rule.effectivePolicy.displayName)"
                )
                Toggle("Enabled", isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(model.isChangingPolicy)
                    .accessibilityLabel("Check \(rule.provider.displayName)")
            }
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

    private var policy: Binding<UpdatePolicy> {
        Binding(
            get: { rule.policy },
            // Pin is not offered for a whole provider: holding every item of a
            // provider at its current version is what turning the provider off
            // means, and the validator refuses the rule outright.
            set: { newValue in Task { await model.setPolicy(newValue, for: rule.provider) } }
        )
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in Task { await model.setProviderEnabled(newValue, for: rule.provider) } }
        )
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
                Button("Clear") { Task { await model.clearPolicy(for: rule.item) } }
                    .disabled(model.isChangingPolicy)
                    .accessibilityLabel("Clear the rule for \(rule.item.name)")
                    .help("Remove this rule so the item follows its provider again")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.item.name.displaySafe)
                    Text(rule.item.rawValue.displaySafe).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: rule.provider.symbolName).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
