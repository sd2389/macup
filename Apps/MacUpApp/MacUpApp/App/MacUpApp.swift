import AppKit
import MacUpCore
import SwiftUI

@main
struct MacUpApp: App {
    @State private var model = AppModel()

    var body: some Scene {
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
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Label("Dashboard", systemImage: "rectangle.grid.2x2")
                    .tag(AppModel.Section.dashboard)
                Label("Updates", systemImage: "arrow.down.circle")
                    .badge(model.updateCount)
                    .tag(AppModel.Section.updates)
                Label("Doctor", systemImage: "stethoscope")
                    .badge(model.attentionCount)
                    .tag(AppModel.Section.doctor)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(AppModel.Section.history)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch model.section ?? .dashboard {
            case .dashboard: DashboardView()
            case .updates: UpdatesView()
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
        }
        .task {
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
