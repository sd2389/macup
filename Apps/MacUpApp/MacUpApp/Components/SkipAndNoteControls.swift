import MacUpCore
import SwiftUI

/// The Skip This Version entries at the foot of an item's rule menu, written
/// through ``PolicyEditor`` exactly as `macup policy skip|unskip` are.
///
/// Skip is offered only for a version the last check found, so what is stored
/// is the exact string the provider reported, and only while the item's rule
/// would offer or run it: an ignored or pinned item already leaves every
/// version alone. Stop Skipping is offered whenever a version is skipped,
/// including one that is no longer on offer.
struct SkipVersionMenuItems: View {
    @Environment(AppModel.self) private var model
    let item: PackageID

    var body: some View {
        let skipped = model.policyRules.rule(for: item)?.skipVersion
        let offered = model.offeredVersion(of: item).flatMap { $0.raw != skipped && canSkip ? $0 : nil }
        if offered != nil || skipped != nil {
            Divider()
        }
        if let offered {
            Button("Skip This Version (\(offered.raw.displaySafe))") {
                Task { await model.skipVersion(offered, for: item) }
            }
        }
        if let skipped {
            Button("Stop Skipping \(skipped.displaySafe)") {
                Task { await model.stopSkipping(item) }
            }
        }
    }

    private var canSkip: Bool {
        let policy = model.decisions[item]?.policy
        return policy != .ignore && policy != .pin
    }
}

/// "Skipped" in words, as a policy is shown: the version on offer is one the
/// user skipped.
struct SkippedLabel: View {
    var body: some View {
        Label("Skipped", systemImage: "forward.end")
            .accessibilityLabel("You skipped this version")
    }
}

/// The user's note, set apart as their words rather than MacUp's.
struct ItemNoteText: View {
    let note: String

    var body: some View {
        Label {
            Text(note.displaySafe)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "text.quote").accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your note: \(note)")
    }
}

/// The version an item skips, whether that skip applies to the version on
/// offer now, and the way to stop skipping it.
struct SkippedVersionDetail: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate

    var body: some View {
        if let rule = model.policyRules.rule(for: update.id), let skipped = rule.skipVersion {
            LabeledContent("Skipped version") {
                HStack(spacing: 10) {
                    Text(skipped.displaySafe).monospacedDigit()
                    Button("Stop Skipping") { Task { await model.stopSkipping(update.id) } }
                        .disabled(model.isChangingPolicy)
                        .accessibilityLabel("Stop skipping \(skipped) of \(update.displayName)")
                }
            }
            Text(rule.skips(update.availableVersion)
                ? "MacUp leaves this version out of plans. When a different one is offered, \(update.displayName.displaySafe) follows its rule again."
                : "\(update.availableVersion.raw.displaySafe) is a different version, so the skip no longer applies.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The user's note on an item, edited in place and saved through
/// ``PolicyEditor`` exactly as `macup policy note` saves it.
///
/// The limits are MacUpCore's and are checked while typing, so Save is never
/// offered for a note the editor would refuse.
struct ItemNoteSection: View {
    @Environment(AppModel.self) private var model
    let item: PackageID
    @State private var draft = ""

    var body: some View {
        Section {
            TextField(
                "Note",
                text: $draft,
                prompt: Text("Why it is held, for example “waiting for PHP 8.4 support”")
            )
            .labelsHidden()
            .onSubmit(save)
            .accessibilityLabel("Note on \(item.name)")
            HStack(spacing: 8) {
                // A problem is stated in words; the colour only repeats it.
                Text(problem ?? "\(draft.count) of \(MacUpConfiguration.ItemSettings.maximumNoteLength) characters")
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if saved != nil {
                    Button("Remove") { Task { await model.clearNote(for: item) } }
                        .disabled(model.isChangingPolicy)
                        .accessibilityLabel("Remove the note on \(item.name)")
                }
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityLabel("Save the note on \(item.name)")
            }
        } header: {
            Text("Your Note")
        } footer: {
            Text("For you. MacUp keeps it exactly as you wrote it, shows it with this item, and never acts on it.")
                .leadingFooter()
        }
        .onAppear { draft = saved ?? "" }
        .onChange(of: item) { draft = saved ?? "" }
        .onChange(of: saved) { draft = saved ?? "" }
    }

    private var saved: String? { model.policyRules.rule(for: item)?.note }

    private var problem: String? {
        draft.isEmpty ? nil : MacUpConfiguration.ItemSettings.problem(withNote: draft)
    }

    private var canSave: Bool {
        !draft.isEmpty && problem == nil && draft != saved && !model.isChangingPolicy
    }

    private func save() {
        guard canSave else { return }
        let note = draft
        Task { await model.setNote(note, for: item) }
    }
}
