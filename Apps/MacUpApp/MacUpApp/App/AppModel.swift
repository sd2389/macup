import AVFoundation
import Foundation
import MacUpCore
import Observation

/// Everything the windows and the menu bar show. One instance per app.
///
/// All engine work goes through MacUpCore; this type only schedules it and
/// holds the latest results.
@MainActor
@Observable
final class AppModel {
    /// Declared in sidebar order, which ⌘1…⌘6 follow.
    enum Section: Hashable, CaseIterable {
        case dashboard, providers, updates, uninstall, features, doctor, history
    }

    var section: Section? = .dashboard
    /// Which update the Updates screen has selected. On the model so the
    /// dashboard can open a provider's first update directly.
    var selectedUpdate: PackageID?
    /// What the Updates screen's list is narrowed to, and how it is ordered.
    /// Only that list: the dashboard, the sidebar badge, and the menu bar
    /// always count everything. See AppModel+UpdateList.swift.
    var updateFilter = UpdateFilter()
    var updateSort = UpdateSortOrder.provider
    /// Whether the Updates screen's search field has focus; ⌘F sets it.
    var isSearchingUpdates = false
    private(set) var report: CheckReport?
    private(set) var configuration: LoadedConfiguration?
    private(set) var isChecking = false
    private(set) var shell: String?
    /// Why the login-shell environment could not be read, if it could not.
    private(set) var environmentProblem: String?

    /// What is actually scheduled, as opposed to what the configuration asks
    /// for. Read from launchd and the installed agent.
    private(set) var scheduleStatus: ScheduleStatus?
    private(set) var isChangingSchedule = false
    /// Why the last scheduling change did not happen, if it did not.
    private(set) var scheduleProblem: String?

    /// The login shell's environment, once it has been read.
    private var shellEnvironment: [String: String]?
    /// Everything outside this type: the command runner, the file system,
    /// macOS authentication, the camera, the check engine, and where the
    /// user's files live. ``AppEnvironment/live()`` is what a shipping build
    /// passes; a test passes fakes, and nothing here ever sees a fingerprint,
    /// a face, or a password either way.
    let environment: AppEnvironment
    /// What depends on each item someone asked about (AppModel+Dependents.swift).
    let dependents = DependentsModel()
    /// The Uninstall screen and its review sheet (AppModel+Uninstall.swift).
    let uninstaller = UninstallState()
    /// Every package manager on this Mac, managed or not (AppModel+Tools.swift).
    let tools = ToolScanModel()

    init(environment: AppEnvironment = .live()) {
        self.environment = environment
    }

    private var home: String { environment.homeDirectory }
    var authorizer: any BiometricAuthorizing { environment.authorizer }

    var updateCount: Int { report?.summary.updatesAvailable ?? 0 }

    /// The glanceable summary: never "up to date" unless the check is complete.
    var status: CheckStatus {
        CheckStatus(report: report, isChecking: isChecking, environmentProblem: environmentProblem)
    }

    /// Errors and warnings worth a look in Doctor.
    var attentionCount: Int {
        let providers = report?.providers ?? []
        let problems = providers.reduce(0) { total, provider in
            total + provider.errors.count + provider.findings.filter { $0.severity != .info }.count
        }
        return problems + (environmentProblem == nil ? 0 : 1) + (configuration?.hasErrors == true ? 1 : 0)
    }

