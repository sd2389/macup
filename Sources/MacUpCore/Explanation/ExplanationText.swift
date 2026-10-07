import Foundation

/// The human-readable form of an ``ItemExplanation``: what `macup explain`
/// prints, and word for word what the app's Copy Details puts on the
/// clipboard.
///
/// Everything a provider supplied is untrusted, so every such string is
/// redacted and then sanitized here, whatever surface it is going to: a
/// control character that reached the clipboard could still reach a terminal
/// when it is pasted. Paths under the home directory are written with `~`, as
/// everywhere else MacUp shows one.
///
/// Styling is decoration and is off unless the caller supplies it. The CLI
/// passes bold and dim for a terminal; the app passes nothing, so what it
/// copies is plain text.
public struct ExplanationText {
    public var homeDirectory: String
    public var timeZone: TimeZone
    public var bold: (String) -> String
    public var dim: (String) -> String

    public init(
        homeDirectory: String,
        timeZone: TimeZone = .current,
        bold: @escaping (String) -> String = { $0 },
        dim: @escaping (String) -> String = { $0 }
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.bold = bold
        self.dim = dim
    }

    public func render(_ explanation: ItemExplanation) -> String {
        var lines = [bold("MacUp explain") + dim(" · read-only · nothing was changed"), ""]
        lines.append(heading(explanation))
        lines.append(text(explanation.summary))
        if explanation.cancelled && explanation.status != .checkFailed {
            lines.append("The check was cancelled before it finished, so this may be incomplete.")
        }
        if !explanation.configuration.valid {
            lines.append("MacUp's configuration \(path(explanation.configuration.path)) has errors, so MacUp will change "
                + "nothing until they are fixed. `macup config show` lists them.")
        }
        lines += problems(explanation)
        lines += versions(explanation)
        lines += risk(explanation)
        lines += notes(explanation)
        lines += ownership(explanation)
        lines += policy(explanation)
        lines += plan(explanation)
        lines += history(explanation)
        if let suggestion = explanation.suggestion {
            lines.append("")
            lines.append(dim(suggestion))
        }
        return lines.joined(separator: "\n")
    }

    /// What to say, in order, when MacUp knows nothing about the item: why,
    /// what it still holds about it, and what to run next. The CLI prints this
    /// as an error instead of an explanation of nothing.
    public func unknownItemMessage(_ explanation: ItemExplanation) -> [String] {
        var lines = [text(explanation.summary)]
        if explanation.policy.source == .item {
            lines.append("MacUp still has a rule for it: \(explanation.policy.policy.displayName) "
                + "(\(safe(explanation.policy.rule))).")
        }
        if !explanation.history.entries.isEmpty {
            let count = explanation.history.moreAvailable
                ? "more than \(explanation.history.entries.count) entries"
                : Self.plural(explanation.history.entries.count, "entry", "entries")
            lines.append("MacUp's history has \(count) for it; `macup history` shows them.")
        }
        if let suggestion = explanation.suggestion { lines.append(suggestion) }
        return lines
    }

    // MARK: Sections

    private func heading(_ explanation: ItemExplanation) -> String {
        var parts: [String] = []
        let name = explanation.update?.displayName ?? explanation.installed?.displayName
        if let name, name != explanation.item.name { parts.append(safe(name)) }
        parts.append(Self.kind(explanation.update?.kind ?? explanation.installed?.kind, of: explanation.item.provider))
        return bold(safe(explanation.item.rawValue)) + dim(" · " + parts.joined(separator: " · "))
    }

    private func problems(_ explanation: ItemExplanation) -> [String] {
        guard let report = explanation.providerReport, !report.errors.isEmpty else { return [] }
        var lines = ["", bold("Problems")]
        for failure in report.errors {
            lines.append("  error (\(failure.operation.displayName)): " + text(failure.error.message))
            if let suggestion = failure.error.recoverySuggestion {
                lines.append("    " + dim(text(suggestion)))
            }
        }
        return lines
    }

