import AppKit
import MacUpCore
import SwiftUI

/// MacUp's windows, menu bar, and settings.
///
/// The `@main` entry point is in the executable target (Apps/MacUpApp/Main);
/// everything it needs is here, where tests can reach it.
public struct MacUpRoot: App {
    @State private var model = AppModel()

    public init() {}

    public var body: some Scene {
        Window("MacUp", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Check Now") { Task { await model.checkNow() } }
                    .keyboardShortcut("r")
                    .disabled(model.isChecking)
            }
            NavigationCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.status.symbolName)
                .accessibilityLabel("MacUp, \(model.status.headline)")
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                    .tag(AppModel.Section.dashboard)
                Label("Providers", systemImage: "shippingbox")
                    .tag(AppModel.Section.providers)
                Label("Updates", systemImage: "arrow.down.circle")
                    .badge(model.updateCount)
                    .tag(AppModel.Section.updates)
                Label("Features", systemImage: "switch.2")
                    .tag(AppModel.Section.features)
                Label("Doctor", systemImage: "stethoscope")
                    .badge(model.attentionCount)
                    .tag(AppModel.Section.doctor)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(AppModel.Section.history)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            // Settings belongs in the primary navigation (UX_SPEC), not only
            // behind ⌘, and the menu bar, where people were not finding it.
            .safeAreaInset(edge: .bottom) {
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        } detail: {
            switch model.section ?? .dashboard {
            case .dashboard: DashboardView()
            case .providers: ProvidersView()
            case .updates: UpdatesView()
            case .features: FeaturesView()
            case .doctor: DoctorView()
            case .history: HistoryView()
            }
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .help("Checking for updates")
                } else {
                    Button {
                        Task { await model.checkNow() }
                    } label: {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                    .help("Check for updates. Checking never changes anything.")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { openSettings() } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("MacUp's settings, including scheduled checks")
            }
        }
        .task {
            #if DEBUG
            if FaceCheck.requested {
                await FaceCheck.run()
                return
            }
            #endif
            if model.report == nil || model.report?.cancelled == true { await model.checkNow() }
            #if DEBUG
            if let directory = Snapshots.directory {
                await Snapshots.capture(model: model, openSettings: { openSettings() }, into: directory)
            }
            #endif
        }
    }

    private var subtitle: String {
        if model.isChecking { return "Checking…" }
        guard let report = model.report else { return "" }
        return "Checked at \(report.finishedAt.formatted(date: .omitted, time: .shortened))"
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status.headline)
        ForEach(model.status.reasons, id: \.self) { reason in
            Text(reason)
        }
        // The decisions the user already made, so the menu's count is never
        // quietly larger than what Review Updates would actually change
        // (CLAUDE.md §21). There is still no blind "update everything" here.
        ForEach(decisionLines, id: \.self) { line in
            Text(line)
        }
        if let report = model.report {
            Text("Last checked at \(report.finishedAt.formatted(date: .omitted, time: .shortened))")
        }
        // Each pending update by name, opening it in the Updates screen.
        MenuBarUpdateList()
        Divider()
        Button("Review Updates…") { show(.updates) }
            .disabled(model.updateCount == 0)
        Button("Check Now") { Task { await model.checkNow() } }
            .disabled(model.isChecking)
        Divider()
        Button("Open MacUp") { show(.dashboard) }
        Button("History") { show(.history) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit MacUp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Only the counts MacUp has. A zero is left out rather than shown as a
    /// reassuring nothing.
    private var decisionLines: [String] {
        var lines: [String] = []
        switch model.updatesNeedingConfirmation {
        case 0: break
        case 1: lines.append("1 needs your confirmation")
        case let count: lines.append("\(count) need your confirmation")
        }
        if model.ignoredUpdateCount > 0 {
            lines.append("\(model.ignoredUpdateCount) ignored by your rules")
        }
        if model.pinnedUpdateCount > 0 {
            lines.append("\(model.pinnedUpdateCount) held at the current version")
        }
        if model.skippedUpdateCount > 0 {
            lines.append("\(model.skippedUpdateCount) skipped until a different version is offered")
        }
        // Only when a check will really happen: an agent that is installed and
        // loaded, not merely a schedule written in the configuration.
        if let status = model.scheduleStatus, status.isActive, let next = status.nextRun {
            lines.append("Next check \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        return lines
    }

    private func show(_ section: AppModel.Section) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
