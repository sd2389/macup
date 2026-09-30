import Foundation

/// Builds the plan for uninstalling one thing. Runs nothing that changes
/// anything: the only commands are the read-only lookups of
/// ``UninstallScanner``, and the only file-system calls are reads.
///
/// Every refusal is a blocker in the plan rather than an error, so the plan
/// is still shown in full — what would run, what would go, what would stay —
/// and says exactly what stands in the way (CLAUDE.md §1: conservative with
/// changes, aggressive with information).
public struct UninstallPlanner: Sendable {
    public var scanner: UninstallScanner

    public init(scanner: UninstallScanner = UninstallScanner()) {
        self.scanner = scanner
    }

    public func plan(
        _ target: UninstallTarget,
        catalog: UninstallCatalog,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        uninstall: UninstallEnvironment,
        paths: MacUpPaths
    ) async -> UninstallPlan {
        var plan: UninstallPlan
        switch target {
        case .app(let app):
            if app.source.kind == .homebrewCask, let token = app.source.caskToken,
               let cask = catalog.casks.first(where: { $0.token == token }) {
                plan = await planCask(cask, catalog: catalog, uninstall: uninstall, environment: environment)
            } else {
                plan = await planApp(app, catalog: catalog, uninstall: uninstall, environment: environment)
            }
        case .package(let package):
            switch package.kind {
            case .formula:
                plan = await planFormula(package, catalog: catalog, configuration: configuration, uninstall: uninstall, environment: environment)
            case .cask:
                if let cask = catalog.casks.first(where: { $0.id == package.packageID }) {
                    plan = await planCask(cask, catalog: catalog, uninstall: uninstall, environment: environment)
                } else {
                    plan = Self.missing(package, environment: environment)
                }
            case .npmPackage:
                plan = planNpm(package, catalog: catalog, environment: environment)
            case .miseRuntime:
                plan = planMise(package, catalog: catalog, uninstall: uninstall, environment: environment)
            case .app, .macUp:
                plan = Self.missing(package, environment: environment)
            }
        case .macUp:
            plan = await SelfUninstallPlanner(uninstall: uninstall, paths: paths, homebrew: scanner.homebrew).plan(catalog: catalog, environment: environment)
        }
        if configuration.hasErrors {
            plan.blockers.insert(UninstallBlocker(
                .configurationInvalid,
                "MacUp will not change anything while it cannot read its configuration.",
                steps: ["Fix what `macup config show` lists, then try again."]
            ), at: 0)
        }
        if let provider = plan.subject.provider, !plan.steps.isEmpty,
           !configuration.configuration.settings(for: provider).enabled {
            plan.blockers.append(UninstallBlocker(
                .providerOff,
                "\(provider.displayName) is turned off in MacUp's configuration, so MacUp will not run it.",
                steps: ["`macup provider enable \(provider.rawValue)` turns it back on."]
            ))
        }
        return plan
    }

    // MARK: Apps

