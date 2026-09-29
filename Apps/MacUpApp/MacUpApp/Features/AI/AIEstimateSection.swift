import MacUpCore
import SwiftUI

/// An AI estimate for the selected update, on request. Shown only while AI
/// help is on; with it off, the Updates screen is exactly what it was. The
/// CLI equivalent is `macup insight <package-id>`.
struct AIEstimateSection: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate

    var body: some View {
        if model.isAIOn && update.provider != .macos {
            Section {
                if let result = model.ai.estimates[update.id] {
                    EstimateDetail(update: update, result: result)
                } else if !model.ai.estimating.contains(update.id) {
                    Button("Ask TypeSafe About This Update") { Task { await model.estimate(update) } }
                        .help("Sends the package's ID and name, its package manager, and the two versions")
                }
                if model.ai.estimating.contains(update.id) {
                    ProgressView("Asking TypeSafe…").controlSize(.small)
                }
                if let problem = model.ai.estimateProblems[update.id] {
                    Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("AI Estimate")
            } footer: {
                Text("Sends only the package's name, its package manager, and the two versions. An estimate can add caution and never takes any away.")
                    .leadingFooter()
            }
            .task(id: update.id) { model.loadSavedEstimate(for: update) }
        }
    }
}

private struct EstimateDetail: View {
    @Environment(AppModel.self) private var model
    let update: UpdateCandidate
    let result: UpdateEstimateResult

    var body: some View {
        let estimate = result.estimate
        LabeledContent("Kind of software") {
            Text("\(estimate.softwareKind.displayName.capitalizedFirst), \(AskMacUp.percent(estimate.softwareKindProbability))")
        }
        LabeledContent("A major upgrade migrates its data") {
            Text(AskMacUp.percent(estimate.dataMigrationProbability))
        }
        if let caution = result.caution {
            // The words carry it; the colour only repeats them.
            Label(caution.note.displaySafe, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("MacUp asks before updating it, even if its rule is Auto Update.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Text("No caution: TypeSafe's judgments do not point to data at risk in this update.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Text("\(result.fromCache ? "Saved answer" : "Asked") \(estimate.askedAt.formatted(date: .abbreviated, time: .shortened)), \(estimate.model.displaySafe)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Ask Again") { Task { await model.estimate(update, refresh: true) } }
                .disabled(model.ai.estimating.contains(update.id))
        }
    }
}
