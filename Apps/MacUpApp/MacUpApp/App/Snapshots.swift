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
        let sections: [(AppModel.Section, String)] = [(.dashboard, "dashboard"), (.updates, "updates"), (.doctor, "doctor"), (.history, "history")]
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (section, name) in sections {
                model.section = section
                try? await Task.sleep(for: .milliseconds(700))
                if let main { write(main, to: directory, named: "\(name)-\(suffix).png") }
            }
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
