import MacUpCore
import SwiftUI

/// Whether MacUp runs a provider, and the rule its items inherit: the same
/// two controls on the Providers screen and in Settings, both written
/// through ``PolicyEditor`` exactly as `macup provider enable|disable` and
/// `macup policy set <provider>` are.
struct ProviderPolicyControls: View {
    @Environment(AppModel.self) private var model
    let rule: PolicyListing.ProviderRule
    let inherited: UpdatePolicy

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Policy", selection: policy) {
                    Text("Use the Default (\(inherited.displayName))").tag(UpdatePolicy.inherit)
                    Text(UpdatePolicy.auto.displayName).tag(UpdatePolicy.auto)
                    Text(UpdatePolicy.ask.displayName).tag(UpdatePolicy.ask)
                    Text(UpdatePolicy.ignore.displayName).tag(UpdatePolicy.ignore)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(rule.effectivePolicy.displayName, systemImage: rule.effectivePolicy.symbolName)
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.isChangingPolicy || !rule.enabled)
            .accessibilityLabel(
                "Update policy for \(rule.provider.displayName), currently \(rule.effectivePolicy.displayName)"
            )
            Toggle("Enabled", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isChangingPolicy)
                .accessibilityLabel("Check \(rule.provider.displayName)")
        }
    }

    private var policy: Binding<UpdatePolicy> {
        Binding(
            get: { rule.policy },
            // Pin is not offered for a whole provider: holding every item of a
            // provider at its current version is what turning the provider off
            // means, and the validator refuses the rule outright.
            set: { newValue in Task { await model.setPolicy(newValue, for: rule.provider) } }
        )
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { rule.enabled },
            set: { newValue in Task { await model.setProviderEnabled(newValue, for: rule.provider) } }
        )
    }
}
