import Foundation

/// What an uninstall did, as history keeps it (CLAUDE.md §16).
///
/// Added to ``HistoryEntry`` as one optional field, so every line an older
/// MacUp wrote still decodes, and an older MacUp reading a newer line simply
/// does not see this part.
public struct UninstallRecord: Sendable, Hashable, Codable {
    public struct RecordedPath: Sendable, Hashable, Codable {
        public var path: String
        public var category: LeftoverCategory
        public var sizeBytes: Int64?
        /// Why it was skipped or failed, or where it went in the Trash.
        public var note: String?

        public init(path: String, category: LeftoverCategory, sizeBytes: Int64? = nil, note: String? = nil) {
            self.path = path
            self.category = category
            self.sizeBytes = sizeBytes
            self.note = note
        }
    }

    public var target: String
    public var name: String
    public var kind: UninstallSubject.Kind
    public var mode: RemovalMode
    public var removed: [RecordedPath]
    /// Left in place because they were not ticked.
    public var kept: [RecordedPath]
    /// Not removed, with the reason: changed since review, refused by the
    /// boundary, or not reached.
    public var skipped: [RecordedPath]
    public var failed: [RecordedPath]
    /// What MacUp removes once this record is written: MacUp's own history
    /// and app, when it is uninstalling itself. Listed, not claimed.
    public var removedAfterRecord: [String]?
    public var bytesRemoved: Int64
    /// MacUp's own steps and what they did, for uninstalling MacUp.
    public var actions: [String]?
    /// What MacUp read back afterwards that did not hold.
    public var unconfirmed: [String]?

    public init(
        target: String,
        name: String,
        kind: UninstallSubject.Kind,
        mode: RemovalMode,
        removed: [RecordedPath] = [],
        kept: [RecordedPath] = [],
        skipped: [RecordedPath] = [],
        failed: [RecordedPath] = [],
        removedAfterRecord: [String]? = nil,
        bytesRemoved: Int64 = 0,
        actions: [String]? = nil,
        unconfirmed: [String]? = nil
    ) {
        self.target = target
        self.name = name
        self.kind = kind
        self.mode = mode
        self.removed = removed
        self.kept = kept
        self.skipped = skipped
        self.failed = failed
        self.removedAfterRecord = removedAfterRecord
        self.bytesRemoved = bytesRemoved
        self.actions = actions
        self.unconfirmed = unconfirmed
    }

    /// Data folders that were left in place.
    public var keptData: Int { kept.filter { $0.category.isData }.count }
}

extension HistoryEntry {
    /// The history line for an uninstall.
    public init(uninstall report: UninstallReport, plan: UninstallPlan, removedAfterRecord: [String] = []) {
        let outcome: ExecutionResult.Outcome = switch report.outcome {
        case .uninstalled: .succeeded
        case .incomplete: report.removals.contains { $0.status == .failed } ? .failed : .succeeded
        case .failed: .failed
        case .refused: .skipped
        case .cancelled: .cancelled
        }
        func recorded(_ outcome: RemovalOutcome) -> UninstallRecord.RecordedPath {
            UninstallRecord.RecordedPath(
                path: outcome.path,
                category: outcome.category,
                sizeBytes: outcome.sizeBytes,
                note: outcome.status == .removed ? outcome.trashedTo.map { "In the Trash at \($0)" } : outcome.reason
            )
        }
        let categories = Dictionary(plan.removals.map { ($0.path, $0.category) }, uniquingKeysWith: { first, _ in first })
        let record = UninstallRecord(
            target: report.subject.target,
            name: report.subject.name,
            kind: report.subject.kind,
            mode: report.mode,
            removed: report.removals.filter { $0.status == .removed || $0.status == .alreadyGone }.map(recorded),
            kept: report.kept.map { UninstallRecord.RecordedPath(path: $0.path, category: $0.category, sizeBytes: $0.sizeBytes) },
            skipped: report.removals.filter { $0.status == .skipped }.map(recorded)
                + report.notAttempted.map {
                    UninstallRecord.RecordedPath(path: $0, category: categories[$0] ?? .belongsToApp, note: "MacUp stopped before it got to this.")
                },
            failed: report.removals.filter { $0.status == .failed }.map(recorded),
            removedAfterRecord: removedAfterRecord.isEmpty ? nil : removedAfterRecord,
            bytesRemoved: report.summary.removedBytes,
            actions: report.actions.isEmpty ? nil : report.actions.map { "\($0.action.summary): \($0.message)" },
            unconfirmed: {
                let failed = report.checks.filter { $0.passed != true }.map { [$0.summary, $0.detail].compactMap { $0 }.joined(separator: ": ") }
                return failed.isEmpty ? nil : failed
            }()
        )
        let confirmed = report.outcome != .refused && report.isConfirmed
        self.init(
            timestamp: report.finishedAt,
            origin: report.origin,
            item: report.subject.packageID,
            versionBefore: report.subject.version,
            versionTarget: nil,
            versionAfter: nil,
            command: report.commands.isEmpty ? nil : report.commands.map(\.command).joined(separator: "\n"),
            outcome: outcome,
            verification: report.outcome == .refused ? nil : confirmed ? .verified : .failed,
            errorSummary: report.error?.message,
            skipReason: report.refusals.isEmpty ? nil : report.refusals.joined(separator: " "),
            durationSeconds: report.finishedAt.timeIntervalSince(report.startedAt)
        )
        uninstall = record
    }
}

extension HistoryHeadline {
    /// "Uninstalled ChatGPT · 7 items moved to the Trash", "Uninstalled mysql;
    /// its data folder was kept".
    static func uninstall(_ entry: HistoryEntry, _ record: UninstallRecord) -> (Kind, String) {
        let name = record.name
        switch entry.outcome {
        case .skipped:
            return (.leftAlone, "Not uninstalled")
        case .cancelled:
            return (.stopped, record.removed.isEmpty ? "Uninstall stopped before anything was removed" : "Uninstall of \(name) stopped part-way")
        case .timedOut:
            return (.timedOut, "Uninstall of \(name) timed out")
        case .failed:
            if !record.removed.isEmpty {
                return (.failed, "Uninstall of \(name) did not finish — " + UninstallWording.items(record.removed.count) + " " + record.mode.pastTense)
            }
            return (.failed, "Uninstall of \(name) failed — MacUp removed nothing further")
        case .succeeded:
            var text = "Uninstalled \(name)"
            if !record.removed.isEmpty {
                text += " · " + UninstallWording.items(record.removed.count) + " " + record.mode.pastTense
            }
            switch record.keptData {
            case 0: break
            case 1: text += "; its data folder was kept"
            case let count: text += "; its \(count) data folders were kept"
            }
            if entry.verification != .verified {
                return (.unconfirmed, text + ", but MacUp could not confirm everything is gone")
            }
            return (.uninstalled, text)
        }
    }
}

/// Wording the CLI, the app, and history share for uninstalls.
public enum UninstallWording {
    /// "1 item", "7 items".
    public static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// "1.6 GB", in the style Finder uses.
    public static func size(_ bytes: Int64, partial: Bool = false) -> String {
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return partial ? "at least " + text : text
    }

    /// "7 items, 1.6 GB".
    public static func total(_ totals: UninstallTotals) -> String {
        items(totals.count) + ", " + size(totals.bytes, partial: totals.bytesArePartial)
    }
}
