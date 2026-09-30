import MacUpCore

/// The Updates screen's search, filter, and order.
///
/// What the list keeps is decided by ``UpdateFilter`` in MacUpCore, the same
/// filter behind `macup check --risk`, `--policy`, and `--attention`; this only
/// holds the screen's choice and says what it is hiding. Nothing else in the
/// app reads it: the dashboard, the sidebar badge, and the menu bar count
/// every update, whatever the list is showing.
extension AppModel {
    /// The Updates list: what the search and filter keep, in the chosen
    /// order, and what they hide. The policy matched is the one each row's
    /// label shows.
    var updateListing: UpdateListing {
        updateFilter.apply(
            to: report?.updates ?? [],
            sortedBy: updateSort,
            effectivePolicies: decisions.mapValues(\.policy)
        )
    }

    /// Providers the Filter menu offers: those with an update, plus any the
    /// filter already names, so a choice in force never vanishes from the menu.
    var filterableProviders: [ProviderID] {
        Set((report?.updates ?? []).map(\.provider)).union(updateFilter.providers).sorted()
    }

    /// "2 updates hidden by the current filter", or nil when nothing is
    /// hidden. A search counts as part of the filter.
    var hiddenUpdatesMessage: String? {
        let hidden = updateListing.hiddenCount
        guard hidden > 0 else { return nil }
        return (hidden == 1 ? "1 update" : "\(hidden) updates") + " hidden by the current filter"
    }

    /// Clears the search and every filter. The order stays: it hides nothing.
    func showAllUpdates() {
        updateFilter = UpdateFilter()
    }

    /// Opens the Updates screen on one update. If the filter would hide it,
    /// the filter is cleared, because this is the one item the person asked
    /// to see.
    func showUpdate(_ item: PackageID) {
        if let update = report?.updates.first(where: { $0.id == item }),
           !updateFilter.matches(update, policy: decisions[item]?.policy) {
            showAllUpdates()
        }
        selectedUpdate = item
        section = .updates
    }

    /// ⌘F: the Updates screen, with its search field ready for typing.
    ///
    /// The field takes focus when this flag turns true while the screen is
    /// showing. It does not when the screen first appears with the flag
    /// already true, nor when the flag is set to true a second time after
    /// focus has moved on. So the flag goes off, and on again once the
    /// Updates screen is there.
    func searchUpdates() {
        section = .updates
        isSearchingUpdates = false
        Task { [weak self] in self?.isSearchingUpdates = true }
    }
}

extension AppModel.Section {
    /// The name the sidebar and the View menu give this section.
    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .providers: "Providers"
        case .updates: "Updates"
        case .uninstall: "Uninstall"
        case .features: "Features"
        case .doctor: "Doctor"
        case .history: "History"
        }
    }
}