    private func versions(_ explanation: ItemExplanation) -> [String] {
        let provider = explanation.item.provider.displayName
        if let update = explanation.update {
            var lines = ["", bold("Versions")]
            lines.append("  Installed: " + safe(update.installedVersion?.raw ?? "not reported by \(provider)"))
            lines.append("  Available: " + safe(update.availableVersion.raw) + ", " + Self.change(update.versionChange))
            if let difference = explanation.versionDifference {
                lines.append("  What changes: " + text(difference.summary))
            } else {
                lines.append("  What changes: MacUp cannot break these versions into parts, so it does not guess.")
            }
            if let link = explanation.releaseInfoLink {
                lines.append("  " + text(link.title) + ": " + safe(link.url.absoluteString))
            }
            return lines
        }
        guard let installed = explanation.installed else { return [] }
        var lines = ["", bold("Versions")]
        lines.append("  Installed: " + text(ItemExplainer.installedVersions(installed)))
        if installed.pinnedByProvider {
            lines.append("  Pinned in \(provider).")
        }
        lines.append(explanation.status == .upToDate
            ? "  No update is available."
            : "  MacUp could not find out whether an update is available.")
        return lines
    }

    private func risk(_ explanation: ItemExplanation) -> [String] {
        guard let update = explanation.update else { return [] }
        return ["", bold("Risk") + ": " + update.risk.level.rawValue] + update.risk.reasons.map { "  " + text($0) }
    }

    private func notes(_ explanation: ItemExplanation) -> [String] {
        guard let notes = explanation.update?.notes, !notes.isEmpty else { return [] }
        return ["", bold("Notes")] + notes.flatMap(indentedLines)
    }

    private func ownership(_ explanation: ItemExplanation) -> [String] {
        let chain = explanation.update?.ownership ?? explanation.installed?.ownership
        guard let links = chain?.links, !links.isEmpty else { return [] }
        var lines = ["", bold("Managed by")]
        for link in links {
            lines.append("  " + safe(link.label) + (link.path.map { " · " + path($0) } ?? ""))
        }
        // Which binary MacUp used, unless the chain already names it.
        if let report = explanation.providerReport, let executable = report.executable,
           !links.contains(where: { $0.path == executable.path }) {
            let version = report.version.map { " (\(safe(report.displayName)) \(safe($0)))" } ?? ""
            lines.append("  " + dim("Checked with " + path(executable.path) + version + "."))
        }
        return lines
    }

    private func policy(_ explanation: ItemExplanation) -> [String] {
        let policy = explanation.policy
        let setBy = "  Set by: " + setByPhrase(policy, item: explanation.item)
        if let decision = policy.decision {
            var lines = ["", bold("Policy") + ": " + decision.actionSummary, setBy]
            if let override = overridePhrase(decision, item: explanation.item) {
                lines.append("  Decided by: " + override)
            }
            lines.append("  Why: " + text(decision.reason))
            return lines
        }
        // No update to decide about. The rule is still worth stating for an
        // item MacUp found, and for one it did not when the rule is the
        // item's own, since that rule will apply to its next update.
        let found = explanation.status == .upToDate || explanation.status == .updateUnknown
        guard found || policy.source == .item else { return [] }
        var lines = ["", bold("Policy") + ": " + policy.policy.displayName, setBy]
        if !explanation.configuration.automaticModificationsAllowed {
            lines.append("  MacUp's configuration has errors, so MacUp would change nothing until they are fixed.")
        }
        if explanation.installed?.pinnedByProvider == true {
            lines.append("  \(explanation.item.provider.displayName) has it pinned, so MacUp would leave an update alone.")
        }
        lines.append(found
            ? "  No update is available, so there is nothing to decide yet."
            : "  The rule applies to its next update.")
        return lines
    }

