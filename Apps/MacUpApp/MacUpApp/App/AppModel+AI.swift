import Foundation
import MacUpCore

/// Opt-in AI help, driven through MacUpCore's ``AIService`` exactly as
/// `macup ai`, `macup ask`, and `macup insight` drive it.
///
/// Every request here starts from a button the user pressed. A change Ask
/// MacUp proposes goes through the same approval and the same
/// ``PolicyEditor`` as every other rule change in the app, and only after the
/// user has confirmed that exact change.
extension AppModel {
    var aiService: AIService { environment.ai }

    /// Whether AI help is on in a configuration MacUp could read.
    var isAIOn: Bool {
        configuration.map(isAIOn) ?? false
    }

    func isAIOn(_ loaded: LoadedConfiguration) -> Bool {
        aiService.appliesEstimates(aiConfiguration(loaded))
    }

    /// The configuration AI help reads. In a debug snapshot run AI help is
    /// shown on without the file on disk changing.
    func aiConfiguration(_ loaded: LoadedConfiguration) -> LoadedConfiguration {
        #if DEBUG
        guard ai.snapshotOverride else { return loaded }
        var copy = loaded
        copy.configuration.ai = MacUpConfiguration.AISettings(enabled: true)
        return copy
        #else
        return loaded
        #endif
    }

    /// Keeps the providers' report and returns it with the cautions of saved
    /// estimates added, while AI help is on. Reads one local file.
    func applyingAICautions(to report: CheckReport) -> CheckReport {
        ai.baseReport = report
        guard let loaded = configuration, isAIOn(loaded), let paths = try? resolvedPaths() else { return report }
        let (cautioned, problem) = aiService.cautioned(report, configuration: aiConfiguration(loaded), paths: paths)
        ai.savedEstimatesProblem = problem
        return cautioned
    }

    // MARK: - Status and settings

    /// Finds out whether AI help could send anything. Reads no secret and
    /// sends nothing.
    func refreshAIStatus() async {
        let loaded = aiConfiguration(loadConfiguration())
        ai.status = aiService.status(loaded, environment: await loadEnvironment())
        if let paths = try? resolvedPaths() {
            ai.savedEstimateCount = (try? aiService.estimates(paths).load().count) ?? 0
        }
    }

    /// The switch on the Features screen. Turning AI help on first shows what
    /// it sends; turning it off happens at once.
    func requestAIEnabled(_ enabled: Bool) {
        if enabled {
            ai.isShowingEnableSheet = true
        } else {
            Task { await setAIEnabled(false) }
        }
    }

