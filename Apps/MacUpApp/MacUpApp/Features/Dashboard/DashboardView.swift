import MacUpCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let report = model.report {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status.headline)
                            .font(.largeTitle.weight(.semibold))
                        Text(statusLine(report))
                            .foregroundStyle(.secondary)
                        if let next = scheduledNext {
                            Text("Next automatic check \(next.formatted(date: .abbreviated, time: .shortened)).")
                                .foregroundStyle(.secondary)
                        }
                        if report.summary.updatesAvailable > 0 {
                            Button("Review Updates") { model.section = .updates }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .padding(.top, 10)
                        }
                    }
                    .padding(.vertical, 10)
                }

                Section("Providers") {
                    ForEach(report.providers, id: \.provider) { provider in
                        ProviderRow(provider: provider, updateCount: report.updates(for: provider.provider).count)
                    }
                }

                if !attention(report).isEmpty {
                    Section("Needs Attention") {
                        ForEach(attention(report), id: \.self) { line in
                            Label(line, systemImage: "exclamationmark.triangle")
                        }
                        Button("Open Doctor") { model.section = .doctor }
                    }
                }
            }
            .formStyle(.grouped)
            .task { await model.refreshScheduleStatus() }
        } else if model.isChecking {
            ProgressView("Checking your Mac…")
        } else {
            ContentUnavailableView {
                Label("Not Checked Yet", systemImage: "arrow.clockwise")
            } description: {
                Text("Check Now shows what is outdated. Checking never changes anything.")
            } actions: {
                Button("Check Now") { Task { await model.checkNow() } }
            }
        }
    }

    /// When the next scheduled check will actually happen. Nil unless one is
    /// installed and loaded, so the dashboard never promises a check that is
    /// only configured.
    private var scheduledNext: Date? {
        guard let status = model.scheduleStatus, status.isActive else { return nil }
        return status.nextRun
    }

    private func statusLine(_ report: CheckReport) -> String {
        var parts = ["Checked at \(report.finishedAt.formatted(date: .omitted, time: .shortened)). Nothing was changed."]
        switch report.pinnedCount {
        case 0: break
        case 1: parts.append("1 update is pinned by its provider.")
        case let count: parts.append("\(count) updates are pinned by their providers.")
        }
        return parts.joined(separator: " ")
    }

    private func attention(_ report: CheckReport) -> [String] {
        var lines: [String] = []
        if model.configuration?.hasErrors == true {
            lines.append("The configuration file has errors, so automatic changes stay off until it is fixed.")
        }
        if model.environmentProblem != nil {
            lines.append("MacUp could not read your shell's environment and may miss some tools.")
        }
        for provider in report.providers where provider.hasErrors {
            lines.append("\(provider.displayName) could not be fully checked.")
        }
        let warnings = report.providers.flatMap(\.findings).filter { $0.severity != .info }.count
        if warnings > 0 {
            lines.append(warnings == 1 ? "1 warning from the last check." : "\(warnings) warnings from the last check.")
        }
        return lines
    }
}

private struct ProviderRow: View {
    let provider: ProviderReport
    let updateCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.provider.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text([provider.displayName, provider.version?.displaySafe].compactMap { $0 }.joined(separator: " "))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(status)
                .foregroundStyle(provider.hasErrors ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .padding(.vertical, 2)
    }

    private func fact(_ key: String) -> String? {
        provider.facts.first { $0.key == key }?.value
    }

    private var detail: String {
        switch provider.availability {
        case .disabled: return "Turned off in the configuration"
        case .unavailable: return "Not installed, or not found in your PATH"
        case .failed: return provider.errors.first?.error.message.displaySafe ?? "Found but not usable"
        case .available: break
        }
        if provider.provider == .npm, let node = fact("nodeVersion") {
            let manager = fact("nodeManager").map { $0 == "unrecognized" ? "" : ", managed by \($0)" } ?? ""
            return "Node \(node.displaySafe)\(manager.displaySafe)"
        }
        return provider.executable?.path.displayPath ?? ""
    }

    private var status: String {
        switch provider.availability {
        case .disabled: return "Off"
        case .unavailable: return "Not found"
        case .failed: return "Not usable"
        case .available: break
        }
        if provider.hasErrors { return "Check failed" }
        switch updateCount {
        case 0: return "Up to date"
        case 1: return "1 update"
        default: return "\(updateCount) updates"
        }
    }
}
