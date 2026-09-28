import MacUpCore
import SwiftUI

extension String {
    /// Provider output is untrusted: control and bidirectional-override
    /// characters are shown as visible escapes instead of being rendered.
    var displaySafe: String { TerminalText.sanitize(self) }

    /// A path with the home directory shortened to `~`, made display-safe.
    var displayPath: String {
        PathDisplay.abbreviatingHome(self, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path).displaySafe
    }

    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension ProviderID {
    var symbolName: String {
        switch self {
        case .homebrew: "mug"
        case .npm: "shippingbox"
        case .mise: "wrench.and.screwdriver"
        case .macos: "apple.logo"
        default: "puzzlepiece"
        }
    }
}

/// Risk is always stated in words; the tinted symbol only reinforces it.
struct RiskLabel: View {
    let level: RiskLevel

    var body: some View {
        Label {
            Text(level.displayName.capitalizedFirst)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
    }

    private var symbol: String {
        switch level {
        case .low: "checkmark.circle"
        case .moderate: "exclamationmark.circle"
        case .high: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch level {
        case .low: .green
        case .moderate: .orange
        case .high: .red
        case .unknown: .secondary
        }
    }
}

extension View {
    /// A grouped Form centres its section footers on macOS, which makes a
    /// sentence of explanation read as a caption floating away from what it
    /// explains. MacUp's footers are sentences, so they start where the
    /// section does — and every line of them does, which takes the text's own
    /// alignment as well as the frame's.
    func leadingFooter() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension UpdatePolicy {
    var symbolName: String {
        switch self {
        case .auto: "arrow.triangle.2.circlepath"
        case .ask: "hand.raised"
        case .ignore: "minus.circle"
        case .pin: "pin"
        case .inherit: "arrow.turn.down.right"
        }
    }
}

/// The policy in effect, always in words. The symbol repeats the word rather
/// than replacing it, because a policy is not something to guess at from an
/// outline (CLAUDE.md §21).
struct PolicyLabel: View {
    let policy: UpdatePolicy

    var body: some View {
        Label(policy.displayName, systemImage: policy.symbolName)
            .accessibilityLabel("Policy: \(policy.displayName)")
    }
}

/// The exact executable and argument list MacUp would pass to the operating
/// system, taken from the plan and never reassembled here.
///
/// The arguments are numbered because "the exact argument list" is the promise
/// (CLAUDE.md §2.4): a single line cannot show where one argument ends and the
/// next begins, and a package name with a space in it would read as two. The
/// shell-quoted line underneath is there to be copied and is never run.
struct CommandView: View {
    let step: ExecutionStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.summary.displaySafe).font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.invocation.executable.displayPath)
                    .font(.caption.monospaced())
                    .fontWeight(.medium)
                ForEach(Array(step.invocation.arguments.enumerated()), id: \.offset) { index, argument in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, alignment: .trailing)
                        Text(argument.displaySafe).font(.caption.monospaced())
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Runs \(step.invocation.executable) with \(step.invocation.arguments.count) arguments: "
                    + step.invocation.arguments.joined(separator: ", ")
            )
            Text(step.invocation.displayString.displayPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityLabel("Copyable form: \(step.invocation.displayString)")
        }
        .padding(.vertical, 2)
    }
}

/// One thing a plan declares about itself: whether it needs the network, may
/// ask for an administrator password, may require a restart, may edit a
/// configuration file, and whether it can be undone.
struct PlanEffectLabel: View {
    let symbol: String
    let title: String
    let value: String
    /// Marks the rows worth pausing over. Everything else is stated plainly:
    /// a tick beside "no" would be noise at best and misleading at worst.
    var isNoteworthy = false

    var body: some View {
        LabeledContent {
            if isNoteworthy {
                Label {
                    Text(value)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
            } else {
                Text(value)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// A diagnostic finding with its severity in words and symbol.
struct FindingRow: View {
    let finding: DiagnosticFinding

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.title.displaySafe)
                if let detail = finding.detail {
                    Text(detail.displayPath).font(.callout).foregroundStyle(.secondary)
                }
                if let recommendation = finding.recommendation {
                    Text(recommendation.displaySafe).font(.callout)
                }
            }
        } icon: {
            switch finding.severity {
            case .info: Image(systemName: "info.circle").foregroundStyle(.blue)
            case .warning: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            case .error: Image(systemName: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .accessibilityLabel("\(finding.severity.rawValue): \(finding.title)")
    }
}

/// What happened to one attempt, in the words MacUp is entitled to use.
///
/// An update MacUp could not confirm is never shown as confirmed. That one
/// distinction is the whole point of verification: if "succeeded" and
/// "succeeded, we think" looked the same, the field a user checks afterwards
/// would be worthless (CLAUDE.md §25).
struct OutcomeLabel: View {
    let outcome: ExecutionResult.Outcome
    let verification: VerificationResult.Outcome?

    var body: some View {
        Label(Self.wording(outcome, verification).text, systemImage: symbol)
            .accessibilityLabel("Result: \(Self.wording(outcome, verification).text)")
    }

    /// The sentence and whether it is good news, so a row can read the same in
    /// a result list, in history, and to VoiceOver.
    static func wording(
        _ outcome: ExecutionResult.Outcome,
        _ verification: VerificationResult.Outcome?
    ) -> (text: String, isGood: Bool) {
        switch outcome {
        case .succeeded:
            switch verification {
            case .verified:
                return ("Updated and confirmed", true)
            case .targetNotReached:
                return ("Ran, but a different version is installed", false)
            case .failed, .notPerformed, nil:
                return ("Succeeded, but MacUp could not confirm it", false)
            }
        case .failed:
            return ("Failed", false)
        case .timedOut:
            return ("Timed out", false)
        case .cancelled:
            return ("Stopped before it finished", false)
        case .skipped:
            return ("Not changed", true)
        }
    }

    private var symbol: String {
        switch (outcome, verification) {
        case (.succeeded, .verified): "checkmark.circle"
        case (.succeeded, _): "questionmark.circle"
        case (.skipped, _): "minus.circle"
        case (.cancelled, _): "stop.circle"
        default: "xmark.octagon"
        }
    }
}

/// A failed provider operation: what failed, what MacUp ran, what to do next.
struct ErrorRow: View {
    let error: MacUpError

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(error.message.displaySafe)
                if let command = error.command {
                    Text("Ran: \(command.displayPath)\(error.exitStatus.map { " (exit status \($0))" } ?? "")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                if let detail = error.detail {
                    Text(detail.displayPath).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(6)
                }
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion.displaySafe).font(.callout)
                }
                Text("Nothing was changed.").font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(error.message)")
    }
}
