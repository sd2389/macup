import MacUpCore
import SwiftUI

/// The toolbar's Ask MacUp button, shown only while AI help is on. The CLI
/// equivalent is `macup ask`.
struct AskMacUpButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ai = model.ai
        Button {
            ai.isShowingAsk.toggle()
        } label: {
            Label("Ask MacUp", systemImage: "text.bubble")
        }
        .help("Ask for a rule change in plain words. Nothing changes until you confirm.")
        .popover(isPresented: $ai.isShowingAsk, arrowEdge: .bottom) {
            AskMacUpView()
                .frame(width: 440)
        }
    }
}

/// A request in plain words, what MacUp made of it, and — for a change —
/// the exact change with Confirm and Cancel.
struct AskMacUpView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var ai = model.ai
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask MacUp").font(.headline)
            HStack {
                TextField("For example: stop updating mysql", text: $ai.askText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(ask)
                    .accessibilityLabel("What you would like MacUp to do")
                Button("Ask", action: ask)
                    .disabled(!canAsk)
            }
            if ai.isAsking {
                ProgressView("Asking TypeSafe…").controlSize(.small)
            }
            if let problem = ai.askProblem {
                Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applied = ai.appliedSummary {
                Label(applied.displaySafe, systemImage: "checkmark.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let interpretation = ai.interpretation {
                AskResultCard(interpretation: interpretation)
            }
            Text("Sends what you type and the names of packages MacUp found to TypeSafe. Nothing changes until you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear { isFocused = true }
    }

    private var canAsk: Bool {
        !model.ai.isAsking && !model.ai.askText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ask() {
        guard canAsk else { return }
        Task { await model.askMacUp() }
    }
}

/// What TypeSafe made of a request, composed by MacUp.
struct AskResultCard: View {
    @Environment(AppModel.self) private var model
    let interpretation: AskInterpretation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(interpretation.message.displaySafe)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            switch interpretation.outcome {
            case .proposal(let proposal):
                ProposalView(proposal: proposal, showsConfidence: false)
            case .explanation(let explanation):
                ForEach(explanation.lines, id: \.self) { line in
                    Text(line.displaySafe)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unsure(let guesses), .noMatch(let guesses):
                if let chosen = model.ai.chosenGuess {
                    ProposalView(proposal: chosen, showsConfidence: true)
                } else {
                    ForEach(guesses) { guess in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(guess.title.displaySafe)
                                Text("\(AskMacUp.percent(guess.confidence)) likely").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Choose…") { model.ai.chosenGuess = guess }
                                .accessibilityLabel("Choose \(guess.title)")
                        }
                    }
                }
            case .notPossible, .notUnderstood:
                EmptyView()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

/// One change, exactly as it would be written, with Confirm and Cancel.
private struct ProposalView: View {
    @Environment(AppModel.self) private var model
    let proposal: AskProposal
    /// The message above already says how sure TypeSafe was of the answer;
    /// a guess picked from a list says it here.
    let showsConfidence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.title.displaySafe).font(.headline)
            Text(proposal.effect.displaySafe)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(proposal.path.displaySafe): \(proposal.currentValue.displaySafe) → \(proposal.newValue.displaySafe)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if proposal.loosens {
                Label("This lets MacUp do more without asking you.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Text("Same as: \(proposal.command)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                if showsConfidence {
                    Text("TypeSafe is \(AskMacUp.percent(proposal.confidence)) sure of this one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelAsk() }
                Button("Confirm Change") { Task { await model.confirmAsk(proposal) } }
                    .disabled(model.isChangingPolicy)
                    // A change that loosens is never the default action.
                    .keyboardShortcut(proposal.loosens ? nil : .defaultAction)
                    .accessibilityHint("Makes this change to MacUp's configuration")
            }
            .padding(.top, 4)
        }
    }
}
