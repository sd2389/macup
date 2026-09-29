import Foundation
import MacUpCore

/// Human-readable output for `macup check`.
///
/// Calm and precise (docs/UX_SPEC.md): what was found, who manages it, what
/// could change, what failed and what MacUp ran — and always that nothing was
/// changed. All provider-supplied text is sanitized for the terminal.
struct CheckRenderer {
    let report: CheckReport
    let style: TextStyle
    let verbose: Bool

    /// Facts worth a line under each provider's heading (npm has its own summary).
    private static let headlineFacts: [ProviderID: [String]] = [
        .homebrew: ["prefix"],
        .mise: ["globalConfigFile"],
        .macos: ["build"],
    ]

    func render() -> String {
        var lines: [String] = []
        let mode = report.mode == .metadataRefresh
            ? "metadata refreshed · no packages were changed"
            : "read-only · nothing was changed"
        lines.append(style.bold("MacUp check") + style.dim(" · \(mode)"))
        if report.cancelled {
            lines.append("Cancelled before the check finished; results are incomplete.")
        }

        for provider in report.providers {
            lines.append("")
            lines += section(for: provider)
        }

        lines.append("")
        lines += summary()
        if verbose {
            lines.append("")
            lines += commands()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Provider sections

    private func section(for provider: ProviderReport) -> [String] {
        var lines: [String] = []
        let name = style.bold(provider.displayName)
        switch provider.availability {
        case .disabled:
            return [name + style.dim(" · disabled in configuration; not checked")]
        case .unavailable:
            lines.append(name + style.dim(" · not found"))
            if verbose, let error = provider.errors.first?.error {
                lines += indented(errorLines(error, heading: nil))
            }
            return lines
        case .failed, .available:
            break
        }

        var heading = name
        if let version = provider.version { heading += " " + style.safe(version) }
        if let executable = provider.executable { heading += style.dim(" · " + style.path(executable.path)) }
        lines.append(heading)

        if verbose {
            lines += provider.facts.map { "  " + style.dim("\($0.label): \(style.path($0.value))") }
        } else if provider.provider == .npm {
            lines += npmSummary(provider).map { "  " + style.dim($0) }
        } else {
            let facts = provider.facts.filter { Self.headlineFacts[provider.provider]?.contains($0.key) == true }
            if !facts.isEmpty {
                lines.append("  " + style.dim(facts.map { "\($0.label): \(style.path($0.value))" }.joined(separator: " · ")))
            }
        }

        if provider.availability == .available {
            lines.append("  " + counts(provider))
        }

        let updates = report.updates(for: provider.provider)
        lines += updateTable(updates)

        if provider.provider == .macos && !updates.isEmpty {
            lines.append("  " + style.dim("Review and install macOS updates in System Settings → General → Software Update."))
        }
        if let items = provider.items, !items.isEmpty {
            lines.append("  Installed:")
            lines += items.map { item in
                let version = item.activeVersion?.raw ?? item.installedVersions.last?.raw ?? "not installed"
                return "    \(style.safe(item.id.rawValue)) \(style.dim(style.safe(version)))"
            }
        }
        for finding in provider.findings {
            lines += indented(findingLines(finding))
        }
        for failure in provider.errors {
            lines += indented(errorLines(failure.error, heading: operationName(failure.operation)))
        }
        return lines
    }

    /// "Node v24.19.0 · ~/.local/bin/node → ~/.hermes/node/bin/node · managed by mise"
    private func npmSummary(_ provider: ProviderReport) -> [String] {
        func fact(_ key: String) -> String? { provider.facts.first { $0.key == key }?.value }
        var node: [String] = []
        if let version = fact("nodeVersion") { node.append("Node " + style.safe(version)) }
        if let path = fact("nodePath") {
            node.append(style.path(path) + (fact("nodeTarget").map { " → " + style.path($0) } ?? ""))
        }
        if let manager = fact("nodeManager") {
            node.append(manager == "unrecognized" ? "not managed by a recognized tool" : "managed by " + style.safe(manager))
        }
        var lines = node.isEmpty ? [] : [node.joined(separator: " · ")]
        if let root = fact("globalRoot") { lines.append("Global packages: " + style.path(root)) }
        return lines
    }

    private func counts(_ provider: ProviderReport) -> String {
        var parts: [String] = []
        if let installed = provider.installedCount {
            parts.append("\(installed) installed")
        }
        switch provider.updateCount {
        case 0? where provider.unreadableUpdates > 0:
            parts.append(TextStyle.plural(provider.unreadableUpdates, "listed update") + " could not be read")
        case 0? where provider.resultsIncomplete:
            parts.append("no updates found; results may be incomplete (see warning)")
        case 0?:
            parts.append("up to date")
        case let count?:
            parts.append(TextStyle.plural(count, "update"))
            if provider.unreadableUpdates > 0 {
                parts.append("\(provider.unreadableUpdates) more could not be read")
            } else if provider.resultsIncomplete {
                parts.append("results may be incomplete (see warning)")
            }
        case nil:
            parts.append("updates unknown (see error)")
        }
        return parts.joined(separator: " · ")
    }

    private func updateTable(_ updates: [UpdateCandidate]) -> [String] {
        guard !updates.isEmpty else { return [] }
        let ids = updates.map { style.safe($0.id.rawValue) }
        let versions = updates.map { update in
            style.safe(update.installedVersion?.raw ?? "unknown") + " → " + style.safe(update.availableVersion.raw)
        }
        let idWidth = min(ids.map(\.count).max() ?? 0, 48)
        let versionWidth = min(versions.map(\.count).max() ?? 0, 40)

        var lines: [String] = []
        for (index, update) in updates.enumerated() {
            var flags = [update.versionChange.displayName]
            if update.signals.contains(.pinnedByProvider) { flags.append("pinned") }
            if update.signals.contains(.restartRequired) { flags.append("restart required") }
            if update.details["configScope"] == "project" { flags.append("project config") }
            lines.append("  " + TextStyle.pad(ids[index], to: idWidth) + "  "
                         + TextStyle.pad(versions[index], to: versionWidth) + "  "
                         + style.risk(update.risk.level) + style.dim(" · " + flags.joined(separator: " · ")))
            if verbose {
                if let difference = update.versionDifference {
                    lines.append("      " + style.dim("Changes: " + style.text(difference.summary)))
                }
                if let link = update.releaseInfoLink {
                    lines.append("      " + style.dim(style.text(link.title) + ": " + style.safe(link.url.absoluteString)))
                }
                if let ownership = update.ownership {
                    lines.append("      " + style.dim("Managed by: " + style.text(ownership.summary)))
                }
                for reason in update.risk.reasons {
                    lines.append("      " + style.dim("Risk: " + style.text(reason)))
                }
                for note in update.notes {
                    lines.append("      " + style.dim(style.text(note)))
                }
            }
        }
        return lines
    }

    private func findingLines(_ finding: DiagnosticFinding) -> [String] {
        let label: String
        switch finding.severity {
        case .info: label = "note"
        case .warning: label = "warning"
        case .error: label = "error"
        }
        var lines = ["\(label): \(style.text(finding.title))"]
        if let detail = finding.detail {
            lines += detail.split(separator: "\n").map { "  " + style.dim(style.text(String($0))) }
        }
        if verbose, let recommendation = finding.recommendation {
            lines.append("  " + style.dim(style.text(recommendation)))
        }
        return lines
    }

    private func errorLines(_ error: MacUpError, heading: String?) -> [String] {
        var lines = ["error\(heading.map { " (\($0))" } ?? ""): \(style.text(error.message))"]
        if let command = error.command {
            let exit = error.exitStatus.map { " (exit status \($0))" } ?? ""
            lines.append("  Ran: " + style.text(command) + exit)
        }
        if let detail = error.detail {
            lines += detail.split(separator: "\n").prefix(verbose ? 12 : 4).map { "  " + style.dim(style.text(String($0))) }
        }
        if let suggestion = error.recoverySuggestion {
            lines.append("  " + style.text(suggestion))
        }
        return lines
    }

    /// Worded in MacUpCore, which `macup explain` shares.
    private func operationName(_ operation: ProviderOperationError.Operation) -> String {
        operation.displayName
    }

    private func indented(_ lines: [String]) -> [String] {
        lines.map { "  " + $0 }
    }

    // MARK: Summary

    private func summary() -> [String] {
        var lines: [String] = []
        let counts = report.providers.compactMap { provider -> String? in
            let count = report.updates(for: provider.provider).count
            return count > 0 ? "\(provider.displayName) \(count)" : nil
        }
        let updates = report.summary.updatesAvailable
        if updates == 0 {
            lines.append(style.bold(report.isComplete ? "No updates available." : "No updates found."))
        } else {
            lines.append(style.bold(TextStyle.plural(updates, "update") + " available") + " (\(counts.joined(separator: ", "))).")
        }
        lines.append(report.mode == .readOnly
            ? "Nothing was changed."
            : "Only package metadata was refreshed; no packages were installed or upgraded.")

        if report.summary.providersWithErrors > 0 {
            lines.append("\(TextStyle.plural(report.summary.providersWithErrors, "provider")) reported errors; results are incomplete.")
        }
        if report.summary.providersIncomplete > 0 {
            lines.append("\(TextStyle.plural(report.summary.providersIncomplete, "provider")) left some updates out; results are incomplete.")
        }
        let configuration = report.configuration
        if !configuration.valid {
            let errors = configuration.issues.filter { $0.severity == .error }.count
            lines.append("Configuration \(style.path(configuration.path)) has \(TextStyle.plural(errors, "error")); "
                         + "automatic modifications stay disabled until it is fixed. Run `macup config show` for details.")
        }
        if updates > 0 && !verbose {
            lines.append(style.dim("For details on each update, run `macup check --verbose`."))
        }
        if report.mode == .readOnly {
            let local = report.providers
                .filter { $0.availability == .available && $0.capabilities.contains(.refreshMetadata) }
                .map(\.displayName)
            if !local.isEmpty {
                lines.append(style.dim("\(local.joined(separator: " and ")) results use locally cached metadata; `macup check --refresh` refreshes it."))
            }
        }
        return lines
    }

    private func commands() -> [String] {
        guard !report.commands.isEmpty else { return ["No commands were run."] }
        let allReadOnly = report.commands.allSatisfy { $0.effect == .readOnly }
        var lines = ["Commands MacUp ran" + (allReadOnly ? " (all read-only):" : ":")]
        for record in report.commands {
            let outcome: String
            switch record.outcome {
            case .exited: outcome = "exit \(record.exitStatus.map(String.init) ?? "?")"
            case .signaled: outcome = "signaled"
            case .timedOut: outcome = "timed out"
            case .cancelled: outcome = "cancelled"
            case .refused: outcome = "refused"
            case .failedToLaunch: outcome = "not launched"
            }
            let effect = record.effect == .readOnly ? "" : " [\(record.effect.rawValue)]"
            lines.append("  " + style.dim(String(format: "%6.2fs  %@", record.durationSeconds, TextStyle.pad(outcome, to: 12)))
                         + style.text(record.command) + effect)
        }
        return lines
    }
}
