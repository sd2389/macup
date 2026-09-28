import MacUpCore
import SwiftUI

/// Every provider MacUp knows: whether this Mac has it, which copy MacUp
/// uses, and the two things the user decides about it — whether MacUp runs
/// it at all, and what its items get (Auto Update, Ask First, Ignore, or the
/// default). The CLI equivalents are `macup provider list|enable|disable` and
/// `macup policy set <provider> <policy>`.
struct ProvidersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rules = model.policyRules
        Form {
            if let problem = model.policyProblem {
                Section("Nothing was changed") {
                    Label(problem.displaySafe, systemImage: "xmark.octagon")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let change = model.lastPolicyChange {
                Section("Last change") {
                    Label(change.summary.displaySafe, systemImage: "checkmark.circle")
                    ForEach(change.warnings, id: \.self) { warning in
                        Label(warning.displaySafe, systemImage: "exclamationmark.triangle")
                    }
                }
            }

            ForEach(rules.providers) { rule in
                ProviderSection(
                    rule: rule,
                    inherited: rules.defaultPolicy,
                    report: model.report?.providers.first { $0.provider == rule.provider }
                )
            }

            Section {
                Text("Auto Update lets `macup update` run that provider's updates without asking; an unknown risk or a macOS update still waits for you, and so does a major version change unless you have turned that off. Ask First shows each update for you to confirm. Ignore leaves them all alone. Turning a provider off means MacUp does not even check it.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("What the rules mean")
            } footer: {
                Text("A rule on one item, set on the Updates screen, wins over its provider's rule.")
                    .leadingFooter()
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadConfiguration() }
    }
}

private struct ProviderSection: View {
    @Environment(AppModel.self) private var model
    let rule: PolicyListing.ProviderRule
    let inherited: UpdatePolicy
    let report: ProviderReport?

    var body: some View {
        Section {
            LabeledContent {
                ProviderPolicyControls(rule: rule, inherited: inherited)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text([rule.provider.displayName, report?.version?.displaySafe].compactMap { $0 }.joined(separator: " "))
                            .font(.headline)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(report?.hasErrors == true ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                } icon: {
                    Image(systemName: rule.provider.symbolName).accessibilityHidden(true)
                }
            }
            if let report, report.availability == .available || report.availability == .failed {
                if let path = report.executable?.path {
                    LabeledContent("Executable") {
                        Text(path.displayPath).textSelection(.enabled)
                    }
                }
                ForEach(report.facts, id: \.key) { fact in
                    LabeledContent(fact.label.displaySafe) {
                        Text(fact.value.displayPath).textSelection(.enabled)
                    }
                }
                if !updates.isEmpty {
                    LabeledContent("Updates") {
                        Button(updates.count == 1 ? "Show 1 Update" : "Show \(updates.count) Updates") {
                            model.selectedUpdate = updates.first?.id
                            model.section = .updates
                        }
                    }
                }
            }
        } footer: {
            Text(footer).leadingFooter()
        }
    }

    private var updates: [UpdateCandidate] {
        model.report?.updates(for: rule.provider) ?? []
    }

    private var status: String {
        guard rule.enabled else { return "Off: MacUp never runs it" }
        guard let report else { return "Not checked yet" }
        switch report.availability {
        case .disabled: return "Off: MacUp never runs it"
        case .unavailable: return "Not installed, or not found in your PATH"
        case .failed: return report.errors.first?.error.message.displaySafe ?? "Found but not usable"
        case .available: break
        }
        if report.hasErrors { return "Found, but the last check failed" }
        switch updates.count {
        case 0: return "Found · up to date"
        case 1: return "Found · 1 update"
        default: return "Found · \(updates.count) updates"
        }
    }

    private var footer: String {
        guard rule.enabled else {
            return "Turn it on to have MacUp check \(rule.provider.displayName) again."
        }
        if !model.canApplyUpdates(of: rule.provider), report?.availability == .available {
            return "MacUp reports \(rule.provider.displayName) updates and does not apply them. Its items get \(rule.effectivePolicy.displayName)."
        }
        return "Its items get \(rule.effectivePolicy.displayName) unless they have a rule of their own."
    }
}
