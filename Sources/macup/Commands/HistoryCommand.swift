import ArgumentParser
import Foundation
import MacUpCore

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show what MacUp has changed, and what it decided not to change (read-only).",
        discussion: """
            Newest first. Every attempt MacUp made is here, including the ones that \
            failed and the ones it deliberately skipped, with the reason. An update \
            MacUp could not confirm afterwards says so rather than reading as done.

            History is MacUp's own audit log, kept at ~/.local/state/macup/history.jsonl \
            as one JSON object per line. Secrets are redacted before a line is written. \
            A line MacUp cannot decode is reported and counted, never guessed at.

            Exit status: 0; 3 the configuration is invalid; 1 the history file could \
            not be read.
            """
    )

    @Option(name: .shortAndLong, help: "Show at most this many entries. Default: 25.")
    var limit: Int = 25

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Also show the commands MacUp ran and how long each attempt took.")
    var verbose = false

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be at least 1.") }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let store = HistoryStore(paths: paths)

        let reading: HistoryReading
        do {
            reading = try store.read(limit: limit)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading MacUp's history")
            context.printError("error: \(TerminalText.sanitize(failure.message))")
            if let suggestion = failure.recoverySuggestion {
                context.printError(TerminalText.sanitize(suggestion))
            }
            throw MacUpExitCode.failure.exitCode
        }

        if json {
            context.print(try JSONOutput.encode(HistoryDocument(reading, path: store.path, limit: limit)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(HistoryRenderer(
                reading: reading,
                path: store.path,
                limit: limit,
                style: style,
                verbose: verbose
            ).render())
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

/// Human-readable output for `macup history`.
struct HistoryRenderer {
    let reading: HistoryReading
    let path: String
    let limit: Int
    let style: TextStyle
    let verbose: Bool

    func render() -> String {
        guard !reading.entries.isEmpty else { return empty() }

        var lines = [style.bold("MacUp history") + style.dim(" · newest first · " + style.path(path))]
        lines.append("")

        let timestamps = reading.entries.map { Self.timestamp($0.timestamp) }
        let ids = reading.entries.map { style.safe($0.item.rawValue) }
        let versions = reading.entries.map {
            PlanText.versions(current: $0.versionBefore, proposed: $0.versionAfter ?? $0.versionTarget, style: style)
        }
        let timeWidth = timestamps.map(\.count).max() ?? 0
        let idWidth = ids.map(\.count).max() ?? 0
        let versionWidth = versions.map(\.count).max() ?? 0

        for (index, entry) in reading.entries.enumerated() {
            lines.append("  " + TextStyle.pad(timestamps[index], to: timeWidth)
                + "  " + TextStyle.pad(ids[index], to: idWidth)
                + "  " + TextStyle.pad(versions[index], to: versionWidth)
                + "  " + TextStyle.pad(Self.outcome(entry), to: 22)
                + "  " + style.dim(Self.origin(entry.origin)))
            if let reason = entry.skipReason {
                lines.append("      " + style.dim("Why: " + style.text(reason)))
            }
            if let error = entry.errorSummary {
                lines.append("      " + style.dim(style.text(error)))
            }
            if verbose {
                if let command = entry.command {
                    lines += command.split(separator: "\n").map { "      " + style.dim("Ran: " + style.path(String($0))) }
                }
                if let duration = entry.durationSeconds {
                    lines.append("      " + style.dim(String(format: "Took %.1fs", duration)))
                }
            }
        }

        lines.append("")
        lines += summary()
        return lines.joined(separator: "\n")
    }

    private func empty() -> String {
        var lines = [style.bold("No history yet.")]
        lines.append("MacUp records every change it attempts, and every one it decides not to make, in "
            + style.path(path) + ".")
        lines.append("Nothing has written to it: MacUp has not changed anything on this Mac.")
        lines += findings()
        return lines.joined(separator: "\n")
    }

    private func summary() -> [String] {
        var lines = [TextStyle.plural(reading.entries.count, "entry", "entries") + " shown."]
        if reading.entries.count == limit {
            lines[0] += " There may be more; `macup history --limit \(limit * 2)` looks further back."
        }
        lines += findings()
        return lines
    }

    /// What MacUp could not read, said out loud rather than dropped.
    private func findings() -> [String] {
        reading.findings.map { finding in
            let label = finding.severity == .info ? "note" : finding.severity.rawValue
            return "\(label): " + style.text(finding.title)
                + (finding.detail.map { " " + style.text($0) } ?? "")
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func outcome(_ entry: HistoryEntry) -> String {
        switch entry.outcome {
        case .succeeded:
            switch entry.verification {
            case .verified: return "updated, confirmed"
            case .targetNotReached: return "updated, other version"
            case .failed, .notPerformed, nil: return "updated, not confirmed"
            }
        case .failed: return "failed"
        case .timedOut: return "timed out"
        case .cancelled: return "cancelled"
        case .skipped: return "left alone"
        }
    }

    static func origin(_ origin: ExecutionOrigin) -> String {
        switch origin {
        case .cli: "from the command line"
        case .gui: "from the app"
        case .scheduled: "on a schedule"
        }
    }
}

/// The machine-readable form of `macup history`.
struct HistoryDocument: Encodable {
    let schemaVersion = 1
    let kind = "history"
    let macupVersion = MacUp.version
    let path: String
    let limit: Int
    let entries: [HistoryEntry]
    /// Lines MacUp could not decode. Reported so a reader knows the log is
    /// incomplete rather than assuming these entries never existed.
    let unreadableLines: Int
    let olderEntriesNotRead: Bool

    init(_ reading: HistoryReading, path: String, limit: Int) {
        self.path = path
        self.limit = limit
        entries = reading.entries
        unreadableLines = reading.unreadableLines
        olderEntriesNotRead = reading.olderEntriesNotRead
    }
}
