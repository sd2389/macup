import Foundation

/// What one history entry says happened, in the words both the History screen
/// and `macup history` use (CLAUDE.md §16, §21).
///
/// Every entry gets exactly one headline, chosen from what happened to the
/// attempt and what MacUp read back afterwards taken together, so an entry
/// never shows two verdicts that repeat or contradict each other. The error
/// text recorded with an attempt is detail under the headline, not a second
/// status beside it.
///
/// A headline claims no more than its entry holds. An update is "confirmed"
/// only when MacUp read the new version back. An entry with nothing read back
/// — a skip, or an attempt recorded before MacUp read items back after one
/// that did not succeed — says what happened to the attempt and nothing about
/// what the item is now, because anything more would be a guess.
public struct HistoryHeadline: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The command succeeded, and MacUp read the new version back.
        case confirmed
        /// The command succeeded, and MacUp could not read the version back.
        case unconfirmed
        /// The command succeeded, but MacUp read back a version other than
        /// the one the plan aimed for.
        case targetNotReached
        /// A command failed.
        case failed
        /// A command ran past its time limit and was interrupted.
        case timedOut
        /// The run was stopped before this item's update finished.
        case stopped
        /// MacUp decided not to run it, for the reason recorded with it.
        case leftAlone
        /// An uninstall finished, and MacUp confirmed everything ticked is gone.
        case uninstalled
    }

    /// How the headline reads at a glance. The words always carry the
    /// meaning; a color or a symbol only repeats it (CLAUDE.md §21).
    public enum Tone: String, Sendable, Hashable {
        case good
        case caution
        case problem
        case neutral
    }

    public var kind: Kind
    /// The sentence. It can name the item, and names come from provider
    /// output, so it is made display-safe wherever it is shown.
    public var text: String

    public init(_ entry: HistoryEntry) {
        if let record = entry.uninstall {
            let (kind, text) = Self.uninstall(entry, record)
            self.init(kind, text)
            return
        }
        let name = entry.subjectName
        switch entry.outcome {
        case .skipped:
            self.init(.leftAlone, "Left alone")
        case .succeeded:
            switch entry.verification {
            case .verified:
                self.init(.confirmed, "Updated and confirmed")
            case .targetNotReached:
                self.init(.targetNotReached, "Ran without an error, but " + Self.missedTarget(entry))
            case .failed, .notPerformed, nil:
                self.init(.unconfirmed, "Updated, but MacUp could not confirm the new version")
            }
        case .failed, .timedOut, .cancelled:
            let kind: Kind = switch entry.outcome {
            case .timedOut: .timedOut
            case .cancelled: .stopped
            default: .failed
            }
            let happened = switch kind {
            case .timedOut: "Timed out"
            case .stopped: "Stopped"
            default: "Failed"
            }
            switch entry.verification {
            case .verified:
                self.init(kind, "\(happened), but \(name) is at the new version")
            case .targetNotReached:
                self.init(kind, "\(happened) — " + Self.missedTarget(entry))
            case .failed:
                self.init(kind, "\(happened) — MacUp could not read the version back")
            case .notPerformed, nil:
                self.init(kind, Self.nothingReadBack(kind, ranCommand: entry.command != nil))
            }
        }
    }

    private init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var tone: Tone {
        switch kind {
        case .confirmed, .uninstalled: .good
        case .unconfirmed, .targetNotReached: .caution
        case .failed, .timedOut: .problem
        case .stopped, .leftAlone: .neutral
        }
    }

    /// An SF Symbol for the kind: the success checkmark only for a confirmed
    /// update, and a stop sign rather than an error for a deliberate stop.
    public var symbolName: String {
        switch kind {
        case .confirmed: "checkmark.circle"
        case .unconfirmed: "questionmark.circle"
        case .targetNotReached: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .timedOut: "clock.badge.exclamationmark"
        case .stopped: "stop.circle"
        case .leftAlone: "minus.circle"
        case .uninstalled: "trash.circle"
        }
    }

    /// What a read-back that missed the target found: still the version it
    /// started from, or some other one.
    private static func missedTarget(_ entry: HistoryEntry) -> String {
        if let before = entry.versionBefore, let after = entry.versionAfter,
           before == after || VersionComparator.compare(before, after) == .orderedSame {
            return "\(entry.subjectName) was not updated"
        }
        return "\(entry.subjectName) is not at the new version"
    }

    /// What can be said about an attempt that did not succeed when MacUp read
    /// nothing back: what happened to the attempt, and nothing about the item.
    private static func nothingReadBack(_ kind: Kind, ranCommand: Bool) -> String {
        switch kind {
        case .timedOut: "Timed out before the update finished"
        case .stopped: ranCommand ? "Stopped before the update finished" : "Stopped before anything ran"
        default: "Failed — MacUp changed nothing further"
        }
    }
}

extension HistoryEntry {
    /// The one sentence that says what happened.
    public var headline: HistoryHeadline { HistoryHeadline(self) }

    /// `9.7.1 → 26.7.0_2 · now 9.7.1`: the version before, the one the plan
    /// aimed for, and — only when MacUp read it back — the one in use
    /// afterwards. Versions come from provider output, so the text is made
    /// display-safe where it is shown.
    public var versionSummary: String {
        if uninstall != nil { return "\(versionBefore ?? "unknown version") → removed" }
        let versions = "\(versionBefore ?? "unknown") → \(versionTarget ?? "unknown")"
        guard let versionAfter else { return versions }
        return versions + " · now \(versionAfter)"
    }

    /// Labelled facts about the attempt, in order: the provider, where the run
    /// was started, and how long the attempt took. Each says what it is,
    /// because "Homebrew · MacUp app · 94.9 s" on its own reads like a list of
    /// things that were updated.
    public var circumstances: [String] {
        // An app or MacUp itself is removed by MacUp, not by a provider.
        let by = provider.map { "via \($0.displayName)" } ?? "by MacUp"
        guard outcome != .skipped else {
            // Nothing ran for a skip, so nothing was started and nothing took
            // any time; the run it was part of still came from somewhere.
            return [by, origin.phrase]
        }
        var facts = [by, "started " + origin.phrase]
        if let durationSeconds {
            facts.append("ran for " + Self.describe(duration: durationSeconds))
        }
        return facts
    }

    /// "1 minute, 35 seconds". In English, like every other word MacUp shows,
    /// and to the nearest second: a tenth of a second is noise here.
    static func describe(duration seconds: Double) -> String {
        guard seconds.isFinite, seconds.rounded() >= 1 else { return "less than a second" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        return formatter.string(from: seconds.rounded()) ?? "\(Int(seconds.rounded())) seconds"
    }
}

extension ExecutionOrigin {
    /// Where a run was started, as the end of a sentence.
    public var phrase: String {
        switch self {
        case .cli: "from the command line"
        case .gui: "from the MacUp app"
        case .scheduled: "on a schedule"
        }
    }
}
