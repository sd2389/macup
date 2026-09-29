import AppKit
import MacUpCore
import SwiftUI

/// The pending updates in the menu bar, each opening the main window on that
/// item in the Updates screen.
///
/// Every entry only shows something. The menu still has no action that
/// updates anything, let alone everything: a change happens in a review,
/// where each one and each item left alone is visible (CLAUDE.md §21).
struct MenuBarUpdateList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let updates = model.menuBarUpdates
        if !updates.entries.isEmpty {
            Divider()
            ForEach(updates.entries) { entry in
                Button(entry.title) { open(entry.id) }
                    .accessibilityLabel(entry.accessibilityLabel)
            }
            if let more = updates.remainingLine {
                Button(more) { open(nil) }
            }
            if let attention = updates.attention {
                Button { open(updates.attentionItem) } label: {
                    Label(attention, systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private func open(_ item: PackageID?) {
        if let item {
            model.reveal(item)
        } else {
            model.section = .updates
        }
        openWindow(id: "main")
        NSApp.activate()
    }
}