    /// Runs a read-only check. Safe to call repeatedly; overlapping calls are ignored.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let processEnvironment = await loadEnvironment()
        let configuration = loadConfiguration()
        report = await environment.checkEngine.run(
            configuration: configuration,
            environment: checkEnvironment(processEnvironment)
        )
    }

    /// The outside world an engine runs against, with the login shell's
    /// environment when MacUp managed to read it. Built in one place so the
    /// check, the planner, the executor, and Doctor all see the same Mac.
    func checkEnvironment(_ processEnvironment: [String: String]) -> CheckEnvironment {
        CheckEnvironment(
            runner: environment.runner,
            fileSystem: environment.fileSystem,
            processEnvironment: processEnvironment,
            homeDirectory: home,
            system: environment.system
        )
    }

    /// That environment with the login shell's variables, for the model's
    /// extensions in other files.
    func engineEnvironment() async -> CheckEnvironment {
        checkEnvironment(await loadEnvironment())
    }

    // MARK: - Policy

    /// Every rule the configuration sets, as written, for the Settings screen.
    var policyRules: PolicyListing {
        configuration.map(PolicyListing.init) ?? PolicyListing(configuration: .defaults)
    }

    /// What policy says about each update the last check found, and why.
    ///
    /// Deciding needs no commands — only the rules, and the risk the provider
    /// already reported — so every screen can show the effective policy and
    /// its reason straight after a check, without waiting for a plan.
    var decisions: [PackageID: PolicyDecision] {
        guard let report, let configuration else { return [:] }
        let engine = PolicyEngine(configuration)
        return Dictionary(
            uniqueKeysWithValues: report.updates.map { ($0.id, engine.decide($0, intent: .interactive)) }
        )
    }

    /// Updates that could still happen: allowed, or waiting for the user.
    /// The top of the dashboard.
    var pendingUpdates: [UpdateCandidate] {
        let decisions = decisions
        return (report?.updates ?? []).filter { decisions[$0.id]?.allowsExecution != false }
    }

    /// Updates a rule, a skipped version, or a provider's own pin keeps back.
    /// Listed under the pending ones, with the reason, so a decision is never
    /// hidden.
    var leftAloneUpdates: [UpdateCandidate] {
        let decisions = decisions
        return (report?.updates ?? []).filter { decisions[$0.id]?.allowsExecution == false }
    }

    /// Items ruled Ignore or Pin that have no update right now. Still worth
    /// listing: the rule is in force and will apply to the next update.
    var heldRulesWithoutUpdate: [PolicyListing.ItemRule] {
        let updating = Set((report?.updates ?? []).map(\.id))
        return policyRules.items.filter {
            ($0.effectivePolicy == .ignore || $0.effectivePolicy == .pin) && !updating.contains($0.item)
        }
    }

    /// Updates that will wait for the user even though they were found.
    var updatesNeedingConfirmation: Int {
        decisions.values.filter { $0.action == .confirm }.count
    }

    /// Updates a rule says to leave alone. Shown, never dropped: it is a
    /// decision the user made, and hiding it would hide the decision
    /// (CLAUDE.md §21).
    var ignoredUpdateCount: Int {
        decisions.values.filter { $0.action == .deny && $0.policy == .ignore }.count
    }

    /// Updates held at their current version, whether by a MacUp rule or by
    /// the provider's own pin.
    var pinnedUpdateCount: Int {
        decisions.values.filter { $0.policy == .pin || $0.source == .providerPin }.count
    }

    /// What the last check found the named provider can do. Empty for a
    /// provider that was not checked, which is the conservative answer: a
    /// capability MacUp has not seen is one it does not offer.
    func capabilities(of provider: ProviderID) -> Set<ProviderCapability> {
        Set(report?.providers.first { $0.provider == provider }?.capabilities ?? [])
    }

    /// Whether MacUp can apply this provider's updates at all, as opposed to
    /// only reporting them. macOS updates are reported and never installed in
    /// this version, so the app does not offer a button that would only
    /// produce a refusal (CLAUDE.md §9).
    func canApplyUpdates(of provider: ProviderID) -> Bool {
        capabilities(of: provider).contains(.updateSelectedItems)
    }

    /// The last policy edit, so a screen can say what changed rather than
    /// only that something did.
    private(set) var lastPolicyChange: PolicyChange?
    /// Why the last policy edit did not happen, if it did not.
    private(set) var policyProblem: String?
    private(set) var isChangingPolicy = false

    func setPolicy(_ policy: UpdatePolicy, for item: PackageID) async {
        await editPolicy("set the rule for \(item.rawValue)") { try $0.setPolicy(policy, for: item) }
    }

    func clearPolicy(for item: PackageID) async {
        await editPolicy("clear the rule for \(item.rawValue)") { try $0.clearPolicy(for: item) }
    }

    func setPolicy(_ policy: UpdatePolicy, for provider: ProviderID) async {
        await editPolicy("set the rule for \(provider.displayName)") { try $0.setPolicy(policy, for: provider) }
    }

    func setProviderEnabled(_ enabled: Bool, for provider: ProviderID) async {
        await editPolicy("turn \(provider.displayName) \(enabled ? "on" : "off") in MacUp") {
            try $0.setProviderEnabled(enabled, for: provider)
        }
    }

    func setDefaultPolicy(_ policy: UpdatePolicy) async {
        await editPolicy("change MacUp's default update policy") { try $0.setDefaultPolicy(policy) }
    }

    /// Every policy edit the app makes, through the one editor that is allowed
    /// to make them (CLAUDE.md §12). The app validates nothing itself: the
    /// editor refuses a configuration it could not read and a result it would
    /// not use, and its refusal is what the user is shown.
    func editPolicy(
        _ action: String,
        _ edit: (PolicyEditor) throws -> PolicyChange
    ) async {
        guard !isChangingPolicy else { return }
        isChangingPolicy = true
        defer { isChangingPolicy = false }
        policyProblem = nil
        lastPolicyChange = nil

        let loaded = loadConfiguration()
        guard let paths = try? resolvedPaths() else {
            policyProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        // No approval is asked for a change that cannot happen: a
        // configuration with errors is refused below, with the reason.
        if !loaded.hasErrors {
            let approval = await ApprovalGate(
                settings: loaded.configuration.security,
                authorizer: authorizer,
                faceUnlock: faceUnlock(loaded.configuration, paths: paths)
            ).approve(action)
            guard approval.allowsChange else {
                policyProblem = approval.explanation
                return
            }
        }
        do {
            lastPolicyChange = try edit(PolicyEditor(paths: paths))
            loadConfiguration()
        } catch let error as MacUpError {
            policyProblem = [error.message, error.detail, error.recoverySuggestion]
                .compactMap { $0 }
                .joined(separator: "\n")
        } catch {
            policyProblem = "The rule could not be changed."
        }
    }

    // MARK: - Planning

    /// The plan under review: every change MacUp would make, with the exact
    /// commands, and every change it would not.
    private(set) var updatePlan: PlanReport?
    private(set) var isPlanning = false
    private(set) var planProblem: String?
    /// Whether the review sheet is open. Set by the model rather than by a
    /// view, because it must not open before there is a plan to show.
    var isReviewingPlan = false
    /// Items the user has confirmed in the review sheet. An item needing
    /// confirmation that is not in here does not run.
    private(set) var confirmedItems: Set<PackageID> = []
    /// Whether the review sheet has its command list open. On the model so it
    /// stays open when the sheet is closed and reopened, and so the state can
    /// be captured.
    var reviewShowsCommands = false

    /// Builds a plan for the named items, or for everything the last check
    /// found, and opens the review sheet.
    ///
    /// Planning reuses the candidates the check already produced, so it never
    /// checks the machine twice, and the planner's runner refuses anything
    /// that is not read-only.
    func reviewUpdates(_ selection: Set<PackageID>? = nil) async {
        guard await makePlan(selection) != nil else { return }
        confirmedItems = []
        executionReport = nil
        executionProblem = nil
        startedItems = []
        isReviewingPlan = true
    }

    /// Closes the review sheet. The plan is kept so its result stays readable
    /// if the sheet is reopened.
    func endReview() {
        isReviewingPlan = false
    }

    func setConfirmed(_ isConfirmed: Bool, for item: PackageID) {
        if isConfirmed {
            confirmedItems.insert(item)
        } else {
            confirmedItems.remove(item)
        }
    }

    /// Items in the plan that MacUp will not run until the user says so.
    var itemsAwaitingConfirmation: [PlannedUpdate] {
        updatePlan?.needingConfirmation ?? []
    }

    /// What pressing Apply would actually change: the items policy allows
    /// outright, plus the ones the user has confirmed. The count is stated
    /// rather than implied, so a batch can never look larger than it is
    /// (CLAUDE.md §21).
    var itemsThatWouldRun: [PlannedUpdate] {
        (updatePlan?.planned ?? []).filter { !$0.needsConfirmation || confirmedItems.contains($0.item) }
    }

    private func makePlan(_ selection: Set<PackageID>?) async -> PlanReport? {
        guard !isPlanning, !isApplying else { return nil }
        isPlanning = true
        defer { isPlanning = false }
        planProblem = nil

        guard let report else {
            planProblem = "MacUp has not checked this Mac yet, so there is nothing to plan."
            return nil
        }
        let loaded = loadConfiguration()
        let plan = await environment.planner.plan(
            report,
            request: PlanRequest(selection: selection, intent: .interactive),
            configuration: loaded,
            environment: checkEnvironment(await loadEnvironment())
        )
        updatePlan = plan
        return plan
    }

    // MARK: - The exact command

    /// A one-item plan behind the "View command" affordance, so the exact
    /// executable and arguments can be read without opening a review.
    private(set) var commandPlan: PlanReport?
    private(set) var commandItem: PackageID?
    var isShowingCommand = false

    /// Plans one item and shows what MacUp would run — or, when there is
    /// nothing it would run, why not.
    func showCommand(for item: PackageID) async {
        guard !isPlanning, !isApplying, let report else { return }
        isPlanning = true
        defer { isPlanning = false }
        commandItem = item
        commandPlan = await environment.planner.plan(
            report,
            request: PlanRequest(selection: [item], intent: .interactive),
            configuration: loadConfiguration(),
            environment: checkEnvironment(await loadEnvironment())
        )
        isShowingCommand = true
    }

    func dismissCommand() {
        isShowingCommand = false
    }

    // MARK: - Applying a plan

    private(set) var isApplying = false
    /// The item whose command is running now.
    private(set) var runningItem: PackageID?
    /// Items whose commands have started, in the order they started, so the
    /// sheet can say "3 of 5" without claiming an outcome it does not have.
    private(set) var startedItems: [PackageID] = []
    /// When the running item's command started, so the sheet can say how
    /// long it has been going instead of leaving a still bar to guess at.
    private(set) var runningSince: Date?
    /// The running command's latest lines, redacted and display-safe. Not
    /// observed: the sheet reads it on a timer, so a noisy build cannot flood
    /// the main thread with redraws.
    let runningOutput = OutputLines(limit: 6)
    /// Stop was pressed: nothing further starts, and the running command is
    /// left to finish.
    private(set) var isStopRequested = false
    private(set) var executionReport: ExecutionReport?
    /// Why nothing was applied, when nothing was.
    private(set) var executionProblem: String?
    /// The running batch, so Cancel has something to cancel. Readable so a
    /// test can wait for it to finish unwinding.
    private(set) var applyTask: Task<Void, Never>?

    /// Runs the plan the user reviewed. Held as a task so it can be cancelled.
    func applyReviewedPlan() {
        guard applyTask == nil, let plan = updatePlan, !itemsThatWouldRun.isEmpty else { return }
        applyTask = Task { [weak self] in
            await self?.apply(plan)
            self?.applyTask = nil
        }
    }

    /// Stops a batch in progress after the item that is running. That item's
    /// command is left to finish — the runner never kills a command that is
    /// changing something, because a package manager stopped part-way can
    /// leave the item with no usable version — and nothing after it starts.
    func cancelApply() {
        guard applyTask != nil else { return }
        isStopRequested = true
        applyTask?.cancel()
    }

    private func apply(_ plan: PlanReport) async {
        guard !isApplying else { return }
        isApplying = true
        isStopRequested = false
        defer {
            isApplying = false
            runningItem = nil
            runningSince = nil
            isStopRequested = false
        }
        executionProblem = nil
        executionReport = nil
        startedItems = []

        let loaded = loadConfiguration()
        guard let paths = try? resolvedPaths() else {
            executionProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        let count = itemsThatWouldRun.count
        let approval = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(loaded.configuration, paths: paths)
        ).approve(count == 1 ? "apply one update on this Mac" : "apply \(count) updates on this Mac")
        guard approval.allowsChange else {
            executionProblem = approval.explanation
            return
        }

        var runEnvironment = checkEnvironment(await loadEnvironment())
        runEnvironment.runner = PlanProgressRunner(
            base: environment.runner,
            planned: plan.planned,
            output: runningOutput
        ) { [weak self] item in
            self?.noteRunning(item)
        }

        executionReport = await environment.makeExecutionEngine(paths).run(
            plan,
            configuration: loaded,
            options: ExecutionOptions(
                origin: .gui,
                intent: .interactive,
                confirmed: confirmedItems
            ),
            environment: runEnvironment
        )
        runningItem = nil
        loadHistory()
        // The versions on this Mac have moved, so what the Updates screen is
        // showing is now out of date. Checking again is read-only, and it runs
        // even after Stop: the screen must show what the stopped run left.
        await Task { await self.checkNow() }.value
    }

    #if DEBUG
    /// Snapshots only: puts the review sheet in the state it shows while
    /// `item` is running, and optionally after Stop, without running anything.
    func showRunningForSnapshot(_ item: PackageID, output: [String], since: Date, stopRequested: Bool) {
        isApplying = true
        runningItem = item
        runningSince = since
        startedItems = [item]
        isStopRequested = stopRequested
        runningOutput.reset()
        for line in output {
            runningOutput.append(CommandOutputChunk(stream: .standardOutput, data: Data((line + "\n").utf8)))
        }
    }

    /// Snapshots only: undoes ``showRunningForSnapshot(_:output:since:stopRequested:)``.
    func endRunningForSnapshot() {
        isApplying = false
        runningItem = nil
        runningSince = nil
        startedItems = []
        isStopRequested = false
        runningOutput.reset()
    }
    #endif

    private func noteRunning(_ item: PackageID) {
        runningItem = item
        runningSince = Date()
        runningOutput.reset()
        if !startedItems.contains(item) { startedItems.append(item) }
    }

    // MARK: - History

    /// What MacUp attempted, newest first, including what it could not read.
    private(set) var history: HistoryReading?
    /// Why the history could not be read, if it could not.
    private(set) var historyProblem: String?
    /// What the History screen is narrowed to: one item, and search text.
    /// See AppModel+History.swift.
    var historyFilter = HistoryFilter()

    /// Reads the history file, for the item the History screen is narrowed
    /// to when it is. Reading never creates or changes it.
    func loadHistory(limit: Int = 250) {
        historyProblem = nil
        guard let paths = try? resolvedPaths() else {
            historyProblem = "MacUp could not resolve where its files live, so it did not look for a history."
            return
        }
        do {
            history = try HistoryStore(paths: paths).read(limit: limit, filter: HistoryFilter(items: historyFilter.items))
        } catch let error as MacUpError {
            history = nil
            historyProblem = [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } catch {
            history = nil
            historyProblem = "MacUp could not read its history."
        }
    }

    // MARK: - Doctor

    private(set) var doctorReport: DoctorReport?
    private(set) var isDiagnosing = false
    private(set) var doctorProblem: String?

    /// The Export Diagnostics sheet while it is open, and `nil` otherwise.
    /// Opened and closed in AppModel+Diagnostics.swift.
    var diagnosticsExport: DiagnosticsExport?

    /// Runs MacUp's deterministic diagnostics. Every check reads; none fixes.
    func runDoctor() async {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        doctorProblem = nil

        let processEnvironment = await loadEnvironment()
        let loaded = loadConfiguration()
        guard let paths = try? resolvedPaths() else {
            doctorProblem = "MacUp could not resolve where its files live, so it could not check them."
            return
        }
        doctorReport = await environment.doctorEngine.run(
            configuration: loaded,
            environment: checkEnvironment(processEnvironment),
            paths: paths,
            schedule: scheduleStatus
        )
    }

    // MARK: - Approval

    var securitySettings: MacUpConfiguration.SecuritySettings {
        configuration?.configuration.security ?? MacUpConfiguration.SecuritySettings()
    }

    /// What this Mac can ask for. Reading it shows no prompt.
    var biometricCapability: BiometricCapability {
        ApprovalGate(settings: securitySettings, authorizer: authorizer).capability
    }

    /// Whether MacUp could get approval at all with the given settings. When it
    /// could not, requiring approval would stop MacUp changing anything.
    func canAskForApproval(with settings: MacUpConfiguration.SecuritySettings) -> Bool {
        let capability = ApprovalGate(settings: settings, authorizer: authorizer).capability
        return capability.isAvailable || (settings.allowPasswordFallback && capability.hasFallback)
    }

    private(set) var securityProblem: String?
    private(set) var faceEnrollment: FaceEnrollment?
    private(set) var isEnrollingFace = false
    /// The running enrolment, so it can be called off. Without a handle the
    /// sheet has no honest Cancel. Readable so a test can wait for an
    /// enrolment to finish unwinding instead of guessing how long that takes.
    private(set) var faceTask: Task<Void, Never>?
    /// Set apart from scheduling: enrolling a face must not appear to be
    /// changing the schedule, nor disable its switch.
    private(set) var isChangingSecurity = false
    /// The live camera session while enrolling, so the reader can see what
    /// the camera sees rather than watch a spinner.
    private(set) var faceCaptureSession: AVCaptureSession?
    /// What enrolment is doing right now, in words.
    private(set) var faceStage: String?
    /// What enrolling or reading the enrolment went wrong with, if anything.
    private(set) var faceProblem: String?

    /// What this build can expect from the camera, and why not, when the
    /// answer is no. Reading it opens nothing.
    var cameraReadiness: CameraReadiness { environment.faceCamera.readiness }

    /// The camera face match, when the configuration asks for it and the
    /// camera can actually be used. `nil` otherwise, so the camera is never
    /// opened for someone who did not turn it on, and approval is not delayed
    /// by a shortcut that cannot answer.
    func faceUnlock(_ configuration: MacUpConfiguration, paths: MacUpPaths) -> FaceUnlockService? {
        guard configuration.security.faceUnlock, cameraReadiness.canUse else { return nil }
        return FaceUnlockService(
            store: faceStore(paths),
            comparator: FaceComparator(threshold: Float(configuration.security.faceMatchThreshold))
        )
    }

    /// Reads the stored enrolment. Opens no camera and shows no prompt.
    func loadFaceEnrollment() {
        faceProblem = nil
        guard let paths = try? resolvedPaths() else { return }
        do {
            faceEnrollment = try faceStore(paths).load()
        } catch let error as MacUpError {
            faceEnrollment = nil
            faceProblem = error.message
        } catch {
            faceEnrollment = nil
        }
    }

    /// MacUp's own state directory holds the enrolment, and both reading and
    /// writing it go through the real file system, as the configuration does.
    /// Tests isolate it by pointing the home directory somewhere throwaway.
    private func faceStore(_ paths: MacUpPaths) -> FaceEnrollmentStore {
        FaceEnrollmentStore(paths: paths)
    }

    /// Starts enrolling. Held as a task so the sheet's Cancel can stop it.
    ///
    /// A camera MacUp cannot use is said so here rather than after a sheet has
    /// opened and waited: there is nothing to wait for.
    func startFaceEnrollment() {
        guard faceTask == nil else { return }
        if let problem = cameraReadiness.problem {
            faceProblem = problem
            return
        }
        faceTask = Task { [weak self] in
            await self?.enrollFace()
            self?.faceTask = nil
        }
    }

    /// Stops an enrolment in progress. The camera closes with it.
    func cancelFaceEnrollment() {
        faceTask?.cancel()
        faceTask = nil
        isEnrollingFace = false
        faceStage = nil
        faceCaptureSession = nil
    }

    /// Takes a few pictures and remembers what they look like. Replacing an
    /// enrolment is a change, so it goes through the same gate.
    private func enrollFace() async {
        guard !isEnrollingFace else { return }
        isEnrollingFace = true
        defer { isEnrollingFace = false }
        faceProblem = nil

        let loaded = loadConfiguration()
        guard !loaded.hasErrors, let paths = try? resolvedPaths() else {
            faceProblem = "MacUp will not change a configuration it cannot read."
            return
        }
        let approval = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(loaded.configuration, paths: paths)
        ).approve("enroll a face on this Mac")
        guard approval.allowsChange else {
            faceProblem = approval.explanation
            return
        }

        defer {
            faceCaptureSession = nil
            faceStage = nil
        }
        do {
            faceEnrollment = try await environment.faceCamera.enroll(
                into: faceStore(paths),
                threshold: loaded.configuration.security.faceMatchThreshold,
                stage: { [weak self] stage in self?.faceStage = stage },
                preview: { [weak self] session in self?.faceCaptureSession = session }
            )

            var configuration = loaded.configuration
            configuration.security.faceUnlock = true
            try ConfigurationStore(paths: paths).save(configuration)
            self.configuration = loadConfiguration()
        } catch let error as MacUpError {
            faceProblem = [error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        } catch is CancellationError {
            faceProblem = nil
        } catch {
            faceProblem = "MacUp could not enroll a face."
        }
    }

    /// Deletes the enrolment and turns the camera check off.
    func forgetFace() {
        faceProblem = nil
        guard let paths = try? resolvedPaths() else { return }
        do {
            try faceStore(paths).remove()
            faceEnrollment = nil
            let loaded = loadConfiguration()
            if !loaded.hasErrors && loaded.configuration.security.faceUnlock {
                var configuration = loaded.configuration
                configuration.security.faceUnlock = false
                try ConfigurationStore(paths: paths).save(configuration)
                self.configuration = loadConfiguration()
            }
        } catch let error as MacUpError {
            faceProblem = error.message
        } catch {
            faceProblem = "The enrolled face could not be deleted."
        }
    }

    /// Turns the approval requirement on or off. Changing it is itself a
    /// change, so it goes through the gate that is in force now.
    func applySecurity(_ settings: MacUpConfiguration.SecuritySettings) async {
        guard !isChangingSecurity else { return }
        isChangingSecurity = true
        defer { isChangingSecurity = false }
        securityProblem = nil

        let loaded = loadConfiguration()
        guard !loaded.hasErrors else {
            securityProblem = "MacUp will not change a configuration it cannot read. Fix the errors above first."
            return
        }
        let approval = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: (try? resolvedPaths()).flatMap { faceUnlock(loaded.configuration, paths: $0) }
        ).approve("change when MacUp asks for your approval")
        guard approval.allowsChange else {
            securityProblem = approval.explanation
            return
        }
        guard !settings.requireApproval || canAskForApproval(with: settings) else {
            securityProblem = "This Mac cannot ask you to confirm right now, so requiring approval would stop MacUp changing anything."
            return
        }
        guard let paths = try? resolvedPaths() else {
            securityProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        var configuration = loaded.configuration
        configuration.security = settings
        do {
            try ConfigurationStore(paths: paths).save(configuration)
            self.configuration = loadConfiguration()
        } catch let error as MacUpError {
            securityProblem = error.message
        } catch {
            securityProblem = "The setting could not be saved."
        }
    }

    // MARK: - Scheduling

    var scheduleSettings: MacUpConfiguration.ScheduleSettings {
        configuration?.configuration.schedule ?? MacUpConfiguration.ScheduleSettings()
    }

    /// Asks launchd and the file system what is scheduled. Changes nothing.
    func refreshScheduleStatus() async {
        let loaded = configuration ?? loadConfiguration()
        guard let paths = try? resolvedPaths(), let executable = scheduledExecutable() else {
            scheduleStatus = nil
            return
        }
        scheduleStatus = await scheduler(paths: paths, executable: executable).status(loaded.configuration.schedule)
    }

    /// Installs or removes the scheduled check and records it in the
    /// configuration. The same rules as the CLI: MacUp will not write a
    /// configuration it could not read, and will not schedule a command it
    /// cannot name.
    func applySchedule(_ settings: MacUpConfiguration.ScheduleSettings) async {
        guard !isChangingSchedule else { return }
        isChangingSchedule = true
        defer { isChangingSchedule = false }
        scheduleProblem = nil

        let loaded = loadConfiguration()
        guard !loaded.hasErrors else {
            scheduleProblem = "MacUp will not change a configuration it cannot read. Fix the errors above first."
            return
        }
        guard let paths = try? resolvedPaths() else {
            scheduleProblem = "MacUp could not resolve where its files live, so it changed nothing."
            return
        }
        guard let executable = scheduledExecutable() else {
            scheduleProblem = "MacUp could not find the macup command to schedule. Install the command-line tool, then try again."
            return
        }

        let approval = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(loaded.configuration, paths: paths)
        ).approve("change MacUp's scheduled check")
        guard approval.allowsChange else {
            scheduleProblem = approval.explanation
            return
        }

        let scheduler = scheduler(paths: paths, executable: executable)
        do {
            if settings.enabled {
                _ = try await scheduler.install(settings)
            } else {
                _ = try await scheduler.remove()
            }
            var configuration = loaded.configuration
            configuration.schedule = settings
            try ConfigurationStore(paths: paths).save(configuration)
            self.configuration = loadConfiguration()
        } catch let error as MacUpError {
            scheduleProblem = error.message
        } catch {
            scheduleProblem = "The schedule could not be changed."
        }
        await refreshScheduleStatus()
    }

    /// The `macup` command a scheduled check runs. The copy inside the app
    /// bundle comes first: it is always present and always the same version as
    /// the app, so a schedule cannot end up running an older CLI. Otherwise
    /// MacUp looks for an installed `macup` on the user's search path.
    func scheduledExecutable() -> String? {
        if let bundled = environment.bundledExecutablePath,
           environment.fileSystem.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let path = shellEnvironment?["PATH"] ?? environment.processEnvironment["PATH"]
        let search = ExecutableSearch(name: "macup", searchPath: SearchPath.parse(path))
        if case .found(let resolved) = ExecutableResolver(fileSystem: environment.fileSystem).resolve(search) {
            return resolved.path
        }
        return nil
    }

    func scheduler(paths: MacUpPaths, executable: String) -> Scheduler {
        Scheduler(
            paths: paths,
            executable: executable,
            fileSystem: environment.fileSystem,
            runner: environment.runner,
            processEnvironment: shellEnvironment ?? environment.processEnvironment
        )
    }

    func resolvedPaths() throws -> MacUpPaths {
        try MacUpPaths.resolve(homeDirectory: home, environment: environment.processEnvironment)
    }

    /// Reads the configuration file. Reading never creates or changes it.
    @discardableResult
    func loadConfiguration() -> LoadedConfiguration {
        let paths: MacUpPaths
        var pathProblem: ConfigurationIssue?
        do {
            paths = try resolvedPaths()
        } catch {
            // Match the CLI's refusal visibly: say why the default location is in use.
            let message = (error as? MacUpError)?.message ?? "The configuration location could not be resolved."
            pathProblem = ConfigurationIssue(.error, "", message + " MacUp is using the default location instead.")
            paths = MacUpPaths.standard(homeDirectory: home)
        }
        var loaded = ConfigurationStore(paths: paths).load()
        if let pathProblem { loaded.issues.insert(pathProblem, at: 0) }
        configuration = loaded
        return loaded
    }

    /// The environment of the user's login shell, read once per launch. An
    /// app started from Finder does not inherit it, and without it MacUp would
    /// miss tools installed outside the standard locations. A failed read is
    /// retried on the next check rather than cached.
    func loadEnvironment() async -> [String: String] {
        if let shellEnvironment { return shellEnvironment }
        let shell = environment.loginShell.shell()
        self.shell = shell
        var result = environment.processEnvironment
        do {
            result = try await environment.loginShell.environment(from: shell)
            environmentProblem = nil
            shellEnvironment = result
        } catch let error as MacUpError {
            environmentProblem = error.message
        } catch {
            environmentProblem = "MacUp could not read your shell's environment."
        }
        return result
    }
}
