import Foundation
import MacUpCore

/// Everything about one update in one place, for the Updates screen's Copy
/// Details and Copy Command.
///
/// The explanation is MacUpCore's, built exactly as `macup explain` builds
/// it, and so is its wording: what the app copies is the text the command
/// prints. It is built from the check already on screen rather than a new
/// one, so it describes what the reader is looking at, and building it runs
/// nothing. The plan is described, never launched, and history is only read.
extension AppModel {
    /// What MacUp knows about one item: the last check's facts, the rules in
    /// force now, a one-item plan, and the item's recent history. `nil`
    /// before the first check.
    func explanation(for item: PackageID) async -> ItemExplanation? {
        guard let report else { return nil }
        let loaded = loadConfiguration()
        let explainer = ItemExplainer(checkEngine: environment.checkEngine, planner: environment.planner)
        let paths = try? MacUpPaths.resolve(
            homeDirectory: environment.homeDirectory,
            environment: environment.processEnvironment
        )
        return await explainer.explain(
            item,
            from: report,
            configuration: loaded,
            environment: await engineEnvironment(),
            history: paths.map { HistoryStore(paths: $0) }
        )
    }

    /// What Copy Details puts on the clipboard: word for word what
    /// `macup explain` prints for the item, with paths under the home
    /// directory written as `~`.
    func detailsText(for explanation: ItemExplanation) -> String {
        ExplanationText(homeDirectory: environment.homeDirectory).render(explanation)
    }

    /// What Copy Details copies for the item, worked out now.
    func copiedDetails(for item: PackageID) async -> String? {
        guard let explanation = await explanation(for: item) else { return nil }
        return detailsText(for: explanation)
    }

    /// What Copy Command copies for the item: the exact command line of its
    /// plan, or `nil` when MacUp would run nothing for it.
    func copiedCommand(for item: PackageID) async -> String? {
        await explanation(for: item)?.commandText
    }
}
