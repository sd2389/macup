import Foundation
import MacUpCore

/// Says which item a run has reached, by watching the commands go past.
///
/// The execution engine returns one report when the whole batch is over, which
/// is the right shape for the CLI and the wrong shape for a window someone is
/// watching. Rather than take the batch apart and run it item by item — which
/// would lose the engine's own rule that a failure stops the riskier changes
/// behind it — the app wraps the command runner and recognizes each request by
/// the plan it came from.
///
/// It recognizes, and passes the planned command's output on to the sheet as
/// it arrives, and nothing more. The map is built from the plans the user
/// reviewed, so a command that is not in one of them is simply not reported;
/// refusing it is the execution guard's job, not this type's. Nothing here
/// decides whether a command may run, and nothing here alters a request.
struct PlanProgressRunner: CommandRunning {
    var base: any CommandRunning
    /// Which item each exact invocation belongs to, taken from the plans.
    var owners: [CommandInvocation: PackageID]
    /// Called with the item whose command is about to start.
    var reachedItem: @MainActor @Sendable (PackageID) -> Void
    /// Where a planned command's output goes as it arrives, for the sheet.
    var lines: OutputLines?

    /// Builds the map from a plan report. Only the steps that change something
    /// are included: a verification command runs after the item is finished,
    /// so reporting it would move the progress backwards.
    init(
        base: any CommandRunning,
        planned: [PlannedUpdate],
        output lines: OutputLines? = nil,
        reachedItem: @MainActor @Sendable @escaping (PackageID) -> Void
    ) {
        self.base = base
        self.reachedItem = reachedItem
        self.lines = lines
        var owners: [CommandInvocation: PackageID] = [:]
        for update in planned {
            for step in update.plan.steps {
                owners[step.invocation] = update.item
            }
        }
        self.owners = owners
    }

    func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        // Awaited rather than detached, so the window's idea of which item is
        // running cannot arrive after the item has already finished.
        guard let item = owners[request.invocation] else {
            return try await base.run(request, output: output)
        }
        await reachedItem(item)
        guard let lines else { return try await base.run(request, output: output) }
        return try await base.run(request) { chunk in
            lines.append(chunk)
            output?(chunk)
        }
    }
}