    private func planApp(
        _ app: InstalledApp,
        catalog: UninstallCatalog,
        uninstall: UninstallEnvironment,
        environment: CheckEnvironment
    ) async -> UninstallPlan {
        let subject = UninstallSubject(
            kind: .app,
            target: app.target,
            name: app.name,
            version: app.version,
            bundleIdentifier: app.bundleIdentifier,
            bundlePath: app.path,
            source: app.source.displayName
        )
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: subject,
            rationale: "MacUp removes \(app.name) itself: no package manager installed it. You choose whether it and "
                + "what it left go to the Trash or are deleted permanently, and nothing you leave unticked is touched."
        )
        let boundary = uninstall.boundary(homebrewPrefix: nil, forMacUp: false)
        plan.blockers += Self.appBlockers(app)
        if let state = catalog.state(of: .homebrew), state.state == .off || state.state == .failed {
            plan.blockers.append(UninstallBlocker(
                .ownershipUnknown,
                "MacUp could not ask Homebrew whether it installed \(app.name), so it cannot tell who should remove it.",
                steps: state.state == .off
                    ? ["`macup provider enable homebrew` lets MacUp check, or remove \(app.name) yourself in Finder."]
                    : ["Check `macup provider list`, or remove \(app.name) yourself in Finder."]
            ))
        }
        if app.removability.isRemovable {
            var bundle = PlannedRemoval(
                path: app.path,
                category: .application,
                kind: .directory,
                sizeBytes: app.sizeBytes,
                sizeIsPartial: app.sizeIsPartial,
                selectedByDefault: true,
                isRequired: true,
                role: .bundle,
                reason: app.source.kind == .appStore ? "The app itself, from the Mac App Store." : "The app itself.",
                identity: app.identity
            )
            if bundle.sizeBytes == nil, let size = FileTree.size(of: app.path) {
                bundle.sizeBytes = size.bytes
                bundle.sizeIsPartial = size.partial || size.unreadable > 0
            }
            plan.removals.append(bundle)
        }
        await addLeftovers(of: app, to: &plan, catalog: catalog, uninstall: uninstall, boundary: boundary)
        plan.blockers += await running(app, uninstall: uninstall)
        plan.verification = [VerificationStep(summary: "Check that \(app.name) and each item you ticked are gone.")]
        return plan
    }

    static func appBlockers(_ app: InstalledApp) -> [UninstallBlocker] {
        switch app.removability.kind {
        case .removable:
            return []
        case .protectedBySystem:
            return [UninstallBlocker(.protectedBySystem, app.removability.reason ?? "macOS protects \(app.name).")]
        case .needsAdministrator:
            return [UninstallBlocker(
                .needsAdministrator,
                app.removability.reason ?? "Removing \(app.name) needs an administrator.",
                steps: app.removability.steps
            )]
        case .notSupported:
            return [UninstallBlocker(
                .unsupported,
                app.removability.reason ?? "MacUp does not remove \(app.name).",
                steps: app.removability.steps
            )]
        }
    }

    /// The app's leftovers in the home folder's Library, and what it left
    /// where only an administrator can remove it.
    private func addLeftovers(
        of app: InstalledApp,
        to plan: inout UninstallPlan,
        catalog: UninstallCatalog,
        uninstall: UninstallEnvironment,
        boundary: RemovalBoundary
    ) async {
        let others = Set(catalog.apps.filter { $0.path != app.path }.compactMap(\.bundleIdentifier))
            .union([MacUpSelf.bundleIdentifier])
            .subtracting(app.bundleIdentifier.map { [$0] } ?? [])
        let team = app.bundleIdentifier == nil ? nil : uninstall.signatures.teamIdentifier(ofBundleAt: app.path)
        let leftovers = AppLeftoverScanner(homeDirectory: uninstall.homeDirectory, otherBundleIdentifiers: others)
            .scan(bundleIdentifier: app.bundleIdentifier, bundlePath: app.path, names: app.names, teamIdentifier: team)
        Self.add(leftovers, to: &plan, boundary: boundary, owner: app.name)
        let system = SystemLeftoverScanner(
            systemLibrary: uninstall.systemLibrary,
            receiptsDirectory: uninstall.receiptsDirectory,
            otherBundleIdentifiers: others,
            userID: uninstall.userID
        )
        for manual in system.scan(bundleIdentifier: app.bundleIdentifier, bundlePath: app.path)
        where !plan.cannotRemove.contains(where: { $0.path == manual.path }) {
            var manual = manual
            manual.sizeBytes = FileTree.size(of: manual.path)?.bytes
            plan.cannotRemove.append(manual)
        }
    }

    /// Measures each leftover and checks it against the boundary: what
    /// passes becomes a removal, what does not is listed with the reason and
    /// what to do by hand. Nothing is dropped silently.
    static func add(_ leftovers: [Leftover], to plan: inout UninstallPlan, boundary: RemovalBoundary, owner: String) {
        for leftover in leftovers where !plan.removals.contains(where: { $0.path == leftover.path }) {
            guard let status = FileTree.status(leftover.path) else { continue }
            let location = FileTree.canonicalLocation(leftover.path) ?? leftover.path
            if let refusal = boundary.refusal(for: location) {
                plan.cannotRemove.append(ManualRemoval(
                    path: leftover.path,
                    reason: "MacUp does not remove it because \(refusal).",
                    steps: ["If you are sure it belongs to \(owner), remove it yourself in Finder."],
                    sizeBytes: FileTree.size(of: leftover.path)?.bytes
                ))
                continue
            }
            let size = FileTree.size(of: leftover.path)
            if let size, size.locked > 0 {
                plan.cannotRemove.append(ManualRemoval(
                    path: leftover.path,
                    reason: "Some of it belongs to another user or is locked. " + SystemLeftoverScanner.administratorReason,
                    steps: ["In Finder, move it to the Trash, and enter an administrator's password when macOS asks."],
                    sizeBytes: size.bytes
                ))
                continue
            }
            plan.removals.append(PlannedRemoval(
                path: leftover.path,
                category: leftover.category,
                kind: status.kind,
                sizeBytes: size?.bytes,
                sizeIsPartial: (size?.partial ?? true) || (size?.unreadable ?? 0) > 0,
                selectedByDefault: leftover.selectedByDefault,
                reason: leftover.reason,
                warning: leftover.warning,
                identity: status.identity
            ))
        }
    }

    /// "Quit ChatGPT first", when it is open.
    func running(_ app: InstalledApp, uninstall: UninstallEnvironment) async -> [UninstallBlocker] {
        let open = await uninstall.runningApplications.running(bundleIdentifier: app.bundleIdentifier, bundlePath: app.path)
        guard !open.isEmpty else { return [] }
        return [UninstallBlocker(
            .appRunning,
            "Quit \(app.name) first.",
            steps: ["\(app.name) is open. Quit it, then try again; MacUp checks again before it removes anything."]
        )]
    }

    // MARK: Homebrew

    private func planCask(
        _ cask: HomebrewCask,
        catalog: UninstallCatalog,
        uninstall: UninstallEnvironment,
        environment: CheckEnvironment
    ) async -> UninstallPlan {
        let app = cask.appPaths.lazy.compactMap { path in catalog.apps.first { $0.path == path } }.first
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: .cask,
                target: cask.id.rawValue,
                packageID: cask.id,
                name: app?.name ?? cask.name,
                version: cask.installedVersion,
                bundleIdentifier: app?.bundleIdentifier,
                bundlePath: app?.path,
                source: "Homebrew cask"
            ),
            rationale: "Homebrew uninstalls the cask \(cask.token)"
                + (app.map { " and removes \($0.name)" } ?? "")
                + ". MacUp never passes --zap: it removes what the cask lists for a complete removal itself, so only "
                + "what you tick goes, in the way you choose."
        )
        guard let installation = catalog.installations[.homebrew] else {
            plan.blockers.append(UninstallBlocker(.providerUnavailable, "MacUp could not find the Homebrew installation to run."))
            return plan
        }
        plan.homebrewPrefix = installation.fact("prefix")
        do {
            plan.steps = try scanner.homebrew.uninstallSteps(cask: cask, installation: installation)
        } catch {
            plan.blockers.append(UninstallBlocker(.unsupported, MacUpError.wrapping(error, context: "Planning").message))
        }
        if cask.pinned {
            plan.blockers.append(UninstallBlocker(
                .pinned,
                "Homebrew has \(cask.token) pinned, and MacUp does not unpin anything for you.",
                steps: ["Unpin it in Homebrew yourself, then try again."]
            ))
        }
        if !cask.administratorReasons.isEmpty {
            plan.blockers.append(UninstallBlocker(
                .needsAdministrator,
                "Uninstalling \(cask.token) needs an administrator. " + (cask.administratorReasons.first ?? ""),
                steps: ["In Terminal, run: brew uninstall --cask \(CommandInvocation.quoted(cask.token)). Homebrew asks for your password itself; MacUp never does."]
            ))
        }
        let boundary = uninstall.boundary(homebrewPrefix: plan.homebrewPrefix, forMacUp: false)
        if let app {
            if !app.removability.isRemovable {
                plan.blockers += Self.appBlockers(app)
            }
            plan.packageManagerRemovesBytes = app.sizeBytes ?? FileTree.size(of: app.path)?.bytes
            await addLeftovers(of: app, to: &plan, catalog: catalog, uninstall: uninstall, boundary: boundary)
            plan.blockers += await running(app, uninstall: uninstall)
        }
        addZap(cask, app: app, to: &plan, uninstall: uninstall, boundary: boundary)
        let caches = HomebrewLeftoverScanner(
            prefix: plan.homebrewPrefix,
            cacheDirectory: HomebrewLeftoverScanner.cacheDirectory(environment: environment.processEnvironment, homeDirectory: uninstall.homeDirectory)
        ).cask(cask.token)
        Self.add(caches, to: &plan, boundary: boundary, owner: cask.token)
        plan.warnings += cask.zapStepsNotCarriedOut
        plan.verification = [
            VerificationStep(
                summary: "Read Homebrew's installed packages back and check \(cask.token) is gone.",
                invocation: CommandInvocation(executable: installation.executable.path, arguments: HomebrewProvider.installedInfoArguments)
            ),
            VerificationStep(summary: "Check that \(app?.name ?? "its app") and each item you ticked are gone."),
        ]
        return plan
    }

    /// The paths a cask's `zap` lists, expanded here, each ticked or not by
    /// where it is: caches and preferences are, data is not.
    private func addZap(
        _ cask: HomebrewCask,
        app: InstalledApp?,
        to plan: inout UninstallPlan,
        uninstall: UninstallEnvironment,
        boundary: RemovalBoundary
    ) {
        let expander = ZapPathExpander(homeDirectory: uninstall.homeDirectory)
        var leftovers: [Leftover] = []
        for directive in cask.zap {
            switch expander.expand(directive.pattern) {
            case .refused(let reason):
                plan.cannotRemove.append(ManualRemoval(
                    path: directive.pattern,
                    reason: reason,
                    steps: ["If you want it gone, look for \(CommandInvocation.quoted(directive.pattern)) yourself."]
                ))
            case .paths(let paths):
                for path in paths where app.map({ !FileTree.isWithin(path, $0.path) }) ?? true {
                    leftovers.append(Self.zapLeftover(path, directive: directive, token: cask.token, homeDirectory: uninstall.homeDirectory))
                }
            }
        }
        Self.add(leftovers, to: &plan, boundary: boundary, owner: cask.token)
    }

    static func zapLeftover(_ path: String, directive: ZapDirective, token: String, homeDirectory: String) -> Leftover {
        let library = homeDirectory + "/Library/"
        let dataFolders = ["Application Support", "Containers", "Group Containers"].map { library + $0 + "/" }
        let isData = dataFolders.contains(where: path.hasPrefix) || !path.hasPrefix(library)
        if directive.action == .rmdir {
            let empty = (FileTree.names(in: path) ?? ["?"]).filter { $0 != ".DS_Store" }.isEmpty
            return Leftover(
                path: path,
                category: .declaredByPackageManager,
                selectedByDefault: empty,
                reason: empty
                    ? "The \(token) cask removes this folder when it is empty, and it is."
                    : "The \(token) cask removes this folder only when it is empty, and it is not.",
                warning: empty ? nil : AppLeftoverScanner.dataWarning
            )
        }
        return Leftover(
            path: path,
            category: .declaredByPackageManager,
            selectedByDefault: !isData,
            reason: "The \(token) cask lists this for a complete removal.",
            warning: isData ? AppLeftoverScanner.dataWarning : nil
        )
    }

    private func planFormula(
        _ package: UninstallablePackage,
        catalog: UninstallCatalog,
        configuration: LoadedConfiguration,
        uninstall: UninstallEnvironment,
        environment: CheckEnvironment
    ) async -> UninstallPlan {
        guard let item = catalog.formulae.first(where: { $0.id == package.packageID }) else {
            return Self.missing(package, environment: environment)
        }
        let name = item.id.name.split(separator: "/").last.map(String.init) ?? item.id.name
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: .formula,
                target: item.id.rawValue,
                packageID: item.id,
                name: item.displayName,
                version: package.version,
                source: "Homebrew formula"
            ),
            rationale: "Homebrew removes every installed version of \(name) (\(item.installedVersions.map(\.raw).joined(separator: ", "))). "
                + "MacUp tells Homebrew not to remove anything else with it: no automatic removal of other formulae, and "
                + "no cleanup. Its data and settings stay unless you tick them."
        )
        guard let installation = catalog.installations[.homebrew] else {
            plan.blockers.append(UninstallBlocker(.providerUnavailable, "MacUp could not find the Homebrew installation to run."))
            return plan
        }
        plan.homebrewPrefix = installation.fact("prefix")
        do {
            plan.steps = try scanner.homebrew.uninstallSteps(formula: item, installation: installation)
        } catch {
            plan.blockers.append(UninstallBlocker(.unsupported, MacUpError.wrapping(error, context: "Planning").message))
        }
        if item.pinnedByProvider {
            plan.blockers.append(UninstallBlocker(
                .pinned,
                "Homebrew has \(name) pinned, and MacUp does not unpin anything for you.",
                steps: ["In Terminal, run: brew unpin \(CommandInvocation.quoted(item.id.name)). Then try again."]
            ))
        }
        if item.details["serviceRunsAsRoot"] == "true" {
            plan.blockers.append(UninstallBlocker(
                .needsAdministrator,
                "\(name) runs as a service for the whole Mac, and stopping it needs an administrator.",
                steps: ["In Terminal, run: sudo brew services stop \(CommandInvocation.quoted(name)). Then try again."]
            ))
        }
        if item.details["serviceStatusUnknown"] == "true" {
            plan.blockers.append(UninstallBlocker(
                .ownershipUnknown,
                "MacUp could not read whether \(name) runs as a Homebrew service, so it cannot be sure uninstalling it would not leave one registered.",
                steps: ["`brew services list` shows it. Stop it there if it is listed, then try again."]
            ))
        }
        plan.blockers += await dependents(of: item.id, installation: installation, configuration: configuration, environment: environment)

        let boundary = uninstall.boundary(homebrewPrefix: plan.homebrewPrefix, forMacUp: false)
        let leftovers = HomebrewLeftoverScanner(
            prefix: plan.homebrewPrefix,
            cacheDirectory: HomebrewLeftoverScanner.cacheDirectory(environment: environment.processEnvironment, homeDirectory: uninstall.homeDirectory)
        ).formula(item.id.name)
        Self.add(leftovers, to: &plan, boundary: boundary, owner: name)
        if let prefix = plan.homebrewPrefix {
            plan.packageManagerRemovesBytes = FileTree.size(of: prefix + "/Cellar/" + name)?.bytes
        }
        if item.details["serviceStatus"].map({ $0 != "none" }) == true {
            plan.warnings.append("\(name) is set up as a Homebrew service. MacUp stops it and removes its launch agent first, so nothing is left starting a program that is gone.")
        }
        plan.verification = [
            VerificationStep(
                summary: "Read Homebrew's installed packages back and check \(name) is gone.",
                invocation: CommandInvocation(executable: installation.executable.path, arguments: HomebrewProvider.installedInfoArguments)
            ),
            VerificationStep(summary: "Check that each item you ticked is gone."),
        ]
        return plan
    }

    /// Refuses when other installed software needs the formula, naming it,
    /// and when MacUp could not find out: an unanswered question is not "no".
    private func dependents(
        of item: PackageID,
        installation: ProviderInstallation,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment
    ) async -> [UninstallBlocker] {
        var context = scanner.context(for: scanner.homebrew, configuration: configuration, environment: environment, log: CommandLog())
        context.installation = installation
        do {
            let listing = try await scanner.homebrew.dependents(of: item, context: context)
            if !listing.elements.isEmpty {
                return [UninstallBlocker(
                    .hasDependents,
                    "Other software on this Mac needs \(item.name): " + listing.elements.map(\.rawValue).joined(separator: ", ") + ".",
                    steps: ["Uninstall those first, or keep \(item.name). MacUp never removes something other software needs."],
                    dependents: listing.elements
                )]
            }
            if listing.isIncomplete {
                return [UninstallBlocker(
                    .hasDependents,
                    "Homebrew named something MacUp could not read when asked what needs \(item.name), so MacUp will not remove it.",
                    steps: ["`brew uses --installed \(ShellWord.isPlain(item.name) ? item.name : "<formula>")` shows what Homebrew says."]
                )]
            }
            return []
        } catch {
            return [UninstallBlocker(
                .hasDependents,
                "MacUp could not find out whether other software needs \(item.name), so it will not remove it.",
                steps: [MacUpError.wrapping(error, context: "Asking Homebrew what depends on it").message]
            )]
        }
    }

    // MARK: npm and mise

    private func planNpm(_ package: UninstallablePackage, catalog: UninstallCatalog, environment: CheckEnvironment) -> UninstallPlan {
        guard let item = catalog.npmItems.first(where: { $0.id == package.packageID }) else {
            return Self.missing(package, environment: environment)
        }
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: .npmPackage,
                target: item.id.rawValue,
                packageID: item.id,
                name: item.displayName,
                version: package.version,
                source: "npm global package"
            ),
            rationale: "npm removes \(item.displayName) from its global packages and the commands it added. No project's package.json is touched."
        )
        guard let installation = catalog.installations[.npm] else {
            plan.blockers.append(UninstallBlocker(.providerUnavailable, "MacUp could not find the npm installation to run."))
            return plan
        }
        if item.id.name == "npm" {
            plan.blockers.append(UninstallBlocker(
                .unsupported,
                "MacUp will not remove npm with npm: the Node it belongs to would be left without it.",
                steps: ["Remove Node itself with whatever installed it, which takes npm with it."]
            ))
        } else {
            do {
                plan.steps = [try scanner.npm.uninstallStep(for: item, installation: installation)]
            } catch {
                plan.blockers.append(UninstallBlocker(.unsupported, MacUpError.wrapping(error, context: "Planning").message))
            }
        }
        if let root = installation.fact(NpmProvider.FactKey.globalRoot) {
            plan.packageManagerRemovesBytes = FileTree.size(of: root + "/" + item.id.name)?.bytes
        }
        plan.verification = [VerificationStep(
            summary: "List npm's global packages and check \(item.displayName) is gone.",
            invocation: CommandInvocation(executable: installation.executable.path, arguments: NpmProvider.globalListArguments)
        )]
        return plan
    }

    private func planMise(
        _ package: UninstallablePackage,
        catalog: UninstallCatalog,
        uninstall: UninstallEnvironment,
        environment: CheckEnvironment
    ) -> UninstallPlan {
        guard let item = catalog.miseItems.first(where: { $0.id == package.packageID }), let version = package.version else {
            return Self.missing(package, environment: environment)
        }
        var plan = UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: .miseRuntime,
                target: package.target,
                packageID: item.id,
                name: item.displayName,
                version: version,
                source: "mise runtime"
            ),
            rationale: "mise removes \(item.displayName) \(version) and nothing else: other versions stay, and mise's configuration is not changed."
        )
        guard let installation = catalog.installations[.mise] else {
            plan.blockers.append(UninstallBlocker(.providerUnavailable, "MacUp could not find the mise installation to run."))
            return plan
        }
        do {
            plan.steps = [try scanner.mise.uninstallStep(tool: item, version: version, installation: installation)]
        } catch {
            plan.blockers.append(UninstallBlocker(.unsupported, MacUpError.wrapping(error, context: "Planning").message))
        }
        if item.activeVersion?.raw == version {
            let file = item.details["configPath"].map { PathDisplay.abbreviatingHome($0, homeDirectory: uninstall.homeDirectory) }
                ?? "Your mise configuration"
            plan.warnings.append(
                "\(file) still names \(item.displayName) \(version), the version in use. mise will report it missing, and "
                    + "install it again the next time something asks for it. MacUp leaves that file alone."
            )
        }
        if let installs = installation.fact(MiseProvider.FactKey.dataDirectory) {
            plan.packageManagerRemovesBytes = FileTree.size(of: installs + "/" + item.id.name + "/" + version)?.bytes
        }
        plan.verification = [VerificationStep(
            summary: "List mise's tools and check \(item.displayName) \(version) is gone.",
            invocation: CommandInvocation(executable: installation.executable.path, arguments: MiseProvider.toolListArguments)
        )]
        return plan
    }

    static func missing(_ package: UninstallablePackage, environment: CheckEnvironment) -> UninstallPlan {
        UninstallPlan(
            createdAt: environment.now(),
            subject: UninstallSubject(
                kind: package.kind,
                target: package.target,
                packageID: package.packageID,
                name: package.name,
                version: package.version,
                source: package.provider.displayName
            ),
            rationale: "",
            blockers: [UninstallBlocker(.notInstalled, "\(package.provider.displayName) no longer lists \(package.target).")]
        )
    }
}
