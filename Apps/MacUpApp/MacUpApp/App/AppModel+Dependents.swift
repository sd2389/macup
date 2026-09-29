import Foundation
import MacUpCore
import Observation

/// What the app has learned about what depends on each item someone asked
/// about, and the question in progress, if there is one.
///
/// Asking runs `brew uses --installed`, which is read-only but slow, so the
/// app asks only when someone presses Show What Depends on It, one item at a
/// time, and keeps each answer (with when it was given) until they ask again.
@MainActor
@Observable
final class DependentsModel {
    /// The latest answer for each item, including answers that were stopped
    /// or failed, so the screen says what happened rather than going blank.
    fileprivate(set) var reports: [PackageID: DependentsReport] = [:]
    /// The item whose question is running now.
    fileprivate(set) var runningItem: PackageID?
    /// The running question, so Cancel has something to cancel. Readable so
    /// a test can wait for it to finish unwinding.
    fileprivate(set) var task: Task<Void, Never>?
}

extension AppModel {
    /// The same lookup `macup dependents` runs, over the check's own providers.
    private var dependentsLookup: DependentsLookup {
        DependentsLookup(providers: environment.checkEngine.providers)
    }

    /// Whether the app can ask what depends on this item. Runs nothing, so a
    /// screen can decide whether to offer the button at all.
    func canListDependents(of item: PackageID) -> Bool {
        dependentsLookup.canList(item)
    }

    /// Asks what depends on `item`. Held as a task so Cancel can stop it.
    ///
    /// The answer reuses the installation the last check chose, so nothing
    /// is detected twice, and it goes through the lookup's own read-only
    /// guard: the only command it may add to a check's is `brew uses`.
    func showDependents(of item: PackageID) {
        guard dependents.task == nil, canListDependents(of: item) else { return }
        dependents.runningItem = item
        dependents.task = Task { [weak self] in
            guard let self else { return }
            let configuration = loadConfiguration()
            let environment = checkEnvironment(await loadEnvironment())
            let report = await dependentsLookup.run(
                item,
                configuration: configuration,
                environment: environment,
                after: self.report
            )
            dependents.reports[item] = report
            dependents.runningItem = nil
            dependents.task = nil
        }
    }

    /// Stops the question in progress. It only reads, so stopping it part-way
    /// leaves nothing behind but an answer that says it was stopped.
    func cancelDependents() {
        dependents.task?.cancel()
    }
}