    private func plan(_ explanation: ItemExplanation) -> [String] {
        let title = bold("What MacUp would run")
        if let plan = explanation.plan, let decision = explanation.policy.decision {
            let allowed = decision.action == .allow
            var lines = ["", title + dim(allowed ? " · without asking" : " · once you confirm")]
            for step in plan.steps {
                lines.append("  " + text(step.summary))
                lines.append("    Runs: " + path(step.invocation.displayString))
                lines.append("    " + dim("Time limit: " + Self.duration(step.timeoutSeconds)))
            }
            lines += indentedLines(plan.rationale)
            let effects = plan.effectSummaries(includingReassuring: true).joined(separator: " · ")
            lines.append("  " + effects.prefix(1).uppercased() + effects.dropFirst())
            for step in plan.verification {
                lines.append("  Confirms afterwards: " + text(step.summary))
                if let invocation = step.invocation {
                    lines.append("    Reads: " + path(invocation.displayString))
                }
            }
            lines.append("  Undo: " + text(plan.rollback.explanation))
            let command = "macup update " + CommandInvocation.quoted(explanation.item.rawValue)
            lines.append("  " + dim(allowed
                ? "`\(command)` runs it."
                : "`\(command)` shows this plan, asks you, and then runs it."))
            return lines
        }
        guard explanation.update != nil || explanation.installed != nil else { return [] }
        var lines = ["", title + ": nothing"]
        guard let skipped = explanation.skipped else {
            lines.append(explanation.status == .upToDate
                ? "  There is no update to apply."
                : "  MacUp knows of no update to apply.")
            return lines
        }
        if let decision = skipped.decision, decision.action == .deny {
            lines.append("  The policy above leaves it alone.")
            if let hint = denialHint(decision, item: explanation.item) { lines.append("  " + dim(hint)) }
            return lines
        }
        lines += indentedLines(skipped.reason)
        if let error = skipped.error {
            if let detail = error.detail, detail != skipped.reason {
                lines += detail.split(separator: "\n").prefix(6).map { "  " + text(String($0)) }
            }
            if let suggestion = error.recoverySuggestion {
                lines += indentedLines(suggestion)
            }
        }
        return lines
    }

    private func history(_ explanation: ItemExplanation) -> [String] {
        let history = explanation.history
        if let problem = history.problem {
            return ["", bold("History") + ": MacUp could not read it.", "  " + text(problem)]
        }
        guard !history.entries.isEmpty else {
            var lines = ["", bold("History") + ": nothing recorded for this item."]
            lines += unreadableNote(history)
            return lines
        }
        let shown = history.entries.count
        let count = history.moreAvailable
            ? (shown == 1 ? "the most recent entry" : "the \(shown) most recent entries")
            : Self.plural(shown, "entry", "entries")
        var lines = ["", bold("History") + dim(" · " + count + (shown > 1 ? ", newest first" : ""))]
        // The same headline, versions, and labelled facts `macup history`
        // and the History screen show, so an attempt reads the same anywhere.
        for entry in history.entries {
            lines.append("  " + HistoryEntry.timestampText(entry.timestamp, in: timeZone) + "  " + text(entry.headline.text))
            lines.append("      " + safe(entry.versionSummary))
            if let state = entry.stateAfter {
                lines.append("      " + text(state))
            }
            if let reason = entry.skipReason {
                lines.append("      Why: " + text(reason))
            }
            lines.append("      " + dim(entry.circumstances.joined(separator: " · ")))
            if let error = entry.errorSummary {
                let details = error.split(separator: "\n").prefix(6).map { text(String($0)) }
                lines += details.enumerated().map { index, line in "      " + (index == 0 ? "Details: " : "         ") + line }
            }
            if let command = entry.command {
                lines += command.split(separator: "\n").map { "      Ran: " + path(String($0)) }
            }
        }
        if history.moreAvailable {
            lines.append("  " + dim("`macup history` shows the older ones."))
        }
        lines += unreadableNote(history)
        return lines
    }

    private func unreadableNote(_ history: ItemExplanation.History) -> [String] {
        guard history.unreadableLines > 0 else { return [] }
        return ["  note: " + (history.unreadableLines == 1
            ? "One line of MacUp's history could not be read, and it may have been about this item."
            : "\(history.unreadableLines) lines of MacUp's history could not be read, and they may have been about this item.")]
    }

