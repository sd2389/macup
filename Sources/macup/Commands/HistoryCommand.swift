import ArgumentParser
import Foundation
import MacUpCore

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show what MacUp has changed, and what it decided not to change (read-only).",
        discussion: """
            Newest first. Every attempt MacUp made is here, including the ones that \
            failed and the ones it deliberately skipped, with the reason. Each entry \
            opens with one line saying what happened. An update MacUp could not \
            confirm afterwards says so rather than reading as done, and an attempt \
            that did not finish says what MacUp found when it read the item back.

            Name package IDs to see only those items, for example \
            `macup history brew:mysql`. --search keeps the entries whose item, \
            provider, or outcome contains every word you give, so \
            `macup history --search stopped` lists the runs that were stopped.

            History is MacUp's own audit log, kept at ~/.local/state/macup/history.jsonl \
            as one JSON object per line. Secrets are redacted before a line is written. \
            A line MacUp cannot decode is reported and counted, never guessed at.

            Exit status: 0; 3 the configuration is invalid; 1 the history file could \
            not be read; 64 an argument is not a package ID.
            """
    )

    @Argument(help: "Show only these items, for example brew:mysql or npm:@scope/name. Default: every item.")
    var items: [String] = []

    @Option(name: .shortAndLong, help: "Show at most this many entries. Default: 25.")
    var limit: Int = 25

    @Option(name: .long, help: "Only show entries whose item, provider, or outcome contains every word of this, ignoring case.")
    var search: String?

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Also show the commands MacUp ran.")
    var verbose = false

    func validate() throws {
        guard limit > 0 else { throw ValidationError("--limit must be at least 1.") }
        try PackageSelection.validate(items)
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let store = HistoryStore(paths: paths)
        let filter = HistoryFilter(items: PackageSelection.parse(items) ?? [], search: search ?? "")

        let reading: HistoryReading
        do {
            reading = try store.read(limit: limit, filter: filter)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading MacUp's history")
            context.printError("error: \(TerminalText.sanitize(failure.message))")
            if let suggestion = failure.recoverySuggestion {
                context.printError(TerminalText.sanitize(suggestion))
            }
            throw MacUpExitCode.failure.exitCode
        }

        if json {
            context.print(try JSONOutput.encode(HistoryDocument(reading, path: store.path, limit: limit, filter: filter)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(HistoryRenderer(
                reading: reading,
                path: store.path,
                limit: limit,
                filter: filter,
                style: style,
                verbose: verbose
            ).render())
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

/// Human-readable output for `macup history`.
///
/// One block per entry: when and which item, then the one headline that says
/// what happened, the versions — with what MacUp found afterwards when it
/// looked — and the labelled facts about the attempt. The error text recorded
/// with an attempt comes last, as detail, so it never reads as a second
/// verdict. The words are ``HistoryHeadline``'s, the same ones the History
/// screen uses.
struct HistoryRenderer {
    let reading: HistoryReading
    let path: String
    let limit: Int
    var filter = HistoryFilter()
    let style: TextStyle
    let verbose: Bool

    func render() -> String {
        guard !reading.entries.isEmpty else { return empty() }

        var lines = [style.bold(title) + style.dim(" · newest first · " + style.path(path))]
        for entry in reading.entries {
            lines.append("")
            lines += block(entry)
        }
        lines.append("")
        lines += summary()
        return lines.joined(separator: "\n")
    }

    private func block(_ entry: HistoryEntry) -> [String] {
        let headline = entry.headline
        var lines = [style.dim(Self.timestamp(entry.timestamp)) + "  " + style.bold(style.safe(entry.item.rawValue))]
        lines.append("  " + style.tone(headline.tone, style.safe(headline.text)))
        lines.append("  " + style.safe(entry.versionSummary))
        if let state = entry.stateAfter {
            lines.append("  " + style.text(state))
        }
        if let reason = entry.skipReason {
            lines.append("  " + style.dim("Why: ") + style.text(reason))
        }
        lines.append("  " + style.dim(entry.circumstances.map(style.safe).joined(separator: " · ")))
        if let error = entry.errorSummary {
            lines.append("  " + style.dim("Details: " + style.text(error)))
        }
        if verbose, let command = entry.command {
            lines += command.split(separator: "\n").map { "  " + style.dim("Ran: " + style.path(String($0))) }
        }
        return lines
    }

    /// "MacUp history", narrowed to what was asked for.
    private var title: String {
        var title = "MacUp history"
        if !filter.items.isEmpty { title += " for " + itemList }
        if !filter.searchWords.isEmpty { title += " matching \"" + style.safe(filter.search) + "\"" }
        return title
    }

    private var itemList: String {
        filter.items.sorted().map { style.safe($0.rawValue) }.joined(separator: ", ")
    }

    private func empty() -> String {
        var lines: [String] = []
        if filter.isEmpty {
            lines.append(style.bold("No history yet."))
            lines.append("MacUp records every change it attempts, and every one it decides not to make, in "
                + style.path(path) + ".")
            lines.append("Nothing has written to it: MacUp has not changed anything on this Mac.")
        } else if filter.searchWords.isEmpty {
            lines.append(style.bold("No history for " + itemList + "."))
            lines.append("MacUp has recorded no attempt at it, and no decision to leave it alone, in " + style.path(path) + ".")
        } else {
            let subject = filter.items.isEmpty ? "No history entry" : "No history for " + itemList
            lines.append(style.bold(subject + " matches \"" + style.safe(filter.search) + "\"."))
            lines.append("A search looks at each entry's package ID, provider, and outcome, in " + style.path(path) + ".")
        }
        lines += findings()
        return lines.joined(separator: "\n")
    }

    private func summary() -> [String] {
        var lines = [TextStyle.plural(reading.entries.count, "entry", "entries") + " shown."]
        if reading.entries.count == limit {
            lines[0] += " There may be more; `\(style.safe(widerCommand))` looks further back."
        }
        lines += findings()
        return lines
    }

    /// The same command with twice the limit. Built as an argument list and
    /// shell-quoted for display, so a search with spaces in it can be copied
    /// as it is.
    private var widerCommand: String {
        var arguments = ["history"] + filter.items.sorted().map(\.rawValue)
        if !filter.searchWords.isEmpty { arguments += ["--search", filter.search] }
        arguments += ["--limit", String(limit * 2)]
        return CommandInvocation(executable: "macup", arguments: arguments).displayString
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
}

extension TextStyle {
    /// A headline, colored by how it reads on terminals. The words carry the
    /// meaning; the color only repeats it.
    fileprivate func tone(_ tone: HistoryHeadline.Tone, _ text: String) -> String {
        let code: String? = switch tone {
        case .good: "32"
        case .caution: "33"
        case .problem: "31"
        case .neutral: nil
        }
        guard enabled, let code else { return text }
        return "\u{1B}[\(code)m" + text + "\u{1B}[0m"
    }
}

/// The machine-readable form of `macup history`.
struct HistoryDocument: Encodable {
    let schemaVersion = 1
    let kind = "history"
    let macupVersion = MacUp.version
    let path: String
    let limit: Int
    /// The items asked for, sorted. Empty when every item was included.
    let items: [PackageID]
    /// The search asked for, absent when there was none.
    let search: String?
    let entries: [HistoryEntry]
    /// Lines MacUp could not decode. Reported so a reader knows the log is
    /// incomplete rather than assuming these entries never existed.
    let unreadableLines: Int
    let olderEntriesNotRead: Bool

    init(_ reading: HistoryReading, path: String, limit: Int, filter: HistoryFilter = HistoryFilter()) {
        self.path = path
        self.limit = limit
        items = filter.items.sorted()
        search = filter.searchWords.isEmpty ? nil : filter.search
        entries = reading.entries
        unreadableLines = reading.unreadableLines
        olderEntriesNotRead = reading.olderEntriesNotRead
    }
}
