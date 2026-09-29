import MacUpCore
import SwiftUI

struct UpdatesView: View {
    @Environment(AppModel.self) private var model
    @State private var showsInspector = true

    var body: some View {
        @Bindable var model = model
        let report = model.report
        let updates = report?.updates ?? []
        Group {
            if let report, !updates.isEmpty {
                List(selection: $model.selectedUpdate) {
                    if !model.status.reasons.isEmpty {
                        Section {
                            ForEach(model.status.reasons, id: \.self) { reason in
                                Label(reason, systemImage: "exclamationmark.triangle")
                            }
                        } header: {
                            Text("These results are incomplete")
                        }
                    }
                    if let change = model.lastPolicyChange {
                        Section {
                            Label(change.summary.displaySafe, systemImage: "checkmark.circle")
                            ForEach(change.warnings, id: \.self) { warning in
                                Label(warning.displaySafe, systemImage: "exclamationmark.triangle")
                            }
                        } header: {
                            Text("Rule changed")
                        }
                    }
                    if let problem = model.policyProblem {
                        Section {
                            Label(problem.displaySafe, systemImage: "xmark.octagon")
                        } header: {
                            Text("The rule was not changed")
                        }
                    }
                    ForEach(report.providers.filter { !report.updates(for: $0.provider).isEmpty }, id: \.provider) { provider in
                        Section(provider.displayName) {
                            ForEach(report.updates(for: provider.provider)) { update in
                                UpdateRow(update: update, decision: model.decisions[update.id]).tag(update.id)
                            }
                        }
                    }
                }
                .onAppear { if model.selectedUpdate == nil { model.selectedUpdate = updates.first?.id } }
            } else if report != nil, !model.status.reasons.isEmpty {
                ContentUnavailableView(
                    "Check Incomplete",
                    systemImage: model.status.symbolName,
                    description: Text(model.status.reasons.joined(separator: "\n") + "\nSee Doctor for details.")
                )
            } else {
                ContentUnavailableView(
                    "No Updates",
                    systemImage: report == nil ? "circle.dashed" : "checkmark.circle",
                    description: Text(report == nil ? "Run a check to see available updates." : "Everything MacUp checks is up to date.")
                )
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let update = updates.first(where: { $0.id == model.selectedUpdate }) {
                    UpdateDetail(update: update, decision: model.decisions[update.id])
                } else {
                    ContentUnavailableView("No Selection", systemImage: "sidebar.trailing", description: Text("Select an update to see its details."))
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.reviewUpdates() }
                } label: {
                    Label("Review Updates", systemImage: "list.bullet.rectangle")
                }
                .disabled(updates.isEmpty || model.isPlanning || model.isApplying)
                // Deliberately not "Update All": the review shows what would
                // change and what would not, and nothing runs until Apply.
                .help("See exactly what MacUp would run, and what it would leave alone")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details")
            }
        }
        .sheet(isPresented: $model.isReviewingPlan) {
            ReviewSheet()
                // Nothing may close the sheet while an update is running: the
                // run would carry on with nobody able to see it.
                .interactiveDismissDisabled(model.isApplying)
        }
        .sheet(isPresented: $model.isShowingCommand) {
            CommandSheet()
        }
    }
}