    // MARK: Policy wording

    /// The rule that supplies the item's policy, and where it lives.
    private func setByPhrase(_ policy: ItemExplanation.Policy, item: PackageID) -> String {
        let rule = safe(policy.rule)
        switch policy.source {
        case .item: return "a rule you set for this item (\(rule))"
        case .provider: return "the rule for \(item.provider.displayName) (\(rule))"
        default: return "the default policy (\(rule))"
        }
    }

    /// What overrode that rule, when something did.
    private func overridePhrase(_ decision: PolicyDecision, item: PackageID) -> String? {
        let provider = item.provider.displayName
        switch decision.source {
        case .item, .provider, .global: return nil
        case .providerDisabled: return "\(provider) is turned off in MacUp's configuration (providers.\(item.provider.rawValue).enabled)"
        case .providerPin: return "\(provider)'s own pin, which MacUp never overrides"
        case .risk: return "the risk of this change"
        case .configuration: return "MacUp's configuration, which it could not read"
        case .unattended: return "a scheduled run, which only updates items set to Auto Update"
        case .skippedVersion: return "the version you skipped (items.\(item.rawValue).skipVersion)"
        }
    }

    /// How to change a refusal, where MacUp can say.
    private func denialHint(_ decision: PolicyDecision, item: PackageID) -> String? {
        let id = CommandInvocation.quoted(item.rawValue)
        switch decision.source {
        case .item: return "`macup policy clear \(id)` removes the rule for this item."
        case .providerDisabled: return "`macup provider enable \(item.provider.rawValue)` turns \(item.provider.displayName) back on."
        case .providerPin: return "Unpin it in \(item.provider.displayName) yourself if you want this update."
        case .configuration: return "`macup config show` lists what is wrong with the configuration."
        case .skippedVersion: return "`macup policy unskip \(id)` offers this version again."
        case .provider, .global, .risk, .unattended: return nil
        }
    }

    // MARK: Text

    /// Untrusted text, with anything secret-shaped removed and anything that
    /// could act on a terminal made visible.
    private func safe(_ value: String) -> String {
        TerminalText.sanitize(Redactor().redact(value))
    }

    /// A path, with the home directory as `~`.
    private func path(_ value: String) -> String {
        safe(PathDisplay.abbreviatingHome(value, homeDirectory: homeDirectory))
    }

    /// Free text that may mention paths under the home directory.
    private func text(_ value: String) -> String {
        safe(PathDisplay.abbreviatingHome(in: value, homeDirectory: homeDirectory))
    }

    /// Free text of one or more lines, each indented under its heading.
    private func indentedLines(_ value: String) -> [String] {
        value.split(separator: "\n").map { "  " + text(String($0)) }
    }

    static func kind(_ kind: ItemKind?, of provider: ProviderID) -> String {
        switch kind {
        case .formula?: "Homebrew formula"
        case .cask?: "Homebrew cask"
        case .globalPackage?: "global npm package"
        case .tool?: "mise tool"
        case .systemUpdate?: "macOS update"
        case nil: provider.displayName
        }
    }

    static func change(_ change: VersionChange) -> String {
        switch change {
        case .major, .minor, .patch, .build: "a \(change.displayName) change"
        case .revision: "a new packaging revision"
        case .prerelease: "a pre-release"
        case .none: "the same version"
        case .downgrade: "older than the installed version"
        case .unknown: "a change MacUp could not classify"
        }
    }

    static func versions(current: String?, proposed: String?) -> String {
        let from = current ?? "unknown"
        guard let proposed else { return from }
        return from + " → " + proposed
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        if whole >= 3600, whole % 3600 == 0 { return plural(whole / 3600, "hour") }
        if whole >= 60, whole % 60 == 0 { return plural(whole / 60, "minute") }
        return plural(whole, "second")
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
        TextCount.plural(count, singular, plural)
    }

    static func pad(_ text: String, to width: Int) -> String {
        TextCount.pad(text, to: width)
    }
}
