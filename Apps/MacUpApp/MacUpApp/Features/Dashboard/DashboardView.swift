import MacUpCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let report = model.report {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: model.status.symbolName)
                            .font(.system(size: 30, weight: .regular))
                            .foregroundStyle(statusTint)
                            .frame(width: 38)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.status.headline)
                                .font(.largeTitle.weight(.semibold))
                            Text(statusLine(report))
                                .foregroundStyle(.secondary)
                            if report.summary.updatesAvailable > 0 {
                                Button("Review Updates") { model.section = .updates }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.large)
                                    .padding(.top, 10)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }

                // Only what MacUp actually knows. No score, no percentage.
                // A grid rather than one row: the numbers wrap instead of
                // squeezing when there are several of them or the text is
                // large (CLAUDE.md §21).
                Section {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140, maximum: 260), spacing: 16, alignment: .topLeading)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(facts(report), id: \.label) { fact in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.value)
                                    .font(.title3.weight(.medium))
                                    .monospacedDigit()
                                Text(fact.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(fact.label): \(fact.value)")
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    if model.pendingUpdates.isEmpty {
                        Text(report.updates.isEmpty
                            ? "Nothing is waiting. Everything MacUp checked is up to date."
                            : "Nothing is waiting. Every update found is one your rules leave alone, listed below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.pendingUpdates) { update in
                        Button {
                            // Clears the Updates filter if it would hide this one.
                            model.showUpdate(update.id)
                        } label: {
                            DashboardUpdateRow(update: update, decision: model.decisions[update.id])
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Pending Updates")
                } footer: {
                    if !model.pendingUpdates.isEmpty {
                        Text("Nothing here runs until you review it. Select one to see what changes and the exact command.")
                            .leadingFooter()
                    }
                }

                Section {
                    if model.leftAloneUpdates.isEmpty && model.heldRulesWithoutUpdate.isEmpty {
                        Text("No item is ignored, pinned, or skipped. Choose Ignore, Pin, or Skip This Version for an item on the Updates screen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.leftAloneUpdates) { update in
                        HeldRow(
                            item: update.id,
                            title: update.displayName,
                            detail: model.decisions[update.id]?.reason ?? "",
                            versions: "\(update.installedVersion?.raw ?? "Unknown") → \(update.availableVersion.raw)",
                            policy: model.decisions[update.id]?.policy ?? .ignore,
                            canClear: model.decisions[update.id]?.source == .item,
                            isSkipped: model.decisions[update.id]?.source == .skippedVersion,
                            note: model.decisions[update.id]?.note
                        )
                    }
                    ForEach(model.heldRulesWithoutUpdate) { rule in
                        HeldRow(
                            item: rule.item,
                            title: rule.item.name,
                            detail: "No update right now. The rule applies to the next one.",
                            versions: nil,
                            policy: rule.effectivePolicy,
                            canClear: true,
                            note: rule.note
                        )
                    }
                } header: {
                    Text("Ignored and Held")
                } footer: {
                    Text("MacUp does not update these. Clearing a rule makes the item follow its provider again; a skipped version comes back by itself when a different one is offered.")
                        .leadingFooter()
                }

                // What ran while nobody was looking. The notification may
                // have been missed, or never allowed, so the run is on the
                // screen as well.
                if let run = model.scheduledRun, let notification = run.notification {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(notification.title.displaySafe)
                                Text(notification.body.displaySafe)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } icon: {
                            Image(systemName: run.failed.isEmpty ? "clock.badge.checkmark" : "clock.badge.exclamationmark")
                                .accessibilityHidden(true)
                        }
                        Button("Open History") { model.section = .history }
                    } header: {
                        Text("Last Scheduled Run")
                    } footer: {
                        Text("Every attempt and every skip is in History, whether or not you saw a notification.")
                            .leadingFooter()
                    }
                }

                if !attention(report).isEmpty {
                    Section("Needs Attention") {
                        ForEach(attention(report), id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle")
                        }
                        Button("Open Doctor") { model.section = .doctor }
                    }
                }
            }
            .formStyle(.grouped)
            .task {
                await model.refreshScheduleStatus()
                await model.reportScheduledRun()
            }
        } else if model.isChecking {
            ProgressView("Checking your Mac…")
        } else {
            ContentUnavailableView {
                Label("Not Checked Yet", systemImage: "arrow.clockwise")
            } description: {
                Text("Check Now shows what is outdated. Checking never changes anything.")
            } actions: {
                Button("Check Now") { Task { await model.checkNow() } }
            }
        }
    }

    /// When the next scheduled check will actually happen. Nil unless one is
    /// installed and loaded, so the dashboard never promises a check that is
    /// only configured.
    private var scheduledNext: Date? {
        guard let status = model.scheduleStatus, status.isActive else { return nil }
        return status.nextRun
    }

    private var statusTint: Color {
        switch model.status {
        case .upToDate: return .green
        case .updatesAvailable: return .accentColor
        case .incomplete: return .orange
        case .notChecked, .checking: return .secondary
        }
    }

    private struct Fact: Hashable {
        let label: String
        let value: String
    }

    /// The glanceable numbers from CLAUDE.md §13, and nothing invented.
    /// A figure is shown only when MacUp has it, and a zero that would only
    /// take up room is left out.
    private func facts(_ report: CheckReport) -> [Fact] {
        var facts = [Fact(label: "Awaiting review", value: "\(report.summary.updatesAvailable)")]
        if model.updatesNeedingConfirmation > 0 {
            facts.append(Fact(label: "Need your confirmation", value: "\(model.updatesNeedingConfirmation)"))
        }
        if model.ignoredUpdateCount > 0 {
            facts.append(Fact(label: "Ignored by your rules", value: "\(model.ignoredUpdateCount)"))
        }
        if model.pinnedUpdateCount > 0 {
            facts.append(Fact(label: "Held at this version", value: "\(model.pinnedUpdateCount)"))
        }
        if model.skippedUpdateCount > 0 {
            facts.append(Fact(label: "Version skipped", value: "\(model.skippedUpdateCount)"))
        }
        facts.append(Fact(
            label: "Providers checked",
            value: "\(report.summary.providersChecked) of \(report.providers.count)"
        ))
        if report.summary.providersWithErrors > 0 {
            facts.append(Fact(label: "Providers with errors", value: "\(report.summary.providersWithErrors)"))
        }
        facts.append(Fact(
            label: "Last check",
            value: report.finishedAt.formatted(date: .omitted, time: .shortened)
        ))
        facts.append(Fact(
            label: "Next check",
            value: scheduledNext?.formatted(date: .abbreviated, time: .shortened) ?? "Not scheduled"
        ))
        return facts
    }

    private func statusLine(_ report: CheckReport) -> String {
        var parts = ["Checked at \(report.finishedAt.formatted(date: .omitted, time: .shortened)). Nothing was changed."]
        switch model.updatesNeedingConfirmation {
        case 0: break
        case 1: parts.append("1 needs your confirmation.")
        case let count: parts.append("\(count) need your confirmation.")
        }
        // Decisions the user already made are stated here rather than left to
        // be discovered, so a count on this screen is never quietly smaller
        // than the list on the next one (CLAUDE.md §21).
        var decided: [String] = []
        if model.ignoredUpdateCount > 0 { decided.append("\(model.ignoredUpdateCount) ignored") }
        if model.pinnedUpdateCount > 0 { decided.append("\(model.pinnedUpdateCount) held at the current version") }
        if model.skippedUpdateCount > 0 { decided.append("\(model.skippedUpdateCount) skipped") }
        if !decided.isEmpty {
            // English like the sentence around it, whatever the Mac's locale.
            let list = decided.formatted(.list(type: .and).locale(Locale(identifier: "en_US")))
            parts.append("MacUp is leaving \(list) alone, as you asked.")
        }
        return parts.joined(separator: " ")
    }

    private func attention(_ report: CheckReport) -> [String] {
        var lines: [String] = []
        if model.configuration?.hasErrors == true {
            lines.append("The configuration file has errors, so automatic changes stay off until it is fixed.")
        }
        if model.environmentProblem != nil {
            lines.append("MacUp could not read your shell's environment and may miss some tools.")
        }
        for provider in report.providers where provider.hasErrors {
            lines.append("\(provider.displayName) could not be fully checked.")
        }
        let warnings = report.providers.flatMap(\.findings).filter { $0.severity != .info }.count
        if warnings > 0 {
            lines.append(warnings == 1 ? "1 warning from the last check." : "\(warnings) warnings from the last check.")
        }
        return lines
    }
}

