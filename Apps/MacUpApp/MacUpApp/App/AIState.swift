import Foundation
import MacUpCore
import Observation

/// What the app shows about opt-in AI help. Kept apart from ``AppModel``'s
/// own state so that, with AI help off, none of it is shown or acted on.
@MainActor
@Observable
final class AIState {
    /// What MacUp last found out, without reading the key or sending anything.
    var status: AIStatus?
    /// Turning AI help on or off, or saving or clearing the key.
    var isChanging = false
    var settingsProblem: String?
    /// Whether the sheet that shows what MacUp sends, before turning AI help
    /// on, is open.
    var isShowingEnableSheet = false

    var isTesting = false
    var testResult: String?
    var testProblem: String?

    /// Ask MacUp.
    var isShowingAsk = false
    var askText = ""
    var isAsking = false
    var interpretation: AskInterpretation?
    /// A guess the user picked from an unsure answer, waiting for Confirm.
    var chosenGuess: AskProposal?
    var askProblem: String?
    /// What the last confirmed change did, in PolicyEditor's own words.
    var appliedSummary: String?

    /// AI caution for updates.
    var estimates: [PackageID: UpdateEstimateResult] = [:]
    var estimating: Set<PackageID> = []
    var estimateProblems: [PackageID: String] = [:]
    var savedEstimateCount = 0
    /// Why the saved estimates could not be read, so none were applied.
    var savedEstimatesProblem: String?

    /// The check as the providers reported it, before saved cautions were
    /// added, so clearing the cautions can take them off again.
    var baseReport: CheckReport?

    #if DEBUG
    /// Snapshots only: show AI help as on without changing the configuration.
    var snapshotOverride = false
    #endif

    /// The real connection and Keychain, except in a debug snapshot run,
    /// which answers from canned replies and never reaches either.
    nonisolated static func liveService() -> AIService {
        #if DEBUG
        if Snapshots.directory != nil { return AISnapshotService.make() }
        #endif
        return .live()
    }
}
