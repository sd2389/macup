import MacUpCore
import SwiftUI

/// What a batch of plans declares about itself, counted rather than implied.
///
/// Every number comes from the plans themselves. Nothing here decides whether
/// a change is safe, and nothing here says "safe": a plan that may ask for an
/// administrator password says so because it said so (CLAUDE.md §11).
struct PlanEffects {
    var network = 0
    var privilege = 0
    var restart = 0
    var configuration = 0
    var rollbackAvailable = 0
    var rollbackUnknown = 0
    var total = 0

    init(_ planned: [PlannedUpdate]) {
        for update in planned {
            total += 1
            if update.plan.expectsNetwork { network += 1 }
            if update.plan.mayRequirePrivilege { privilege += 1 }
            if update.plan.mayRequireRestart { restart += 1 }
            if update.plan.mayChangeUserConfiguration { configuration += 1 }
            switch update.plan.rollback.availability {
            case .available: rollbackAvailable += 1
            case .unknown: rollbackUnknown += 1
            case .unavailable: break
            }
        }
    }

    /// "none", "yes", "1 change", or "3 of 5 changes" — never a bare number
    /// that leaves the reader to work out what it is a share of.
    private func phrase(_ count: Int) -> String {
        switch count {
        case 0: "none"
        case total: total == 1 ? "yes" : "all \(total) changes"
        case 1: "1 change"
        default: "\(count) of \(total) changes"
        }
    }

    var rows: [(symbol: String, title: String, value: String, noteworthy: Bool)] {
        [
            ("network", "Needs the network", phrase(network), false),
            ("lock.shield", "May ask for an administrator password", phrase(privilege), privilege > 0),
            ("power", "May require a restart", phrase(restart), restart > 0),
            ("doc.text", "May edit your configuration or lockfiles", phrase(configuration), configuration > 0),
            ("arrow.uturn.backward", "Can be undone by MacUp", rollbackPhrase, false),
        ]
    }

    /// Rollback is stated as unavailable unless a plan says otherwise, because
    /// MacUp never claims it without a tested strategy (CLAUDE.md §2.22).
    private var rollbackPhrase: String {
        if rollbackAvailable == 0 && rollbackUnknown == 0 { return "no" }
        if rollbackUnknown > 0 { return "\(phrase(rollbackAvailable)); \(rollbackUnknown) unknown" }
        return phrase(rollbackAvailable)
    }
}

