#if DEBUG
import AppKit
import MacUpCore
import SwiftUI

/// Debug-only: `MacUp --snapshot-dir <dir>` runs a check, renders each screen
/// of its own windows to PNG, and quits. An app can always capture its own
/// windows, so this needs no Screen Recording permission. Used to review the
/// UI from scripts; not compiled into release builds. The directory must be
/// private (see ``PrivateDirectory``); a shared one such as `/tmp/x` is refused.
enum Snapshots {
    static var directory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--snapshot-dir"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    @MainActor
    static func capture(model: AppModel, openSettings: () -> Void, into url: URL) async {
        let directory: PrivateDirectory
        do {
            directory = try PrivateDirectory(url.path)
        } catch {
            FileHandle.standardError.write(Data("MacUp snapshots: \(error)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        NSApp.activate()
        let main = NSApp.windows.first { $0.title == "MacUp" && $0.isVisible }
        main?.makeKeyAndOrderFront(nil)
        let sections: [(AppModel.Section, String)] = [
            (.dashboard, "dashboard"), (.providers, "providers"), (.updates, "updates"), (.features, "features"),
            (.doctor, "doctor"), (.history, "history"),
        ]
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (section, name) in sections {
                model.section = section
                try? await Task.sleep(for: .milliseconds(700))
                // Doctor runs a second, fuller check of its own, so waiting
                // for it is the difference between photographing the findings
                // and photographing a spinner.
                var waited = 0
                while model.isDiagnosing && waited < 60 {
                    try? await Task.sleep(for: .milliseconds(250))
                    waited += 1
                }
                if let main { write(main, to: directory, named: "\(name)-\(suffix).png") }
            }
            // History narrowed to one item, as the Updates screen's "Show All
            // in History" opens it. Reading the file is all this does.
            if let item = model.history?.entries.first?.item {
                model.showHistory(for: item)
                try? await Task.sleep(for: .milliseconds(700))
                if let main { write(main, to: directory, named: "history-item-\(suffix).png") }
                model.showAllHistory()
            }
            await captureFilteredUpdates(model: model, main: main, into: directory, suffix: suffix)
            await captureSheets(model: model, main: main, into: directory, suffix: suffix)
        }
        openSettings()
        try? await Task.sleep(for: .milliseconds(1200))
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.frame.width > 300 }) {
            write(settings, to: directory, named: "settings-dark.png")
            NSApp.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(700))
            write(settings, to: directory, named: "settings-light.png")
            await captureDiagnosticsExport(model: model, settings: settings, into: directory)
        }
        NSApp.terminate(nil)
    }

    /// The Export Diagnostics sheet of the Settings window, in both
    /// appearances. Opening it gathers, which is a read-only check and Doctor;
    /// nothing here presses Save, and nothing here ever will.
    @MainActor
    private static func captureDiagnosticsExport(
        model: AppModel,
        settings: NSWindow,
        into directory: PrivateDirectory
    ) async {
        model.beginDiagnosticsExport()
        await model.diagnosticsExport?.waitUntilGathered()
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = settings.attachedSheet { write(sheet, to: directory, named: "diagnostics-\(suffix).png") }
        }
        model.endDiagnosticsExport()
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The two sheets the Updates screen can open, which are windows of their
    /// own and so are not captured by photographing the main one.
    ///
    /// Both are read-only: opening a review builds a plan, and building a plan
    /// runs nothing. Nothing here presses Apply, and nothing here ever will —
    /// a snapshot run must be as safe to start as `macup check`.
    @MainActor
    private static func captureSheets(
        model: AppModel,
        main: NSWindow?,
        into directory: PrivateDirectory,
        suffix: String
    ) async {
        guard let item = model.report?.updates.first?.id else { return }
        model.section = .updates

        await model.reviewUpdates()
        try? await Task.sleep(for: .milliseconds(900))
        if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "review-\(suffix).png") }

        // What the sheet shows while an update runs, and after Stop. Only the
        // model's display state is set; no command is started.
        if let running = model.updatePlan?.planned.first?.item {
            let output = ["==> Upgrading \(running.name)", "==> Downloading and verifying", "==> Installing \(running.name)"]
            model.showRunningForSnapshot(running, output: output, since: Date().addingTimeInterval(-95), stopRequested: false)
            try? await Task.sleep(for: .milliseconds(1200))
            if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "review-running-\(suffix).png") }
            model.showRunningForSnapshot(running, output: output, since: Date().addingTimeInterval(-95), stopRequested: true)
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "review-stopping-\(suffix).png") }
            model.endRunningForSnapshot()
        }
        model.endReview()
        try? await Task.sleep(for: .milliseconds(500))

        // One item with its commands open, because the command list is the
        // half of the sheet that would be easiest to get wrong unnoticed, and
        // a one-item review is short enough to fit on screen.
        model.reviewShowsCommands = true
        await model.reviewUpdates([item])
        try? await Task.sleep(for: .milliseconds(900))
        if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "review-commands-\(suffix).png") }
        model.reviewShowsCommands = false
        model.endReview()
        try? await Task.sleep(for: .milliseconds(500))

        await model.showCommand(for: item)
        try? await Task.sleep(for: .milliseconds(900))
        if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "command-\(suffix).png") }
        model.dismissCommand()
        try? await Task.sleep(for: .milliseconds(500))
    }

    /// The Updates screen narrowed and reordered: a filter that hides part of
    /// this Mac's list (at the window's size and at its narrowest), the list
    /// sorted by risk, the search field focused as ⌘F leaves it, and a search
    /// that matches nothing. Only the screen's own state changes; nothing runs.
    @MainActor
    private static func captureFilteredUpdates(
        model: AppModel,
        main: NSWindow?,
        into directory: PrivateDirectory,
        suffix: String
    ) async {
        guard let main, let updates = model.report?.updates, !updates.isEmpty else { return }
        model.section = .updates
        let policies = model.decisions.mapValues(\.policy)
        // The first filter that both shows and hides something here, so the
        // picture has a hidden count in it whatever this Mac has to update.
        let filters = [UpdateFilter(needsAttentionOnly: true)]
            + RiskLevel.allCases.map { UpdateFilter(riskLevels: [$0]) }
            + [UpdatePolicy.auto, .ask, .ignore, .pin].map { UpdateFilter(policies: [$0]) }
            + ProviderID.known.map { UpdateFilter(providers: [$0]) }
        let filter = filters.first { filter in
            let listing = filter.apply(to: updates, sortedBy: .provider, effectivePolicies: policies)
            return !listing.shown.isEmpty && listing.hiddenCount > 0
        }
        // One change at a time, with a pause after each: resizing the window
        // and replacing the list's rows in the same turn is something only
        // this script does, and AppKit's table complains about it.
        let settle = { try? await Task.sleep(for: .milliseconds(700)) }

        if let filter {
            model.updateFilter = filter
            model.selectedUpdate = model.updateListing.shown.first?.id
            await settle()
            write(main, to: directory, named: "updates-filtered-\(suffix).png")

            let frame = main.frame
            main.setFrame(NSRect(origin: frame.origin, size: NSSize(width: 820, height: frame.height)), display: true)
            await settle()
            write(main, to: directory, named: "updates-filtered-narrow-\(suffix).png")
            main.setFrame(frame, display: true)
            await settle()
        }

        model.showAllUpdates()
        await settle()
        model.updateSort = .risk
        await settle()
        write(main, to: directory, named: "updates-sorted-\(suffix).png")
        model.updateSort = .provider
        await settle()

        model.searchUpdates()
        model.updateFilter.searchText = String(updates[0].displayName.prefix(3))
        await settle()
        write(main, to: directory, named: "updates-search-\(suffix).png")

        model.updateFilter.searchText = "no update is called this"
        await settle()
        write(main, to: directory, named: "updates-no-match-\(suffix).png")

        model.isSearchingUpdates = false
        model.showAllUpdates()
        await settle()
    }

    @MainActor
    private static func write(_ window: NSWindow, to directory: PrivateDirectory, named name: String) {
        // The frame view (content view's superview) includes the title bar and toolbar.
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try directory.write(png, named: name)
        } catch {
            FileHandle.standardError.write(Data("MacUp snapshots: \(error)\n".utf8))
        }
    }
}
#endif