/// One update: what it is, where it came from, what policy says, and the two
/// controls that change something.
private struct UpdateRow: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate
    let decision: PolicyDecision?

    var body: some View {
        // The controls sit on their own line rather than beside the text, so
        // a long package name cannot squeeze a button until its label wraps
        // one letter per line.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(update.displayName.displaySafe).fontWeight(.medium)
                Spacer(minLength: 8)
                Text("\(update.installedVersion?.raw.displaySafe ?? "Unknown") → \(update.availableVersion.raw.displaySafe)")
                    .monospacedDigit()
                    .accessibilityLabel(
                        "\(update.installedVersion?.raw ?? "unknown version") to \(update.availableVersion.raw)"
                    )
            }
            HStack(spacing: 10) {
                Text(update.id.rawValue.displaySafe)
                Label(update.provider.displayName, systemImage: update.provider.symbolName)
                if let decision {
                    PolicyLabel(policy: decision.policy)
                }
                if decision?.source == .skippedVersion { SkippedLabel() }
                RiskLabel(level: update.risk.level)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let difference = update.versionDifference, !difference.changedParts.isEmpty {
                Text("Changes: \(difference.summary.displaySafe)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if update.signals.contains(.installationIncomplete) {
                Label(
                    "An earlier install of \(update.displayName.displaySafe) did not finish. MacUp will not upgrade it until that is repaired; see the details.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            } else if update.signals.contains(.buildsFromSource) {
                Label("Will be compiled from source, which can take an hour or more.", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = decision?.reason {
                Text(reason.displaySafe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ItemPolicyPicker(item: update.id)
                Button("Update…") { Task { await model.reviewUpdates([update.id]) } }
                    .disabled(!canApply || model.isPlanning || model.isApplying)
                    .help(applyHelp)
                    .accessibilityLabel("Review an update for \(update.displayName)")
                    .accessibilityHint(applyHelp)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 5)
        // Run the row separator under the whole row, not just the last label.
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        // An ignored or pinned item stays legible: the decision the user made
        // is the information, so it is never greyed out into invisibility.
        .accessibilityElement(children: .contain)
    }

    /// MacUp offers to apply an update only when the provider can apply one
    /// and policy has not already refused it. Everything else gets the reason
    /// instead of a button that would fail.
    private var canApply: Bool {
        model.canApplyUpdates(of: update.provider) && decision?.allowsExecution != false
            && !update.signals.contains(.installationIncomplete)
    }

    private var applyHelp: String {
        if update.signals.contains(.installationIncomplete) {
            return "An earlier install of \(update.displayName) did not finish, so MacUp will not start another upgrade on top of it."
        }
        if !model.canApplyUpdates(of: update.provider) {
            return "MacUp reports \(update.provider.displayName) updates but does not apply them. Use View Command to see what it would take."
        }
        if decision?.allowsExecution == false {
            return decision?.reason ?? "MacUp will not change this item."
        }
        return "Review the exact command before anything runs"
    }
}

/// The rule for one item, written through ``PolicyEditor`` and nowhere else.
///
/// "Use the default" removes the rule rather than writing `inherit`, because a
/// rule that says "inherit" and no rule at all mean the same thing, and having
/// one fewer way to say it keeps the configuration file honest.
struct ItemPolicyPicker: View {
    @Environment(AppModel.self) private var model
    let item: PackageID

    var body: some View {
        // A menu rather than a pop-up button: the options have to name what
        // the default is, and a pop-up button would put that whole sentence
        // in the row.
        Menu {
            Picker("Policy", selection: selection) {
                Text("Use the Default (\(inherited.displayName))").tag(UpdatePolicy.inherit)
                Text(UpdatePolicy.auto.displayName).tag(UpdatePolicy.auto)
                Text(UpdatePolicy.ask.displayName).tag(UpdatePolicy.ask)
                Text(UpdatePolicy.ignore.displayName).tag(UpdatePolicy.ignore)
                // Pin is MacUp's own hold, enforced by the policy engine for
                // every provider, exactly as `macup policy set <id> pin` is.
                Text(UpdatePolicy.pin.displayName).tag(UpdatePolicy.pin)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            SkipVersionMenuItems(item: item)
        } label: {
            Label(effective.displayName, systemImage: effective.symbolName)
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(model.isChangingPolicy)
        .accessibilityLabel("Update policy for \(item.name), currently \(effective.displayName)")
        .help(rule == nil
            ? "\(item.name) follows the default. Choose a rule of its own here."
            : "\(item.name) has a rule of its own.")
    }

    /// What this item gets today, whether from its own rule or inherited.
    private var effective: UpdatePolicy { rule ?? inherited }

    /// `nil` for an entry that says `inherit`, which is how an item with a
    /// skipped version or a note but no rule of its own is written.
    private var rule: UpdatePolicy? {
        model.policyRules.rule(for: item).flatMap { $0.policy == .inherit ? nil : $0.policy }
    }

    /// What this item would get with no rule of its own.
    private var inherited: UpdatePolicy {
        let rules = model.policyRules
        let provider = rules.rule(for: item.provider)?.policy ?? .inherit
        return provider == .inherit ? rules.defaultPolicy : provider
    }

    private var selection: Binding<UpdatePolicy> {
        Binding(
            get: { rule ?? .inherit },
            set: { policy in
                Task {
                    if policy == .inherit {
                        await model.clearPolicy(for: item)
                    } else {
                        await model.setPolicy(policy, for: item)
                    }
                }
            }
        )
    }
}

private struct UpdateDetail: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate
    let decision: PolicyDecision?

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

            RecentAttemptsSection(item: update.id, name: update.displayName)

            Section {
                if let difference = update.versionDifference {
                    ForEach(difference.parts, id: \.name) { part in
                        LabeledContent(part.name) {
                            Text(part.changed ? "\(part.from) → \(part.to)" : "\(part.from), unchanged")
                                .monospacedDigit()
                                .fontWeight(part.changed ? .semibold : .regular)
                                .foregroundStyle(part.changed ? .primary : .secondary)
                        }
                        .accessibilityLabel(part.changed
                            ? "\(part.name) changes from \(part.from) to \(part.to)"
                            : "\(part.name) stays \(part.from)")
                    }
                } else {
                    Text("MacUp cannot break these versions into parts, so it does not guess at what changes between them.")
                        .foregroundStyle(.secondary)
                }
                if let link = update.releaseInfoLink {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "arrow.up.right.square")
                    }
                    .help(link.url.absoluteString)
                }
            } header: {
                Text("What Changes")
            } footer: {
                Text(update.releaseInfoLink == nil
                    ? "Worked out from the two version numbers. \(update.provider.displayName) gives MacUp no page to read the release notes on."
                    : "Worked out from the two version numbers. The page opens in your browser; MacUp itself fetches nothing.")
                    .leadingFooter()
            }

            Section("Policy") {
                if let decision {
                    LabeledContent("In effect") { PolicyLabel(policy: decision.policy) }
                    Text(decision.reason.displaySafe).foregroundStyle(.secondary)
                }
                LabeledContent("Rule for this item") { ItemPolicyPicker(item: update.id) }
                SkippedVersionDetail(update: update)
                if decision?.policy == .pin {
                    Text("Pin is MacUp's own hold: MacUp will not update \(update.displayName.displaySafe). It does not pin the item in \(update.provider.displayName), so running \(update.provider.displayName) yourself can still update it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !model.canApplyUpdates(of: update.provider) {
                    Text("MacUp reports \(update.provider.displayName) updates and does not apply them in this version.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ItemNoteSection(item: update.id)

            Section("Risk") {
                RiskLabel(level: update.risk.level)
                ForEach(update.risk.reasons, id: \.self) { reason in
                    Text(reason.displaySafe).foregroundStyle(.secondary)
                }
                ForEach(update.signals, id: \.self) { signal in
                    Label(signal.explanation, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                Button("View Command…") { Task { await model.showCommand(for: update.id) } }
                    .disabled(model.isPlanning || model.isApplying)
                    .help("The exact executable and arguments MacUp would run for this item")
                Button("Review Update…") { Task { await model.reviewUpdates([update.id]) } }
                    .disabled(
                        !model.canApplyUpdates(of: update.provider)
                            || decision?.allowsExecution == false
                            || model.isPlanning
                            || model.isApplying
                    )
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
