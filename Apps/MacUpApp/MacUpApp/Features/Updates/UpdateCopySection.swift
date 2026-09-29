import AppKit
import MacUpCore
import SwiftUI

/// Copy Details and Copy Command for the update on screen.
///
/// Details is word for word what `macup explain` prints for the item, and
/// Command is the exact command line of its plan. Both come from MacUpCore,
/// built from the check on screen. Copying runs nothing, and it says it
/// happened in words that VoiceOver announces as well as shows.
struct UpdateCopySection: View {
    @Environment(AppModel.self) private var model
    let item: PackageID

    /// The explanation as things stand, so Copy Command can say in advance
    /// whether there is a command at all.
    @State private var explanation: ItemExplanation?
    @State private var confirmation: String?
    /// Which confirmation is showing, so an older one's timer cannot hide a
    /// newer one.
    @State private var confirmations = 0

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Button { copy(.details) } label: {
                    Label("Copy Details", systemImage: "doc.on.doc")
                }
                .help("Copy what macup explain prints for this item: versions, risk, policy, the exact command, and history")
                Button { copy(.command) } label: {
                    Label("Copy Command", systemImage: "terminal")
                }
                .disabled(explanation?.commandText == nil)
                .help(commandHelp)
                Spacer(minLength: 0)
            }
            if let confirmation {
                Label(confirmation, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        } footer: {
            Text("Copy Details copies what `macup explain` prints for this item. Copy Command copies the command line from its plan; MacUp runs it with the environment its provider needs, which a copied line does not carry. Copying runs nothing.")
                .leadingFooter()
        }
        .task(id: Freshness(item: item, checkedAt: model.report?.finishedAt, configuration: model.configuration)) {
            explanation = await model.explanation(for: item)
        }
    }

    /// What the explanation depends on: a new check or a changed rule means
    /// the one held here is out of date.
    private struct Freshness: Equatable {
        let item: PackageID
        let checkedAt: Date?
        let configuration: LoadedConfiguration?
    }

    private enum Copied {
        case details, command
    }

    private var commandHelp: String {
        guard let explanation else { return "Working out whether MacUp has a command for this item" }
        if explanation.commandText != nil { return "Copy the exact command line MacUp would run for this item" }
        if let skipped = explanation.skipped {
            return "MacUp would run nothing for this item: \(skipped.reason.displaySafe)"
        }
        return "MacUp would run nothing for this item."
    }

    /// Works the text out again at the moment of copying, so what lands on
    /// the clipboard is never older than the click.
    private func copy(_ kind: Copied) {
        Task {
            guard let fresh = await model.explanation(for: item) else {
                confirm("There is nothing to copy until MacUp has checked this Mac.")
                return
            }
            explanation = fresh
            switch kind {
            case .details:
                Clipboard.copy(model.detailsText(for: fresh))
                confirm("Details copied to the clipboard.")
            case .command:
                guard let command = fresh.commandText else {
                    confirm("MacUp would run nothing for this item, so there is no command to copy.")
                    return
                }
                Clipboard.copy(command)
                confirm("Command copied to the clipboard.")
            }
        }
    }

    private func confirm(_ message: String) {
        confirmations += 1
        let shown = confirmations
        withAnimation { confirmation = message }
        AccessibilityNotification.Announcement(message).post()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if confirmations == shown { withAnimation { confirmation = nil } }
        }
    }
}

/// The system clipboard. Only a click reaches it: the tests check the text
/// the model would copy, and never touch the pasteboard of the Mac they run on.
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
