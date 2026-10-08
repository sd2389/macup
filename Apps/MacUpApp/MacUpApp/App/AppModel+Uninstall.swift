import AppKit
import Foundation
import MacUpCore
import Observation

/// The Uninstall screen's state: what is installed, the plan under review,
/// what is ticked in it, how the files go, and what the last uninstall did.
///
/// How the files go is asked every time a review opens and starts at the
/// Trash, so a permanent deletion can only happen when someone chose it for
/// this uninstall.
@MainActor
@Observable
final class UninstallState {
    fileprivate(set) var catalog: UninstallCatalog?
    fileprivate(set) var isScanning = false
    fileprivate(set) var plan: UninstallPlan?
    fileprivate(set) var selection: UninstallSelection?
    /// Move to Trash or Delete Permanently, chosen at the top of the sheet.
    var mode: RemovalMode = .trash
    var isReviewing = false
    fileprivate(set) var isPlanning = false
    fileprivate(set) var isRunning = false
    /// What the running uninstall is doing now, in words.
    fileprivate(set) var progressLine: String?
    fileprivate(set) var report: UninstallReport?
    /// Why nothing was removed, when nothing was: approval refused, or MacUp
    /// could not find its own files.
    fileprivate(set) var problem: String?
    fileprivate(set) var task: Task<Void, Never>?
    var search = ""
    /// The script MacUp wrote for the administrator-only part, once asked
    /// for. MacUp writes it and shows it; the person runs it.
    fileprivate(set) var adminScript: AdminRemovalScript?
    /// Why that script could not be written, when it could not.
    fileprivate(set) var adminScriptProblem: String?
    /// Whether the script's text is on screen.
    var isReadingAdminScript = false
}

extension AppModel {
    /// Writes the administrator-only part of the reviewed plan as a script
    /// the person can read and then run with `sudo`.
    ///
    /// MacUp stays out of it after that: it does not run the script, make it
    /// executable, or ask for a password (docs/TRUST_AND_SECURITY.md,
    /// "Privilege"). The only thing written is MacUp's own file, which is why
    /// this needs no approval of its own — nothing on the Mac changes.
    func writeAdminScript() {
        uninstaller.adminScript = nil
        uninstaller.adminScriptProblem = nil
        guard let plan = uninstaller.plan else { return }
        guard plan.cannotRemove.contains(where: { !$0.commands.isEmpty }) else {
            uninstaller.adminScriptProblem = "Nothing here has an exact command MacUp can write down, so the steps above are the only way."
            return
        }
        do {
            let paths = try resolvedPaths()
            uninstaller.adminScript = try AdminRemovalScriptWriter.write(plan, paths: paths)
        } catch {
            uninstaller.adminScriptProblem = (error as? MacUpError)?.message
                ?? "MacUp could not write the script, so there is nothing to run."
        }
    }

