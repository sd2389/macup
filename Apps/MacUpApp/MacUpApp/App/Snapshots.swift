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
            (.dashboard, "dashboard"), (.updates, "updates"), (.features, "features"),
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
            await captureSheets(model: model, main: main, into: directory, suffix: suffix)
        }
        openSettings()
        try? await Task.sleep(for: .milliseconds(1200))
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.frame.width > 300 }) {
            write(settings, to: directory, named: "settings-dark.png")
            NSApp.appearance = NSAppearance(named: .aqua)
            try? await Task.sleep(for: .milliseconds(700))
            write(settings, to: directory, named: "settings-light.png")
        }
        NSApp.terminate(nil)
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