/// One pending update: what it is, how far it moves, and what policy says.
private struct DashboardUpdateRow: View {
    let update: UpdateCandidate
    let decision: PolicyDecision?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: update.provider.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(update.displayName.displaySafe)
                HStack(spacing: 10) {
                    Text(update.provider.displayName)
                    if let decision { PolicyLabel(policy: decision.policy) }
                    RiskLabel(level: update.risk.level)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(update.installedVersion?.raw.displaySafe ?? "Unknown") → \(update.availableVersion.raw.displaySafe)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this update on the Updates screen")
    }
}

/// An item MacUp is leaving alone, why, and the way to stop.
private struct HeldRow: View {
    @Environment(AppModel.self) private var model
    let item: PackageID
    let title: String
    let detail: String
    let versions: String?
    let policy: UpdatePolicy
    /// Only a rule on the item itself can be cleared here. One inherited
    /// from the provider, or a pin in the package manager, is changed where
    /// it lives.
    let canClear: Bool
    /// Left alone only because the user skipped the version on offer.
    var isSkipped = false
    var note: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.provider.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title.displaySafe)
                    Group {
                        if isSkipped { SkippedLabel() } else { PolicyLabel(policy: policy) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text(detail.displaySafe)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note { ItemNoteText(note: note) }
            }
            Spacer()
            if let versions {
                Text(versions.displaySafe).monospacedDigit().foregroundStyle(.secondary)
            }
            if isSkipped {
                Button("Stop Skipping") { Task { await model.stopSkipping(item) } }
                    .disabled(model.isChangingPolicy)
                    .accessibilityLabel("Stop skipping this version of \(item.name)")
                    .help("Let this version follow the item's rule again")
            } else if canClear {
                Button(policy == .pin ? "Unpin" : "Stop Ignoring") {
                    Task { await model.clearPolicy(for: item) }
                }
                .disabled(model.isChangingPolicy)
                .accessibilityLabel("\(policy == .pin ? "Unpin" : "Stop ignoring") \(item.name)")
                .help("Remove this item's rule so it follows its provider again")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