    /// Puts the command on the clipboard. The password is typed into the
    /// terminal, never into MacUp.
    func copyAdminScriptCommand() {
        guard let command = uninstaller.adminScript?.command else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Opens Terminal, with the command already copied, so the person pastes
    /// it and `sudo` asks them for their password. MacUp runs nothing.
    func openTerminalForAdminScript() {
        copyAdminScriptCommand()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Shows the script in Finder, so it can be opened in any editor first.
    func revealAdminScript() {
        guard let path = uninstaller.adminScript?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// This Mac, or the pretend one a test gives.
    var uninstallEnvironment: UninstallEnvironment {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil
        return environment.uninstall ?? .live(homeDirectory: environment.homeDirectory, currentAppBundle: bundle)
    }

    /// Reads what is installed, and what apps that are gone left behind.
    /// Reads only: it runs the same read-only listings a check does and looks
    /// at files; it changes nothing.
    func scanUninstallable() async {
        guard !uninstaller.isScanning else { return }
        uninstaller.isScanning = true
        defer { uninstaller.isScanning = false }
        let configuration = loadConfiguration()
        let environment = checkEnvironment(await loadEnvironment())
        uninstaller.catalog = await UninstallScanner().catalog(
            configuration: configuration,
            environment: environment,
            uninstall: uninstallEnvironment,
            measureApps: false,
            includeOrphans: true
        )
    }

    /// What apps that are no longer installed left in `~/Library`, biggest
    /// group first.
    var orphanedLeftovers: [OrphanedLeftovers] { uninstaller.catalog?.orphans ?? [] }

    /// Opens the review for one group of leftovers. Nothing in it is ticked.
    func reviewLeftovers(_ group: OrphanedLeftovers) async {
        await reviewUninstall(.leftovers(group))
    }

    /// Works out what uninstalling `target` would remove and opens the review.
    /// Building a plan removes nothing.
    func reviewUninstall(_ target: UninstallTarget) async {
        guard !uninstaller.isRunning, !uninstaller.isPlanning else { return }
        uninstaller.mode = .trash
        uninstaller.report = nil
        uninstaller.problem = nil
        uninstaller.plan = nil
        uninstaller.selection = nil
        uninstaller.isReviewing = true
        uninstaller.isPlanning = true
        defer { uninstaller.isPlanning = false }
        if uninstaller.catalog == nil { await scanUninstallable() }
        guard let catalog = uninstaller.catalog, let paths = try? resolvedPaths() else {
            uninstaller.problem = "MacUp could not look at what is installed, so it has nothing to remove."
            return
        }
        let plan = await UninstallPlanner().plan(
            target,
            catalog: catalog,
            configuration: loadConfiguration(),
            environment: checkEnvironment(await loadEnvironment()),
            uninstall: uninstallEnvironment,
            paths: paths
        )
        uninstaller.plan = plan
        uninstaller.selection = UninstallSelection(plan)
    }

    /// The review for removing MacUp itself.
    func reviewSelfUninstall() async {
        await reviewUninstall(.macUp)
    }

    func isIncludedInUninstall(_ path: String) -> Bool {
        uninstaller.selection?.contains(path) ?? false
    }

    func setIncludedInUninstall(_ included: Bool, path: String) {
        guard let plan = uninstaller.plan, var selection = uninstaller.selection, !uninstaller.isRunning else { return }
        selection.set(included, path, in: plan)
        uninstaller.selection = selection
    }

    /// Ticks everything MacUp can remove: the no-residue choice.
    func selectEverythingForUninstall() {
        guard let plan = uninstaller.plan, var selection = uninstaller.selection, !uninstaller.isRunning else { return }
        selection.includeEverything(from: plan)
        uninstaller.selection = selection
    }

    /// Back to what the plan ticks on its own: nothing that is anyone's data.
    func selectDefaultsForUninstall() {
        guard let plan = uninstaller.plan, !uninstaller.isRunning else { return }
        uninstaller.selection = UninstallSelection(plan)
    }

    var uninstallTotals: UninstallTotals? {
        guard let plan = uninstaller.plan, let selection = uninstaller.selection else { return nil }
        return plan.totals(for: selection.paths)
    }

    /// Runs the reviewed plan with what is ticked and the mode chosen. Held as
    /// a task, so the sheet can stop it between removals.
    func runUninstall() {
        guard uninstaller.task == nil, let plan = uninstaller.plan, plan.canRun,
              let selection = uninstaller.selection else { return }
        let mode = uninstaller.mode
        uninstaller.task = Task { [weak self] in
            await self?.performUninstall(plan, selection: selection.paths, mode: mode)
            self?.uninstaller.task = nil
        }
    }

    /// Stops before the next removal. What already went is reported.
    func stopUninstall() {
        uninstaller.task?.cancel()
    }

    func endUninstallReview() {
        guard !uninstaller.isRunning else { return }
        uninstaller.isReviewing = false
        uninstaller.plan = nil
        uninstaller.selection = nil
        uninstaller.report = nil
        uninstaller.problem = nil
        uninstaller.mode = .trash
    }

    private func performUninstall(_ plan: UninstallPlan, selection: Set<String>, mode: RemovalMode) async {
        uninstaller.isRunning = true
        uninstaller.problem = nil
        defer {
            uninstaller.isRunning = false
            uninstaller.progressLine = nil
        }
        let loaded = loadConfiguration()
        guard let paths = try? resolvedPaths() else {
            uninstaller.problem = "MacUp could not resolve where its files live, so it removed nothing."
            return
        }
        let approval = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(loaded.configuration, paths: paths)
        ).approve("uninstall \(plan.subject.name) from this Mac")
        guard approval.allowsChange else {
            uninstaller.problem = approval.explanation ?? "The change was not approved, so nothing was removed."
            return
        }

        let environment = checkEnvironment(await loadEnvironment())
        let scheduler = scheduler(paths: paths, executable: scheduledExecutable() ?? "macup")
        let report = await UninstallEngine.standard(paths: paths).run(
            plan,
            selection: selection,
            mode: mode,
            options: UninstallOptions(origin: .gui),
            configuration: loaded,
            environment: environment,
            uninstall: uninstallEnvironment,
            scheduler: scheduler
        ) { [weak self] progress in
            let line = Self.describe(progress)
            Task { @MainActor in self?.uninstaller.progressLine = line }
        }
        uninstaller.report = report
        loadHistory()
        // What is installed has changed, so both lists are read again — even
        // after Stop, because the screens must show what a stopped run left.
        if plan.subject.kind != .macUp {
            await Task { await self.scanUninstallable() }.value
            await Task { await self.checkNow() }.value
        }
    }

    nonisolated static func describe(_ progress: UninstallProgress) -> String {
        switch progress {
        case .runningCommand(let command): "Running \(TerminalText.sanitize(command))"
        case .running(let action): TerminalText.sanitize(action.summary)
        case .removing(let path, let index, let total): "Removing \(index) of \(total): \(TerminalText.sanitize((path as NSString).lastPathComponent))"
        case .checking: "Checking what is left…"
        }
    }
}