/// The last thing between a plan and the machine.
///
/// It says how many changes there are, which of them are still waiting on the
/// reader, which will not happen and why, what each one will run, and what the
/// plans declare about themselves. Nothing runs until Apply.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 460, idealHeight: 620)
    }

    private var plan: PlanReport? { model.updatePlan }

    private var commandsShown: Binding<Bool> {
        Binding(get: { model.reviewShowsCommands }, set: { model.reviewShowsCommands = $0 })
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if model.executionReport != nil { return "What MacUp did" }
        if model.isApplying { return "Applying changes" }
        let count = model.itemsThatWouldRun.count
        switch count {
        case 0:
            // There is a difference between a batch nobody has confirmed yet
            // and one there was never anything in, and the reader is owed it.
            return model.itemsAwaitingConfirmation.isEmpty ? "Nothing to apply" : "Nothing confirmed yet"
        case 1: return "Ready to make 1 change"
        default: return "Ready to make \(count) changes"
        }
    }

    private var subtitle: String {
        if let report = model.executionReport {
            var parts = ["\(report.summary.attempted) attempted, \(report.summary.succeeded) succeeded, \(report.summary.failed) failed."]
            if report.summary.unverified > 0 {
                parts.append("\(report.summary.unverified) succeeded without MacUp being able to confirm them.")
            }
            if report.cancelled { parts.append("The run was stopped before it finished.") }
            return parts.joined(separator: " ")
        }
        if model.isApplying {
            return "MacUp runs one item at a time and lets each one finish."
        }
        let waiting = model.itemsAwaitingConfirmation.filter { !model.confirmedItems.contains($0.item) }.count
        var parts = ["Nothing has run yet."]
        if waiting == 1 {
            parts.append("1 item is still waiting for you below.")
        } else if waiting > 1 {
            parts.append("\(waiting) items are still waiting for you below.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Body

    @ViewBuilder
    private var content: some View {
        if let plan {
            Form {
                if let problem = model.executionProblem {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(problem.displaySafe)
                                Text("Nothing was changed.").foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "xmark.octagon").foregroundStyle(.red).accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Nothing was changed: \(problem)")
                    }
                }

                if let report = model.executionReport {
                    results(report)
                } else {
                    if model.isApplying { progress }
                    plannedSections(plan)
                }

                if !plan.skipped.isEmpty {
                    Section("Will not change") {
                        ForEach(plan.skipped) { skip in
                            SkipRow(skip: skip)
                        }
                    }
                }

                if !plan.unmatchedSelection.isEmpty {
                    Section("No update offered") {
                        ForEach(plan.unmatchedSelection, id: \.self) { item in
                            Label("\(item.rawValue.displaySafe) — no provider offered an update for this.", systemImage: "questionmark.circle")
                        }
                    }
                }

                ForEach(plan.providers.filter(\.hasErrors), id: \.provider) { provider in
                    Section(provider.displayName) {
                        Text("\(provider.displayName) could not be fully checked, so this plan may be missing items.")
                            .foregroundStyle(.secondary)
                        ForEach(Array(provider.errors.enumerated()), id: \.offset) { _, failure in
                            ErrorRow(error: failure.error)
                        }
                    }
                }

                if !plan.planned.isEmpty {
                    Section("This batch") {
                        ForEach(PlanEffects(model.itemsThatWouldRun.isEmpty ? plan.planned : model.itemsThatWouldRun).rows, id: \.title) { row in
                            PlanEffectLabel(symbol: row.symbol, title: row.title, value: row.value, isNoteworthy: row.noteworthy)
                        }
                    }

                    Section {
                        DisclosureGroup("Show Commands", isExpanded: commandsShown) {
                            // A grouped Form centres what a disclosure group
                            // contains, and a command that does not start at
                            // the left margin is hard to read and harder to
                            // compare with the one above it.
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(plan.planned) { update in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(update.candidate.displayName.displaySafe).font(.callout.weight(.medium))
                                        ForEach(Array(update.plan.steps.enumerated()), id: \.offset) { _, step in
                                            CommandView(step: step)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ProgressView("Working out what MacUp would run…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func plannedSections(_ plan: PlanReport) -> some View {
        let allowed = plan.allowed
        let waiting = plan.needingConfirmation
        if !allowed.isEmpty {
            Section("Will update") {
                ForEach(allowed) { update in
                    PlannedRow(update: update)
                }
            }
        }
        if !waiting.isEmpty {
            Section {
                ForEach(waiting) { update in
                    Toggle(isOn: confirmation(for: update.item)) {
                        PlannedRow(update: update)
                    }
                    .disabled(model.isApplying)
                    .accessibilityLabel("Confirm \(update.candidate.displayName)")
                    .accessibilityHint(update.decision.reason)
                }
            } header: {
                Text("Needs your confirmation")
            } footer: {
                Text("An item you leave unconfirmed is not updated, and MacUp records that it was left alone.")
                    .leadingFooter()
            }
        }
    }

    private func confirmation(for item: PackageID) -> Binding<Bool> {
        Binding(
            get: { model.confirmedItems.contains(item) },
            set: { model.setConfirmed($0, for: item) }
        )
    }

    private var progress: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(progressLine).font(.headline)
                }
                // Refreshed on a timer rather than on every line of output, so
                // a build printing thousands of lines cannot swamp the window.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        if let since = model.runningSince {
                            Text("Running for \(Self.elapsed(since: since, now: context.date)).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        let lines = model.runningOutput.recent
                        if !lines.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Latest output: \(lines.last ?? "")")
                        }
                    }
                }
                if let note = longRunningNote {
                    Label(note, systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isStopRequested {
                    Label(stoppingNote, systemImage: "hand.raised")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if total > 1 {
                    ProgressView(value: Double(finished), total: Double(total))
                        .accessibilityLabel("\(finished) of \(total) finished")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var total: Int { max(model.itemsThatWouldRun.count, model.startedItems.count) }

    /// Items whose command has ended. The running one has started but not
    /// finished, so a bar never shows a batch as done while it is working.
    private var finished: Int {
        max(0, model.startedItems.count - (model.runningItem == nil ? 0 : 1))
    }

    private var runningCandidate: UpdateCandidate? {
        guard let running = model.runningItem else { return nil }
        return model.updatePlan?.planned.first { $0.item == running }?.candidate
    }

    /// Said up front when the provider has told MacUp this will be slow, so
    /// a long wait reads as expected rather than as a hang.
    private var longRunningNote: String? {
        guard let candidate = runningCandidate, candidate.signals.contains(.buildsFromSource) else { return nil }
        return "Homebrew is compiling \(candidate.displayName.displaySafe) from source. That can take an hour or more, and it is working even when the output is quiet."
    }

    private var stoppingNote: String {
        let name = model.runningItem.map { $0.name.displaySafe } ?? "the current item"
        return "MacUp will stop once \(name) finishes, and nothing after it will start. It does not cut the running command short: stopping a package manager part-way can leave the item with no usable version."
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(0, now.timeIntervalSince(start))) ?? ""
    }

    private var progressLine: String {
        guard let running = model.runningItem else {
            return model.startedItems.isEmpty
                ? "Waiting for the first command to start."
                : "Finishing up."
        }
        return total > 1
            ? "Updating \(running.name.displaySafe) (\(model.startedItems.count) of \(total))"
            : "Updating \(running.name.displaySafe)"
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ report: ExecutionReport) -> some View {
        if !report.executed.isEmpty {
            Section("Attempted") {
                ForEach(report.executed) { executed in
                    ExecutedRow(executed: executed)
                }
            }
        }
        if !report.skipped.isEmpty {
            Section("Left alone") {
                ForEach(report.skipped) { skip in
                    SkipRow(skip: skip)
                }
            }
        }
        Section {
            Text("Every attempt above, and every reason MacUp left something alone, is in History.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if model.isApplying {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(progressLine).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isApplying {
                // No Escape shortcut: a key pressed to close a sheet must not
                // be the one that changes what an update does.
                Button(model.isStopRequested ? "Stopping After This Item" : "Stop After This Item") { model.cancelApply() }
                    .disabled(model.isStopRequested)
                    .help("Start nothing further. The update running now finishes first, because stopping a package manager part-way can break what it is installing.")
            } else if model.executionReport != nil {
                Button("Done") { model.endReview() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Cancel") { model.endReview() }
                    .keyboardShortcut(.cancelAction)
                Button(applyTitle) { model.applyReviewedPlan() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.itemsThatWouldRun.isEmpty)
                    .help(model.itemsThatWouldRun.isEmpty
                        ? "There is nothing MacUp is allowed to change in this batch."
                        : "Run exactly the commands listed above")
            }
        }
        .padding(20)
    }

    private var applyTitle: String {
        let count = model.itemsThatWouldRun.count
        return count == 1 ? "Apply 1 Change" : "Apply \(count) Changes"
    }
}

/// One item a plan would change, with the risk and the reason policy gave.
private struct PlannedRow: View {
    let update: PlannedUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(update.candidate.displayName.displaySafe).fontWeight(.medium)
                Spacer(minLength: 8)
                Text("\(update.plan.currentVersion?.raw.displaySafe ?? "Unknown") → \(update.plan.proposedVersion.raw.displaySafe)")
                    .monospacedDigit()
            }
            HStack(spacing: 10) {
                Label(update.provider.displayName, systemImage: update.provider.symbolName)
                PolicyLabel(policy: update.decision.policy)
                RiskLabel(level: update.plan.risk.level)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(update.decision.reason.displaySafe)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(update.candidate.displayName), \(update.plan.currentVersion?.raw ?? "unknown version") "
                + "to \(update.plan.proposedVersion.raw), \(update.provider.displayName), "
                + "\(update.decision.policy.displayName), \(update.plan.risk.level.displayName). \(update.decision.reason)"
        )
    }
}

/// One item MacUp will not change, and why. Always shown: a decision the user
/// made is information, not clutter (CLAUDE.md §21).
private struct SkipRow: View {
    let skip: SkippedUpdate

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(skip.displayName.displaySafe).fontWeight(.medium)
                    Spacer(minLength: 8)
                    if let current = skip.currentVersion {
                        Text("\(current.displaySafe) → \(skip.proposedVersion?.displaySafe ?? "unknown")")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Label(skip.provider.displayName, systemImage: skip.provider.symbolName)
                    if let policy = skip.decision?.policy {
                        PolicyLabel(policy: policy)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(skip.reason.displayPath)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let suggestion = skip.error?.recoverySuggestion {
                    Text(suggestion.displaySafe).font(.callout).foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(skip.displayName) was not changed. \(skip.reason)")
    }
}

/// One item MacUp attempted, with the honest result.
private struct ExecutedRow: View {
    let executed: ExecutedUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(executed.displayName.displaySafe).fontWeight(.medium)
                Spacer(minLength: 8)
                Text(versions).monospacedDigit().foregroundStyle(.secondary)
            }
            OutcomeLabel(outcome: executed.result.outcome, verification: executed.verification?.outcome)
                .font(.callout)
            if let verification = executed.verification {
                Text(verification.message.displaySafe)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = executed.result.error {
                ErrorRow(error: error)
            }
            Text(duration).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var versions: String {
        let target = executed.plan.proposedVersion.raw.displaySafe
        guard let after = executed.verification?.observedVersion?.displaySafe else {
            return "\(executed.plan.currentVersion?.raw.displaySafe ?? "Unknown") → \(target)"
        }
        return "\(executed.plan.currentVersion?.raw.displaySafe ?? "Unknown") → \(target) → now \(after)"
    }

    private var duration: String {
        let seconds = executed.result.finishedAt.timeIntervalSince(executed.result.startedAt)
        return "Took \(seconds.formatted(.number.precision(.fractionLength(1)))) seconds"
    }
}

/// The exact command for one item, with no way to run it from here.
struct CommandSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.commandItem.map { "Command for \($0.name.displaySafe)" } ?? "Command")
                    .font(.title2.weight(.semibold))
                // Paths are shown with the home directory as ~, here as
                // everywhere else, so a screenshot of this window does not
                // carry the reader's user name.
                Text("The exact executable and arguments MacUp would pass to the operating system, with your home directory written as ~. Nothing runs from this window.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            Form {
                if let planned = model.commandPlan?.planned.first {
                    Section("Steps") {
                        ForEach(Array(planned.plan.steps.enumerated()), id: \.offset) { _, step in
                            CommandView(step: step)
                        }
                    }
                    Section("Rationale") {
                        Text(planned.plan.rationale.displaySafe)
                        Text(planned.decision.reason.displaySafe).foregroundStyle(.secondary)
                    }
                    Section("This change") {
                        ForEach(PlanEffects([planned]).rows, id: \.title) { row in
                            PlanEffectLabel(symbol: row.symbol, title: row.title, value: row.value, isNoteworthy: row.noteworthy)
                        }
                    }
                    if !planned.plan.verification.isEmpty {
                        Section("How MacUp will confirm it") {
                            ForEach(Array(planned.plan.verification.enumerated()), id: \.offset) { _, step in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.summary.displaySafe)
                                    if let invocation = step.invocation {
                                        Text(invocation.displayString.displayPath)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    Section("Can it be undone") {
                        Text(planned.plan.rollback.explanation.displaySafe)
                    }
                } else if let skip = model.commandPlan?.skipped.first {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MacUp has no command for \(skip.displayName.displaySafe).")
                                Text(skip.reason.displayPath).foregroundStyle(.secondary)
                                if let suggestion = skip.error?.recoverySuggestion {
                                    Text(suggestion.displaySafe)
                                }
                            }
                        } icon: {
                            Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } else if model.isPlanning {
                    ProgressView("Working out the command…")
                } else {
                    Text("MacUp did not produce a plan for this item.")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.dismissCommand() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 660)
    }
}