    /// Writes `ai.enabled`. Turning it on is a change, so it goes through the
    /// approval in force; turning it off only ever makes MacUp do less.
    func setAIEnabled(_ enabled: Bool) async {
        guard !ai.isChanging else { return }
        ai.isChanging = true
        defer { ai.isChanging = false }
        ai.settingsProblem = nil

        let loaded = loadConfiguration()
        guard let paths = try? resolvedPaths() else {
            ai.settingsProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        if enabled && !loaded.hasErrors {
            let approval = await ApprovalGate(
                settings: loaded.configuration.security,
                authorizer: environment.authorizer,
                faceUnlock: faceUnlock(loaded.configuration, paths: paths)
            ).approve("turn on AI help from TypeSafe")
            guard approval.allowsChange else {
                ai.settingsProblem = approval.explanation
                return
            }
        }
        do {
            try AISettingsEditor(paths: paths).setEnabled(enabled)
        } catch let error as MacUpError {
            ai.settingsProblem = [error.message, error.detail, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n")
        } catch {
            ai.settingsProblem = "The setting could not be saved."
        }
        loadConfiguration()
        ai.isShowingEnableSheet = false
        if !enabled { resetAI() }
        reapplyAICautions()
        await refreshAIStatus()
    }

    /// Saves a pasted key in the Keychain. Returns whether it was saved, so
    /// the field can be emptied; the key is never shown again.
    @discardableResult
    func saveAIKey(_ text: String) async -> Bool {
        ai.settingsProblem = nil
        do {
            try aiService.keyStore.saveKey(try TypeSafeAPIKey(validating: text))
        } catch let error as AIError {
            ai.settingsProblem = error.message
            return false
        } catch {
            ai.settingsProblem = "The key could not be saved."
            return false
        }
        await refreshAIStatus()
        return true
    }

    func clearAIKey() async {
        ai.settingsProblem = nil
        do {
            try aiService.keyStore.deleteKey()
        } catch let error as AIError {
            ai.settingsProblem = error.message
        } catch {
            ai.settingsProblem = "The key could not be removed."
        }
        await refreshAIStatus()
    }

    /// One tiny request that says nothing about this Mac.
    func testAIConnection() async {
        guard !ai.isTesting else { return }
        ai.isTesting = true
        defer { ai.isTesting = false }
        ai.testResult = nil
        ai.testProblem = nil
        do {
            let result = try await aiService.testConnection(aiConfiguration(loadConfiguration()), environment: await loadEnvironment())
            ai.testResult = "TypeSafe answered: \(result.model), in \(result.milliseconds) ms. The key came from \(result.keySource.displayName)."
        } catch let error as AIError {
            ai.testProblem = error.message
        } catch {
            ai.testProblem = AIError.offline.message
        }
    }

    /// Deletes the saved estimates, and the cautions they added.
    func forgetAIEstimates() {
        guard let paths = try? resolvedPaths() else { return }
        do {
            try aiService.forgetEstimates(paths: paths)
            ai.estimates = [:]
            ai.estimateProblems = [:]
        } catch let error as MacUpError {
            ai.settingsProblem = error.message
        } catch {
            ai.settingsProblem = "The estimates could not be deleted."
        }
        reapplyAICautions()
        ai.savedEstimateCount = (try? aiService.estimates(paths).load().count) ?? 0
    }

    private func resetAI() {
        ai.interpretation = nil
        ai.chosenGuess = nil
        ai.askProblem = nil
        ai.appliedSummary = nil
        ai.estimates = [:]
        ai.estimateProblems = [:]
        ai.isShowingAsk = false
        ai.testResult = nil
    }

    // MARK: - Ask MacUp

    /// Sends what the user typed, with the packages the last check found, and
    /// shows what TypeSafe made of it. Changes nothing.
    func askMacUp() async {
        guard !ai.isAsking else { return }
        ai.isAsking = true
        defer { ai.isAsking = false }
        ai.interpretation = nil
        ai.chosenGuess = nil
        ai.askProblem = nil
        ai.appliedSummary = nil

        let loaded = aiConfiguration(loadConfiguration())
        let processEnvironment = await loadEnvironment()
        if let refusal = aiService.status(loaded, environment: processEnvironment).refusal {
            ai.askProblem = refusal.message
            return
        }
        // Installed items are kept only by a check made with AI help on, so a
        // report from before it was turned on is checked again, read-only.
        if report == nil || report?.providers.allSatisfy({ $0.items == nil }) == true {
            await checkNow()
        }
        guard let report else {
            ai.askProblem = "MacUp has not checked this Mac yet, so it has no packages to offer."
            return
        }
        do {
            ai.interpretation = try await aiService.ask(
                ai.askText,
                context: AskContext(report: report, configuration: loaded, homeDirectory: environment.homeDirectory),
                environment: processEnvironment
            )
        } catch let error as AIError {
            ai.askProblem = [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } catch {
            ai.askProblem = AIError.unexpectedResponse.message
        }
    }

    /// Makes the change the user confirmed, through the same approval and
    /// editor as every other rule change in the app.
    func confirmAsk(_ proposal: AskProposal) async {
        switch proposal.change {
        case .setItemPolicy(let item, let policy): await setPolicy(policy, for: item)
        case .clearItemPolicy(let item): await clearPolicy(for: item)
        case .setProviderPolicy(let provider, let policy): await setPolicy(policy, for: provider)
        case .setProviderEnabled(let provider, let enabled): await setProviderEnabled(enabled, for: provider)
        case .skipVersion(let item, let version): await skipVersion(AvailableVersion(version), for: item)
        case .unskipVersion(let item): await stopSkipping(item)
        case .setNote(let item, let note): await setNote(note, for: item)
        }
        if let problem = policyProblem {
            ai.askProblem = problem
        } else {
            ai.appliedSummary = lastPolicyChange?.summary
            ai.interpretation = nil
            ai.chosenGuess = nil
            ai.askText = ""
        }
    }

    func cancelAsk() {
        ai.interpretation = nil
        ai.chosenGuess = nil
        ai.askProblem = nil
    }

    // MARK: - AI caution for updates

    /// Shows the saved estimate for this update, if there is one. Reads a
    /// local file; sends nothing.
    func loadSavedEstimate(for update: UpdateCandidate) {
        guard ai.estimates[update.id] == nil, let loaded = configuration, isAIOn(loaded),
              let paths = try? resolvedPaths(),
              let saved = (try? aiService.estimates(paths).load())?.filter({ $0.matches(update) }).max(by: { $0.askedAt < $1.askedAt })
        else { return }
        ai.estimates[update.id] = UpdateEstimateResult(
            estimate: saved,
            caution: UpdateInsight.caution(for: providerCandidate(update), estimate: saved),
            fromCache: true
        )
    }

    /// Asks TypeSafe about one update, or reads the saved answer, and adds
    /// the caution it produces to what every screen shows.
    func estimate(_ update: UpdateCandidate, refresh: Bool = false) async {
        guard !ai.estimating.contains(update.id) else { return }
        ai.estimating.insert(update.id)
        defer { ai.estimating.remove(update.id) }
        ai.estimateProblems[update.id] = nil

        guard let paths = try? resolvedPaths() else { return }
        do {
            ai.estimates[update.id] = try await aiService.estimate(
                providerCandidate(update),
                configuration: aiConfiguration(loadConfiguration()),
                environment: await loadEnvironment(),
                paths: paths,
                refresh: refresh
            )
        } catch let error as AIError {
            ai.estimateProblems[update.id] = error.message
        } catch {
            ai.estimateProblems[update.id] = AIError.unexpectedResponse.message
        }
        reapplyAICautions()
        ai.savedEstimateCount = (try? aiService.estimates(paths).load().count) ?? 0
    }

    /// The candidate as its provider reported it, before any caution was
    /// added, which is what an estimate is about.
    private func providerCandidate(_ update: UpdateCandidate) -> UpdateCandidate {
        ai.baseReport?.updates.first { $0.id == update.id } ?? update
    }
}
