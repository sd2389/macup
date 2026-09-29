import MacUpCore
import SwiftUI

/// The Updates screen's Filter menu: provider, risk, the policy in effect,
/// and Needs Attention. Choices within a group are alternatives and the
/// groups combine, exactly as `macup check --risk high --risk unknown
/// --policy ask` does, because both go through ``UpdateFilter``.
struct UpdateFilterMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Section("Provider") {
                ForEach(model.filterableProviders, id: \.self) { provider in
                    Toggle(provider.displayName, isOn: member(\.providers, provider))
                }
            }
            Section("Risk") {
                ForEach([RiskLevel.high, .unknown, .moderate, .low], id: \.self) { level in
                    Toggle(level.displayName.capitalizedFirst, isOn: member(\.riskLevels, level))
                }
            }
            Section("Policy") {
                ForEach([UpdatePolicy.auto, .ask, .ignore, .pin], id: \.self) { policy in
                    Toggle(policy.displayName, isOn: member(\.policies, policy))
                }
            }
            Section {
                Toggle("Needs Attention", isOn: $model.updateFilter.needsAttentionOnly)
                    .help("An earlier install that did not finish, or an update that will be built from source")
            }
            Divider()
            Button("Show All Updates") { model.showAllUpdates() }
                .disabled(!model.updateFilter.isActive)
        } label: {
            // The filled symbol is a change of shape, not only of colour; the
            // count of hidden updates is also written out above the list.
            Label(
                "Filter",
                systemImage: model.updateFilter.hasCriteria
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help(model.updateFilter.hasCriteria
            ? "Filtering: \(model.updateFilter.summary.displaySafe)"
            : "Show only some updates")
        .accessibilityLabel("Filter")
        .accessibilityValue(model.updateFilter.hasCriteria ? model.updateFilter.summary.displaySafe : "Off")
    }

    /// Whether `value` is one of the filter's choices, as a switch.
    private func member<Value: Hashable>(
        _ keyPath: WritableKeyPath<UpdateFilter, Set<Value>>,
        _ value: Value
    ) -> Binding<Bool> {
        Binding(
            get: { model.updateFilter[keyPath: keyPath].contains(value) },
            set: { isOn in
                if isOn {
                    model.updateFilter[keyPath: keyPath].insert(value)
                } else {
                    model.updateFilter[keyPath: keyPath].remove(value)
                }
            }
        )
    }
}

/// How the Updates list is ordered. Ordering hides nothing.
struct UpdateSortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            Picker("Sort By", selection: $model.updateSort) {
                ForEach(UpdateSortOrder.allCases, id: \.self) { order in
                    Text(order.menuTitle).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort updates: \(model.updateSort.menuTitle)")
        .accessibilityLabel("Sort")
        .accessibilityValue(model.updateSort.menuTitle)
    }
}

/// Says how many updates the search and filter are hiding, with the way to
/// see them all. Shown whenever anything is hidden, above the list where it
/// cannot be scrolled away, so a filter never quietly shortens the list
/// (CLAUDE.md §21).
struct HiddenUpdatesBar: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        // A plain row. `ViewThatFits` here made the whole window lay out
        // taller than itself, pushing every column up under the toolbar; in a
        // narrow window this one simply wraps.
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(message)
                if !model.updateFilter.summary.isEmpty {
                    Text("Showing: \(model.updateFilter.summary.displaySafe)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button("Show All") { model.showAllUpdates() }
                .accessibilityLabel("Show all updates")
                .accessibilityHint("Clears the search and every filter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// The list's only row when the search and filter leave nothing to show. The
/// bar above it still says how many are hidden and offers Show All.
struct NoMatchingUpdatesRow: View {
    var body: some View {
        ContentUnavailableView(
            "No Matching Updates",
            systemImage: "line.3.horizontal.decrease.circle",
            description: Text("Nothing MacUp found matches the current filter.")
        )
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }
}

extension UpdateSortOrder {
    /// As the Sort menu names it.
    var menuTitle: String {
        switch self {
        case .provider: "Grouped by Provider"
        case .risk: "Risk, Highest First"
        case .name: "Name"
        case .change: "Size of Change, Largest First"
        }
    }

    /// The heading over a list in this order, when it is not grouped.
    var listTitle: String {
        switch self {
        case .provider: "Updates"
        case .risk: "By Risk, Highest First"
        case .name: "By Name"
        case .change: "By Size of Change, Largest First"
        }
    }
}
