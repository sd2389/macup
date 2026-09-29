import Foundation

/// The plan for uninstalling MacUp itself: `macup self-uninstall`, and
/// Uninstall MacUp in Settings.
///
/// Everything MacUp put on this Mac, and nothing else:
///
/// - its scheduled check, removed the way `macup schedule disable` removes it;
/// - a Keychain item an earlier version saved, if there is one;
/// - copies of the `macup` command it knows the places of, or Homebrew's
///   `brew uninstall` when Homebrew installed it;
/// - its configuration and its state folder (history, logs, a face
///   enrollment);
/// - what macOS keeps for `dev.macup.MacUp` in `~/Library`;
/// - the MacUp app, last.
///
/// The state folder goes after the uninstall is recorded, so the record is
/// made while there is a history to keep it in; in Trash mode it is in the
/// Trash with the rest.
struct SelfUninstallPlanner: Sendable {
    var uninstall: UninstallEnvironment
    var paths: MacUpPaths
    var homebrew = HomebrewProvider()

    func plan(catalog: UninstallCatalog, environment: CheckEnvironment) async -> UninstallPlan {
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: .macUp,
                target: "macup",
                name: "MacUp",
                version: MacUp.version,
                bundleIdentifier: MacUpSelf.bundleIdentifier,
                source: "MacUp"
            ),
            rationale: "MacUp removes everything it put on this Mac: its scheduled check, its command-line tool, its "
                + "configuration and history, what macOS keeps for it in your Library, and the app, last. Nothing it "
                + "manages for you — your apps and packages — is touched."
        )
        let prefix = catalog.installations[.homebrew]?.fact("prefix")
        plan.homebrewPrefix = prefix
        let boundary = uninstall.boundary(homebrewPrefix: prefix, forMacUp: true)

        let agent = paths.launchAgentsDirectory + "/" + LaunchAgent.fileName
        if FileTree.exists(agent) {
            plan.actions.append(SelfUninstallAction(
                kind: .removeScheduledCheck,
                summary: "Turn off the scheduled check, as `macup schedule disable` does",
                detail: CommandInvocation(executable: Scheduler.launchctlPath, arguments: ["bootout", "gui/\(uninstall.userID)/\(LaunchAgent.label)"]).displayString
                    + ", then remove " + PathDisplay.abbreviatingHome(agent, homeDirectory: uninstall.homeDirectory)
            ))
        }
        if uninstall.keychain.hasLeftoverItem() {
            plan.actions.append(SelfUninstallAction(
                kind: .deleteKeychainItem,
                summary: "Delete the Keychain item an earlier MacUp saved",
                detail: "Generic password, service \(SystemMacUpKeychainItems.service), in your login keychain"
            ))
        }

        // Installed with Homebrew: Homebrew removes its own copy.
        let formula = catalog.formulae.first { ($0.id.name.split(separator: "/").last.map(String.init) ?? $0.id.name) == "macup" }
        if let formula, let installation = catalog.installations[.homebrew] {
            do {
                plan.steps = try homebrew.uninstallSteps(formula: formula, installation: installation)
                plan.stepsProvider = .homebrew
            } catch {
                plan.blockers.append(UninstallBlocker(.unsupported, MacUpError.wrapping(error, context: "Planning").message))
            }
        }

        var leftovers: [Leftover] = []
        for location in uninstall.macUpCommandLocations {
            guard let status = FileTree.status(location), status.kind == .file || status.kind == .symlink else { continue }
            if formula != nil, let prefix, let target = FileTree.canonicalPath(location),
               FileTree.isInside(target, (FileTree.canonicalPath(prefix) ?? prefix) + "/Cellar") {
                continue
            }
            let parent = (location as NSString).deletingLastPathComponent
            guard FileTree.isWritable(parent) else {
                plan.cannotRemove.append(ManualRemoval(
                    path: location,
                    reason: "A copy of the macup command in a folder only an administrator can change.",
                    steps: ["In Terminal, run: sudo rm \(CommandInvocation.quoted(location))"]
                ))
                continue
            }
            leftovers.append(Leftover(path: location, category: .macUp, selectedByDefault: true, reason: "A copy of the macup command."))
        }
        if FileTree.exists(paths.configDirectory) {
            leftovers.append(Leftover(
                path: paths.configDirectory,
                category: .macUp,
                selectedByDefault: true,
                reason: "MacUp's configuration: your update rules and settings."
            ))
        }
        let library = AppLeftoverScanner(homeDirectory: uninstall.homeDirectory, otherBundleIdentifiers: [])
            .scan(bundleIdentifier: MacUpSelf.bundleIdentifier, bundlePath: uninstall.currentAppBundle ?? "/nonexistent", names: [], teamIdentifier: nil)
        leftovers += library.map { Leftover(path: $0.path, category: .macUp, selectedByDefault: true, reason: $0.reason) }
        UninstallPlanner.add(leftovers, to: &plan, boundary: boundary, owner: "MacUp")

        if let state = FileTree.status(paths.stateDirectory), state.kind == .directory {
            let size = FileTree.size(of: paths.stateDirectory)
            if boundary.refusal(for: FileTree.canonicalLocation(paths.stateDirectory) ?? paths.stateDirectory) == nil {
                plan.removals.append(PlannedRemoval(
                    path: paths.stateDirectory,
                    category: .macUp,
                    kind: .directory,
                    sizeBytes: size?.bytes,
                    sizeIsPartial: size?.partial ?? true,
                    selectedByDefault: true,
                    role: .macUpState,
                    reason: "MacUp's history, logs, and saved state, including a face enrollment if you made one.",
                    identity: state.identity
                ))
            }
        }

        var bundles = catalog.apps.filter { $0.bundleIdentifier == MacUpSelf.bundleIdentifier }
        if let current = uninstall.currentAppBundle, !bundles.contains(where: { $0.path == current }),
           let app = AppScanner(applicationDirectories: []).app(at: current, measure: true) {
            bundles.append(app)
        }
        for app in bundles {
            guard app.removability.isRemovable, boundary.refusal(for: FileTree.canonicalLocation(app.path) ?? app.path) == nil else {
                plan.cannotRemove.append(ManualRemoval(
                    path: app.path,
                    reason: app.removability.reason ?? "MacUp cannot remove this copy of itself.",
                    steps: app.removability.steps.isEmpty ? ["In Finder, drag it to the Trash."] : app.removability.steps,
                    sizeBytes: app.sizeBytes
                ))
                continue
            }
            let isCurrent = app.path == uninstall.currentAppBundle
            if !isCurrent,
               !(await uninstall.runningApplications.running(bundleIdentifier: nil, bundlePath: app.path)).isEmpty {
                plan.blockers.append(UninstallBlocker(
                    .appRunning,
                    "Quit the MacUp app first.",
                    steps: ["The MacUp app at \(PathDisplay.abbreviatingHome(app.path, homeDirectory: uninstall.homeDirectory)) is open. Quit it, then try again."]
                ))
            }
            plan.removals.append(PlannedRemoval(
                path: app.path,
                category: .macUp,
                kind: .directory,
                sizeBytes: app.sizeBytes,
                sizeIsPartial: app.sizeIsPartial,
                selectedByDefault: true,
                role: .bundle,
                reason: isCurrent ? "This MacUp app. Removed last; the app quits afterwards." : "The MacUp app.",
                identity: app.identity
            ))
        }
        // The app goes last of all, after the state folder, so whatever else
        // fails, the app that can say so is still there.
        plan.removals.sort { Self.order($0.role) < Self.order($1.role) }
        plan.verification = [VerificationStep(summary: "Check that each item you ticked is gone and no scheduled check is left.")]
        return plan
    }

    static func order(_ role: PlannedRemoval.Role) -> Int {
        switch role {
        case .item: 0
        case .macUpState: 1
        case .bundle: 2
        }
    }
}
