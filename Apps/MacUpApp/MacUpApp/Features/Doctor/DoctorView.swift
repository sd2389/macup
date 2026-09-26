import MacUpCore
import SwiftUI

/// Findings and failures from the last check. Doctor explains; it never fixes.
struct DoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let providers = (model.report?.providers ?? []).filter { !$0.findings.isEmpty || !$0.errors.isEmpty }
        let issues = model.configuration?.issues ?? []
        if providers.isEmpty && issues.isEmpty && model.environmentProblem == nil {
            ContentUnavailableView(
                "No Issues Found",
                systemImage: "checkmark.seal",
                description: Text(model.report == nil ? "Run a check first." : "Nothing in the last check needs your attention.")
            )
        } else {
            Form {
                if let problem = model.environmentProblem {
                    Section("Shell Environment") {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(problem.displaySafe)
                                Text("MacUp may not find tools installed outside the standard locations. You can set explicit paths in the configuration file.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                    }
                }

                if !issues.isEmpty {
                    Section("Configuration") {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            FindingRow(finding: DiagnosticFinding(
                                id: "configuration",
                                severity: issue.severity == .error ? .error : .warning,
                                provider: nil,
                                title: issue.path.isEmpty ? issue.message : "\(issue.path): \(issue.message)"
                            ))
                        }
                    }
                }

                ForEach(providers, id: \.provider) { provider in
                    Section(provider.displayName) {
                        ForEach(Array(provider.errors.enumerated()), id: \.offset) { _, failure in
                            ErrorRow(error: failure.error)
                        }
                        ForEach(Array(provider.findings.enumerated()), id: \.offset) { _, finding in
                            FindingRow(finding: finding)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}
