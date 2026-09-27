import AppKit
import MacUpCore
import SwiftUI

/// The configuration, and the one part of it MacUp can change today: the
/// scheduled read-only check. Editing the rest arrives with update policies.
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

            ScheduleSection()

            Section("Privacy") {
                Text("MacUp has no telemetry and no account. Nothing about your Mac leaves it, except the requests your package managers make themselves.")
            }

            Section("Diagnostics") {
                LabeledContent("Login shell", value: model.shell?.displayPath ?? "Not read yet")
                LabeledContent("Shell environment", value: model.environmentProblem == nil ? (model.shell == nil ? "Not read yet" : "Read successfully") : "Could not be read")
            }

            Section {
                Text("Apart from scheduling, settings are read-only in this version. To change the rest, edit the configuration file.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
        .onAppear {
            model.loadConfiguration()
            Task { await model.refreshScheduleStatus() }
        }
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


/// Turns the scheduled read-only check on and off.
///
/// Changes are applied deliberately rather than as a side effect of moving a
/// picker: turning this on installs a launchd agent, so the exact command it
/// will run is shown first and nothing happens until Apply.
private struct ScheduleSection: View {
    @Environment(AppModel.self) private var model
    @State private var draft = MacUpConfiguration.ScheduleSettings()
    @State private var loaded = false

    var body: some View {
        Section("Scheduling") {
            Toggle("Check automatically", isOn: $draft.enabled)
                .help("Runs the same read-only check on a schedule. It never installs or upgrades anything.")

            if draft.enabled {
                Picker("How often", selection: $draft.frequency) {
                    Text("Daily").tag(MacUpConfiguration.ScheduleSettings.Frequency.daily)
                    Text("Weekly").tag(MacUpConfiguration.ScheduleSettings.Frequency.weekly)
                }
                if draft.frequency == .weekly {
                    Picker("Day", selection: weekdayBinding) {
                        ForEach(MacUpConfiguration.ScheduleSettings.Weekday.allCases, id: \.self) { day in
                            Text(day.rawValue.capitalizedFirst).tag(day)
                        }
                    }
                }
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                Toggle("Refresh package lists first", isOn: $draft.refresh)
                    .help("Without this, Homebrew results come from local metadata that may be weeks old. A refresh updates package lists only; it never upgrades a package.")
            }

            // Shown only while the schedule is on, so the off state stays a
            // toggle and one line, but the exact command is never hidden from
            // someone about to install it.
            if draft.enabled {
                if let command {
                    LabeledContent("Will run") {
                        Text(command.displayPath)
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                    }
                } else {
                    Label(
                        "MacUp could not find the macup command to schedule.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }

            ForEach(statusLines, id: \.self) { line in
                Text(line).foregroundStyle(.secondary).font(.callout)
            }
            ForEach(model.scheduleStatus?.warnings ?? [], id: \.self) { warning in
                Label(warning.displaySafe, systemImage: "exclamationmark.triangle")
            }
            if let problem = model.scheduleProblem {
                Label(problem.displaySafe, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }

            HStack {
                Button(applyTitle) { Task { await model.applySchedule(draft) } }
                    .disabled(!canApply)
                if model.isChangingSchedule { ProgressView().controlSize(.small) }
                Spacer()
                Text("A scheduled check changes nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { reload() }
        .onChange(of: model.configuration?.configuration.schedule) { reload() }
    }

    private func reload() {
        guard !loaded || !model.isChangingSchedule else { return }
        draft = model.scheduleSettings
        loaded = true
    }

    private var command: String? {
        model.scheduleStatus?.command ?? model.scheduledExecutable().map { $0 + " check --save-state" }
    }

    private var canApply: Bool {
        guard !model.isChangingSchedule else { return false }
        guard draft != model.scheduleSettings || draft.enabled != (model.scheduleStatus?.agentInstalled ?? false) else {
            return false
        }
        return !draft.enabled || model.scheduledExecutable() != nil
    }

    private var applyTitle: String {
        let installed = model.scheduleStatus?.agentInstalled == true
        if draft.enabled { return installed ? "Update Schedule" : "Turn On" }
        // With nothing installed there is nothing to turn off; the button is
        // disabled anyway, so it names the action the switch would enable.
        return installed ? "Turn Off" : "Turn On"
    }

    private var statusLines: [String] {
        guard let status = model.scheduleStatus else { return [] }
        var lines: [String] = []
        if status.isActive, let next = status.nextRun {
            lines.append("Next check \(next.formatted(date: .abbreviated, time: .shortened)).")
        } else if !status.agentInstalled {
            lines.append("No check is scheduled.")
        }
        if let last = status.lastCheck {
            if last.unreadable {
                lines.append("The last saved report could not be read.")
            } else {
                var text = "Last scheduled check"
                if let finished = last.finishedAt {
                    text += " \(finished.formatted(date: .abbreviated, time: .shortened))"
                }
                if let updates = last.updatesAvailable {
                    text += ": \(updates == 1 ? "1 update" : "\(updates) updates")"
                }
                lines.append(text + ".")
            }
        }
        return lines
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let parts = (try? LaunchAgent.clockTime(draft.time)) ?? (hour: 23, minute: 0)
                return Calendar.current.date(bySettingHour: parts.hour, minute: parts.minute, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.time = String(format: "%02d:%02d", components.hour ?? 23, components.minute ?? 0)
            }
        )
    }

    private var weekdayBinding: Binding<MacUpConfiguration.ScheduleSettings.Weekday> {
        Binding(get: { draft.resolvedWeekday }, set: { draft.weekday = $0 })
    }
}
