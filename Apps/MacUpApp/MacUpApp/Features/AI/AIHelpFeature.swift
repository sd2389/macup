import MacUpCore
import SwiftUI

/// "AI help from TypeSafe" on the Features screen: the switch, the key, the
/// disclosure, and the estimates MacUp has kept. The CLI equivalent is
/// `macup ai`.
struct AIHelpFeature: View {
    @Environment(AppModel.self) private var model
    @State private var draftKey = ""
    @State private var showsDisclosure = false

    var body: some View {
        @Bindable var ai = model.ai
        FeatureCard(
            symbol: "sparkles",
            title: "AI help from TypeSafe",
            summary: "Ask for rule changes in plain words, and get a second opinion on risky updates. Nothing is sent until you turn this on, and then only what you ask about.",
            isOn: enabled,
            isBusy: ai.isChanging,
            // Nothing to turn on without a key; turning off is always allowed.
            canChange: ai.status?.key.source != nil || ai.status?.enabled == true,
            state: ai.status?.summary
        ) {
            keyControls
            if ai.status?.isActive == true {
                HStack {
                    Button("Test Connection") { Task { await model.testAIConnection() } }
                        .disabled(ai.isTesting)
                        .help("Sends one fixed sentence and one fixed question. Nothing about this Mac.")
                    if ai.isTesting { ProgressView().controlSize(.small) }
                }
                if let result = ai.testResult {
                    Label(result.displaySafe, systemImage: "checkmark.circle")
                }
                if let problem = ai.testProblem {
                    Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
                }
            }
            if ai.savedEstimateCount > 0 {
                HStack {
                    Text(ai.savedEstimateCount == 1 ? "1 AI estimate saved on this Mac." : "\(ai.savedEstimateCount) AI estimates saved on this Mac.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Estimates") { model.forgetAIEstimates() }
                        .help("Delete them, and the cautions they added")
                }
            }
            DisclosureGroup("What MacUp sends", isExpanded: $showsDisclosure) {
                AIDisclosureView()
                    .padding(.top, 6)
            }
            if let problem = ai.settingsProblem {
                Label(problem.displaySafe, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let problem = ai.savedEstimatesProblem {
                Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
            }
        }
        .task { await model.refreshAIStatus() }
        .sheet(isPresented: $ai.isShowingEnableSheet) {
            AIEnableSheet()
        }
    }

    /// Where the key comes from, never the key itself. A key can be pasted in
    /// and saved to the Keychain; it is not shown again.
    @ViewBuilder
    private var keyControls: some View {
        let key = model.ai.status?.key
        if key?.keychainHasKey == true {
            HStack {
                Label("A key is saved in the Keychain.", systemImage: "key")
                Spacer()
                Button("Clear Key") { Task { await model.clearAIKey() } }
                    .disabled(model.ai.isChanging)
            }
        } else {
            if key?.environmentHasKey == true {
                Label("Using TYPESAFE_API_KEY from your shell.", systemImage: "key")
            }
            HStack {
                SecureField("TypeSafe API key", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("TypeSafe API key")
                    .onSubmit(save)
                Button("Save Key", action: save)
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Saved in your login keychain, never in a file. Saving a key sends nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(key?.problems ?? [], id: \.self) { problem in
            Label(problem.displaySafe, systemImage: "exclamationmark.triangle")
        }
    }

    private func save() {
        let text = draftKey
        Task {
            if await model.saveAIKey(text) { draftKey = "" }
        }
    }

    /// On shows what MacUp sends and waits for Turn On; off applies at once.
    private var enabled: Binding<Bool> {
        Binding(
            get: { model.ai.status?.enabled == true && model.ai.status?.configurationReadable == true },
            set: { model.requestAIEnabled($0) }
        )
    }
}

/// Shown when AI help is switched on: exactly what it sends, before anything
/// can be.
struct AIEnableSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on AI help from TypeSafe?").font(.title3.weight(.semibold))
            Text("Turning it on sends nothing. Afterwards, MacUp sends a request only when you ask it something.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                AIDisclosureView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 360)
            if let problem = model.ai.settingsProblem {
                Label(problem.displaySafe, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.ai.isShowingEnableSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On") { Task { await model.setAIEnabled(true) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.ai.isChanging)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// ``AIDisclosure/standard``, as a person reads it.
struct AIDisclosureView: View {
    private let disclosure = AIDisclosure.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(disclosure.features) { feature in
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title).font(.callout.weight(.semibold))
                    // Rendered as Markdown so a command reads as code, not as backticks.
                    Text(LocalizedStringKey(feature.when)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(feature.sends, id: \.self) { field in
                        Label(field, systemImage: "arrow.up.circle").font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("With every request").font(.callout.weight(.semibold))
                ForEach(disclosure.withEveryRequest, id: \.self) { field in
                    Label(field, systemImage: "arrow.up.circle").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Never sent").font(.callout.weight(.semibold))
                ForEach(disclosure.neverSent, id: \.self) { field in
                    Label(field, systemImage: "nosign").font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Link(destination: disclosure.dataProcessingAgreement) {
                Label("How TypeSafe handles what it receives: its Data Processing Agreement", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }
            .help(disclosure.dataProcessingAgreement.absoluteString)
        }
    }
}
