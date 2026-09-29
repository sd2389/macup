import Foundation
import MacUpCore

/// What the menu bar lists under its headline.
struct MenuBarUpdates: Equatable {
    struct Entry: Equatable, Identifiable {
        let id: PackageID
        /// "mysql  9.7.1 → 26.7.0_2", display-safe.
        let title: String
        /// The same for VoiceOver, which reads "to" more clearly than an arrow.
        let accessibilityLabel: String
    }

    /// The first pending updates, in the order the Updates screen lists them.
    var entries: [Entry]
    /// Pending updates beyond the ones listed.
    var remaining: Int
    /// One line about the pending updates worth a look before anything else,
    /// or `nil` when none is.
    var attention: String?
    /// The update that line opens.
    var attentionItem: PackageID?

    /// "and 3 more", or `nil` when every pending update is listed.
    var remainingLine: String? { remaining > 0 ? "and \(remaining) more" : nil }
}

extension AppModel {
    /// How many pending updates the menu bar names before it says how many
    /// more there are. Past this a menu stops being something to glance at.
    static let menuBarUpdateLimit = 8

    /// The pending updates, for the menu bar: the same list as the top of the
    /// dashboard, so an update a rule leaves alone is counted in the lines
    /// above rather than listed as if it would run. Each one opens the
    /// Updates screen on that item, and none of them updates anything.
    var menuBarUpdates: MenuBarUpdates {
        let pending = pendingUpdates
        let entries = pending.prefix(Self.menuBarUpdateLimit).map { update in
            let from = (update.installedVersion?.raw ?? "unknown").displaySafe
            let to = update.availableVersion.raw.displaySafe
            let name = update.displayName.displaySafe
            return MenuBarUpdates.Entry(
                id: update.id,
                title: "\(name)  \(from) → \(to)",
                accessibilityLabel: "\(name), \(from) to \(to)"
            )
        }
        // An unfinished install blocks the update until someone repairs it,
        // and a build from source can hold the machine for an hour: both are
        // worth knowing before choosing what to review.
        // The same set the Updates screen's Needs Attention filter uses.
        let flagged = pending.filter(\.needsAttention)
        return MenuBarUpdates(
            entries: Array(entries),
            remaining: pending.count - entries.count,
            attention: Self.attentionLine(flagged),
            attentionItem: flagged.first?.id
        )
    }

    static func attentionLine(_ flagged: [UpdateCandidate]) -> String? {
        guard let first = flagged.first else { return nil }
        guard flagged.count == 1 else {
            let names = flagged.prefix(3).map(\.displayName.displaySafe).joined(separator: ", ")
            return "\(flagged.count) need attention: \(names)" + (flagged.count > 3 ? ", …" : "")
        }
        let name = first.displayName.displaySafe
        if first.signals.contains(.installationIncomplete) { return "\(name): an earlier install did not finish" }
        if first.signals.contains(.buildsFromSource) { return "\(name) will be compiled from source" }
        return "\(name) needs attention"
    }

    /// Shows one update on the Updates screen, selected, as the menu bar and
    /// the dashboard do.
    func reveal(_ item: PackageID) {
        selectedUpdate = item
        section = .updates
    }
}
