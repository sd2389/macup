import AppKit
import SwiftUI

/// The keyboard's way around MacUp: ⌘1 to ⌘6 open the sidebar's sections in
/// the order the sidebar lists them, from the View menu, and ⌘F searches the
/// Updates list. Each brings the main window forward, so they also work when
/// only the menu bar extra is showing.
struct NavigationCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(AppModel.Section.allCases.enumerated()), id: \.element) { index, section in
                if index < 9 {
                    Button(section.title) { show(section) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                } else {
                    Button(section.title) { show(section) }
                }
            }
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Updates…") {
                model.searchUpdates()
                bringForward()
            }
            .keyboardShortcut("f")
        }
    }

    private func show(_ section: AppModel.Section) {
        model.section = section
        bringForward()
    }

    private func bringForward() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
