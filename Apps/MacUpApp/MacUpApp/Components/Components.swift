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
            Image(systemName: symbol).foregroundStyle(tint)
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
            Image(systemName: "xmark.octagon").foregroundStyle(.red)
        }
    }
}
