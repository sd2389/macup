import MacUpCore
import SwiftUI

/// Everything MacUp noticed about this Mac's developer environment, with
/// nothing changed.
///
/// Doctor explains. There is no "fix everything" button, and there is not
/// going to be one: the findings are things MacUp is not confident enough to
/// change on someone's behalf, which is exactly why it is telling them
/// (CLAUDE.md §13).
struct DoctorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let report = model.doctorReport {
                Form {
                    summary(report)
                    findings(report)
                    observed(report)
                }
                .formStyle(.grouped)
            } else if model.isDiagnosing {
                ProgressView("Looking at your Mac…")
            } else if let problem = model.doctorProblem {
                ContentUnavailableView {
                    Label("Diagnostics Could Not Run", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.displayPath)
                } actions: {
                    Button("Try Again") { Task { await model.runDoctor() } }
                }
            } else {
                ContentUnavailableView {
                    Label("Not Checked Yet", systemImage: "stethoscope")
                } description: {
                    Text("Doctor looks at how your package managers are installed and how MacUp is set up. It reads; it changes nothing.")
                } actions: {
                    Button("Run Diagnostics") { Task { await model.runDoctor() } }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isDiagnosing {
                    ProgressView().controlSize(.small).help("Running diagnostics")
                } else {
                    Button {
                        Task { await model.runDoctor() }
                    } label: {
                        Label("Run Again", systemImage: "arrow.clockwise")
                    }
                    .help("Run the diagnostics again. They only read.")
                }
            }
        }
        // A report whose check was cancelled — because the reader left this
        // screen part-way through — is incomplete, and coming back should
        // finish the job rather than keep showing the half of it that ran.
        .task { if model.doctorReport == nil || model.doctorReport?.cancelled == true { await model.runDoctor() } }
    }

    // MARK: Summary

    @ViewBuilder
    private func summary(_ report: DoctorReport) -> some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: report.isHealthy ? "checkmark.seal" : "stethoscope")
                    .font(.system(size: 28))
                    .foregroundStyle(report.isHealthy ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(headline(report)).font(.title2.weight(.semibold))
                    Text(detail(report)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if report.cancelled {
                        Label("The check behind these findings was cancelled, so some may be missing.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline(report)). \(detail(report))")
        }
    }

    private func headline(_ report: DoctorReport) -> String {
        if report.summary.errors > 0 {
            return report.summary.errors == 1 ? "1 problem needs your attention" : "\(report.summary.errors) problems need your attention"
        }
        if report.summary.warnings > 0 {
            return report.summary.warnings == 1 ? "1 thing is worth a look" : "\(report.summary.warnings) things are worth a look"
        }
        return "Nothing needs your attention"
    }

    private func detail(_ report: DoctorReport) -> String {
        var parts = ["\(report.summary.checksRun) checks ran at \(report.finishedAt.formatted(date: .omitted, time: .shortened)). Nothing was changed."]
        if report.summary.notes > 0 {
            parts.append(report.summary.notes == 1 ? "There is also 1 note below." : "There are also \(report.summary.notes) notes below.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Findings

    /// Grouped by severity, most severe first, so a healthy Mac reads as calm
    /// rather than as an empty screen.
    @ViewBuilder
    private func findings(_ report: DoctorReport) -> some View {
        let groups: [(DiagnosticFinding.Severity, String, String)] = [
            (.error, "Needs attention", "MacUp is not confident enough to change any of these for you."),
            (.warning, "Worth a look", "None of these stops MacUp working."),
            (.info, "Notes", "Things MacUp noticed that are probably fine."),
        ]
        ForEach(groups, id: \.0) { severity, title, footer in
            let matching = report.findings.filter { $0.severity == severity }
            if !matching.isEmpty {
                Section {
                    ForEach(matching, id: \.self) { finding in
                        FindingRow(finding: finding)
                    }
                } header: {
                    Text(title)
                } footer: {
                    Text(footer).leadingFooter()
                }
            }
        }
    }

    // MARK: What MacUp looked at

    @ViewBuilder
    private func observed(_ report: DoctorReport) -> some View {
        Section {
            ForEach(report.providers, id: \.provider) { provider in
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(availability(provider))
                        if let path = provider.executable?.path {
                            Text(path.displayPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                } label: {
                    Label(
                        [provider.displayName, provider.version?.displaySafe].compactMap { $0 }.joined(separator: " "),
                        systemImage: provider.provider.symbolName
                    )
                }
                .accessibilityElement(children: .combine)
            }
            LabeledContent("Configuration", value: report.configuration.path.displayPath)
        } header: {
            Text("What MacUp looked at")
        } footer: {
            Text("Doctor explains what it found. It changes nothing, and it has no button that would.")
                .leadingFooter()
        }
    }

    private func availability(_ provider: ProviderReport) -> String {
        switch provider.availability {
        case .available: provider.hasErrors ? "Found; check failed" : "Found"
        case .disabled: "Turned off in the configuration"
        case .unavailable: "Not found"
        case .failed: "Found but not usable"
        }
    }
}
