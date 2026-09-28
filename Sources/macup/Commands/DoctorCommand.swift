import ArgumentParser
import Foundation
import MacUpCore

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Explain what is odd about this Mac's developer environment (read-only).",
        discussion: """
            Doctor runs MacUp's deterministic checks — two Homebrew installations, a \
            provider MacUp cannot find, a PATH that differs between your shell and the \
            app, an npm prefix that does not match the Node that owns it, an \
            architecture mismatch, MacUp's own files and schedule — and says what it \
            observed and what you can do about each one.

            Doctor explains. It fixes nothing, changes no configuration, and installs \
            nothing. Every recommendation is something for you to decide.

            Exit status: 0 nothing needs attention (notes are fine); 5 at least one \
            warning or error; 130 cancelled. A configuration problem is reported as a \
            finding, so it comes back as 5 rather than 3.
            """
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    @Flag(name: .shortAndLong, help: "Also show the notes, and each provider's installation.")
    var verbose = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        // Reading the schedule is part of the diagnosis: an agent pointing at
        // a binary that has moved is exactly the kind of thing Doctor is for.
        let schedule = await context.scheduler(paths: paths).status(loaded.configuration.schedule)

        let engine = context.doctorEngine
        let environment = context.checkEnvironment
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(configuration: loaded, environment: environment, paths: paths, schedule: schedule)
        }

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(DoctorRenderer(report: report, style: style, verbose: verbose).render())
        }

        if report.cancelled { throw MacUpExitCode.cancelled.exitCode }
        if !report.isHealthy { throw MacUpExitCode.attentionRequired.exitCode }
    }
}

/// Human-readable output for `macup doctor`.
///
/// Most severe first, each finding saying what MacUp observed and what the
/// reader can do. Nothing is dramatized: a Mac with nothing wrong gets a short
/// calm answer, not a clean bill of health it cannot support.
struct DoctorRenderer {
    let report: DoctorReport
    let style: TextStyle
    let verbose: Bool

    func render() -> String {
        var lines = [style.bold("MacUp doctor")
            + style.dim(" · \(TextStyle.plural(report.summary.checksRun, "check")) · nothing was changed")]
        if report.cancelled {
            lines.append("Cancelled before every check finished; this is incomplete.")
        }

        if verbose {
            lines.append("")
            lines += providers()
        }

        let shown = verbose ? report.findings : report.findings.filter { $0.severity != .info }
        if shown.isEmpty {
            lines.append("")
            lines.append(style.bold(report.findings.isEmpty
                ? "Nothing to report."
                : "Nothing needs attention."))
            if !report.findings.isEmpty {
                lines.append("\(TextStyle.plural(report.summary.notes, "note")) MacUp did not think worth "
                    + "interrupting you with; `macup doctor --verbose` shows them.")
            }
        } else {
            for finding in shown {
                lines.append("")
                lines += render(finding)
            }
        }

        lines.append("")
        lines += summary()
        return lines.joined(separator: "\n")
    }

    private func render(_ finding: DiagnosticFinding) -> [String] {
        // The severity is a word, not a color: the label carries the meaning
        // on its own so nothing depends on styling being available.
        let label: String
        switch finding.severity {
        case .error: label = "error"
        case .warning: label = "warning"
        case .info: label = "note"
        }
        var lines = [style.bold(TextStyle.pad(label, to: 7)) + " " + style.text(finding.title)]
        if let provider = finding.provider {
            lines[0] += style.dim(" · " + style.safe(provider.displayName))
        }
        if let detail = finding.detail {
            lines += detail.split(separator: "\n").map { "        " + style.text(String($0)) }
        }
        if let recommendation = finding.recommendation {
            lines += recommendation.split(separator: "\n").map { "        " + style.dim(style.text(String($0))) }
        }
        return lines
    }

    private func providers() -> [String] {
        var lines = [style.bold("Providers")]
        for provider in report.providers {
            let state: String
            switch provider.availability {
            case .available: state = "found"
            case .unavailable: state = "not found"
            case .disabled: state = "disabled"
            case .failed: state = "not usable"
            }
            var line = "  " + TextStyle.pad(style.safe(provider.displayName), to: 10) + TextStyle.pad(state, to: 11)
            if let executable = provider.executable { line += style.path(executable.path) }
            if let version = provider.version { line += style.dim(" " + style.safe(version)) }
            lines.append(line)
        }
        return lines
    }

    private func summary() -> [String] {
        let counts = report.summary
        var parts: [String] = []
        if counts.errors > 0 { parts.append(TextStyle.plural(counts.errors, "error")) }
        if counts.warnings > 0 { parts.append(TextStyle.plural(counts.warnings, "warning")) }
        if counts.notes > 0 { parts.append(TextStyle.plural(counts.notes, "note")) }

        var lines: [String] = []
        lines.append(style.bold(parts.isEmpty ? "No findings." : parts.joined(separator: " · ") + "."))
        lines.append(report.isHealthy
            ? "Nothing here needs your attention."
            : "Each finding above says what MacUp observed and what you can do. MacUp changed nothing.")
        if !verbose && counts.notes > 0 && !report.findings.filter({ $0.severity != .info }).isEmpty {
            lines.append(style.dim("`macup doctor --verbose` also shows the notes."))
        }
        return lines
    }
}
