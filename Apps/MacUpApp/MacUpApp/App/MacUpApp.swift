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
        if let report = model.report {
            Text("Last checked at \(report.finishedAt.formatted(date: .omitted, time: .shortened))")
        }
        // Only when a check will really happen: an agent that is installed and
        // loaded, not merely a schedule written in the configuration.
        if let status = model.scheduleStatus, status.isActive, let next = status.nextRun {
            Text("Next check \(next.formatted(date: .abbreviated, time: .shortened))")
        }
        Divider()
        Button("Review Updates…") { show(.updates) }
            .disabled(model.updateCount == 0)
        Button("Check Now") { Task { await model.checkNow() } }
            .disabled(model.isChecking)
        Divider()
        Button("Open MacUp") { show(.dashboard) }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit MacUp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ section: AppModel.Section) {
        model.section = section
        openWindow(id: "main")
        NSApp.activate()
    }
}
