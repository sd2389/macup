import MacUpCore
import SwiftUI

/// Everything MacUp can do for you, each one a row you can turn on.
///
/// One screen, one row per feature, one switch each. Settings stays what it
/// is: where the configuration lives and what is in it.
struct FeaturesView: View {
    @Environment(AppModel.self) private var model

    /// Side by side while the window is wide enough for the text to stay
    /// readable, one column when it is not.
    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 460), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                AutomaticChecksFeature()
                ApprovalFeature()
                FaceMatchFeature()
            }
            .padding(20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            model.loadConfiguration()
            model.loadFaceEnrollment()
            await model.refreshScheduleStatus()
        }
        .sheet(isPresented: .constant(model.isEnrollingFace)) {
            FaceEnrollmentSheet()
        }
    }
}

/// One feature: what it is, a switch, and its settings once it is on.
///
/// A card rather than a form section, so the description sits with the thing
/// it describes and the settings are visibly part of the same feature.
private struct FeatureCard<Detail: View>: View {
    let symbol: String
    let title: String
    let summary: String
    @Binding var isOn: Bool
    var isBusy = false
    /// False when this Mac cannot do the thing at all, so the switch is not
    /// offered as though it could. ``state`` says why.
    var canChange = true
    var state: String?
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 19))
                        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 22)
                        .accessibilityHidden(true)
                    Text(title).font(.headline)
                    Spacer(minLength: 12)
                    Toggle(title, isOn: $isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(isBusy || !canChange)
                        .accessibilityLabel(title)
                        .accessibilityHint(canChange ? "" : (state ?? ""))
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)

            if state != nil || hasDetail {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let state {
                        Text(state)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    detail
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var hasDetail: Bool { !(Detail.self == EmptyView.self) }
}

// MARK: - Automatic checks

private struct AutomaticChecksFeature: View {
    @Environment(AppModel.self) private var model
    @State private var draft = MacUpConfiguration.ScheduleSettings()
    @State private var loaded = false

    var body: some View {
        FeatureCard(
            symbol: "clock",
            title: "Check automatically",
            summary: "Look for updates on a schedule. The check only reports; it never installs anything.",
            isOn: enabled,
            isBusy: model.isChangingSchedule,
            state: state
        ) {
            if draft.enabled {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("How often").foregroundStyle(.secondary)
                        Picker("How often", selection: $draft.frequency) {
                            Text("Daily").tag(MacUpConfiguration.ScheduleSettings.Frequency.daily)
                            Text("Weekly").tag(MacUpConfiguration.ScheduleSettings.Frequency.weekly)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if draft.frequency == .weekly {
                        GridRow {
                            Text("Day").foregroundStyle(.secondary)
                            Picker("Day", selection: weekday) {
                                ForEach(MacUpConfiguration.ScheduleSettings.Weekday.allCases, id: \.self) { day in
                                    Text(day.rawValue.capitalizedFirst).tag(day)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    GridRow {
                        Text("Time").foregroundStyle(.secondary)
                        DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .fixedSize()
                    }
                }
                if hasUnsavedChanges {
                    Button("Apply Changes") { Task { await model.applySchedule(draft) } }
                        .disabled(model.isChangingSchedule)
                }
            }
            ForEach(model.scheduleStatus?.warnings ?? [], id: \.self) { warning in
                Label(warning.displaySafe, systemImage: "exclamationmark.triangle")
            }
            if let problem = model.scheduleProblem {
                Label(problem.displaySafe, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .onAppear { reload() }
        .onChange(of: model.configuration?.configuration.schedule) { reload() }
    }

    private func reload() {
        guard !model.isChangingSchedule else { return }
        draft = model.scheduleSettings
        loaded = true
    }

    /// Turning it on or off applies at once; the details below get one Apply,
    /// so changing a time cannot ask for approval on every keystroke.
    private var enabled: Binding<Bool> {
        Binding(
            get: { draft.enabled },
            set: { newValue in
                draft.enabled = newValue
                var settings = draft
                settings.enabled = newValue
                Task { await model.applySchedule(settings) }
            }
        )
    }

    private var hasUnsavedChanges: Bool {
        loaded && draft != model.scheduleSettings
    }

    private var state: String? {
        guard let status = model.scheduleStatus else { return nil }
        if status.isActive, let next = status.nextRun {
            return "Next check \(next.formatted(date: .abbreviated, time: .shortened))."
        }
        if draft.enabled && !status.agentInstalled { return "Not running yet." }
        return nil
    }

    private var time: Binding<Date> {
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

    private var weekday: Binding<MacUpConfiguration.ScheduleSettings.Weekday> {
        Binding(get: { draft.resolvedWeekday }, set: { draft.weekday = $0 })
    }
}

// MARK: - Approval

private struct ApprovalFeature: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FeatureCard(
            symbol: "lock.shield",
            title: "Ask before changing anything",
            summary: "macOS asks you to confirm before MacUp changes a setting. It never sees your fingerprint or your password.",
            isOn: enabled,
            isBusy: model.isChangingSecurity,
            // What this Mac will really accept, not just the name of a sensor
            // it may not have: macOS takes the login password, and an unlocked
            // Apple Watch when one is paired.
            state: model.biometricCapability.summary
        ) {
            if let problem = model.securityProblem {
                Label(problem.displaySafe, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            Text("A confirmation, not a lock: MacUp runs as you, and so do brew, npm, and mise.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.securitySettings.requireApproval },
            set: { newValue in
                var settings = model.securitySettings
                settings.requireApproval = newValue
                Task { await model.applySecurity(settings) }
            }
        )
    }
}

// MARK: - Face match

private struct FaceMatchFeature: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FeatureCard(
            symbol: "faceid",
            title: "Face match",
            summary: "Use the camera to approve a change instead of Touch ID. A photograph of you passes it, so it is a shortcut, not a lock.",
            isOn: enabled,
            isBusy: model.isEnrollingFace,
            // Nothing to turn on when the camera cannot be opened, and the
            // switch says so by not pretending otherwise.
            canChange: model.cameraReadiness.canUse || model.faceEnrollment != nil,
            state: state
        ) {
            HStack {
                Button(model.faceEnrollment == nil ? "Enroll Face…" : "Enroll Again…") {
                    model.startFaceEnrollment()
                }
                // Offering a button that cannot work would be a lie; the
                // reason is stated above it instead.
                .disabled(!model.cameraReadiness.canUse || model.isEnrollingFace)
                .help(model.cameraReadiness.problem ?? "Take a few pictures and remember what they look like.")
                Button("Forget Face") { model.forgetFace() }
                    .disabled(model.faceEnrollment == nil || model.isEnrollingFace)
            }
            if let spread = model.faceEnrollment?.sampleSpread, Double(spread) >= model.securitySettings.faceMatchThreshold {
                Label(
                    "Your own samples vary more than the threshold allows, so this will usually fail to recognise you. Enroll again in even light.",
                    systemImage: "exclamationmark.triangle"
                )
            }
            if let problem = model.faceProblem {
                Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
            }
            if model.faceEnrollment != nil && !model.securitySettings.requireApproval {
                Text("MacUp is not asking for approval, so this does nothing yet. Turn on “Ask before changing anything” above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What is true of this Mac right now. A camera MacUp cannot use is said
    /// here, before anyone presses a button and waits for a refusal.
    private var state: String? {
        if let problem = model.cameraReadiness.problem { return problem }
        guard let enrollment = model.faceEnrollment else { return "No face enrolled yet." }
        return "Enrolled \(enrollment.signatures.count) samples on \(enrollment.createdAt.formatted(date: .abbreviated, time: .shortened))."
    }

    /// The switch cannot be on without an enrolled face, so turning it on with
    /// none enrolled starts enrolment rather than setting a flag that does
    /// nothing.
    private var enabled: Binding<Bool> {
        Binding(
            get: { model.securitySettings.faceUnlock && model.faceEnrollment != nil },
            set: { newValue in
                if newValue && model.faceEnrollment == nil {
                    model.startFaceEnrollment()
                    return
                }
                if newValue {
                    var settings = model.securitySettings
                    settings.faceUnlock = true
                    Task { await model.applySecurity(settings) }
                } else {
                    model.forgetFace()
                }
            }
        )
    }
}
