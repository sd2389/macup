import Foundation

/// Finds everything MacUp can uninstall. Reading only.
///
/// Apps come from the Applications folders. Packages come from the package
/// managers, each asked through a ``ReadOnlyCommandGuard`` whose rules are the
/// check's allowlist plus the one lookup an uninstall needs that a check never
/// makes (`brew uses --installed`, for what depends on a formula), so looking
/// cannot change anything. A package manager turned off in MacUp's
/// configuration is not asked at all.
public struct UninstallScanner: Sendable {
    public var homebrew: HomebrewProvider
    public var npm: NpmProvider
    public var mise: MiseProvider

    public init(
        homebrew: HomebrewProvider = HomebrewProvider(),
        npm: NpmProvider = NpmProvider(),
        mise: MiseProvider = MiseProvider()
    ) {
        self.homebrew = homebrew
        self.npm = npm
        self.mise = mise
    }

    public var providers: [any UpdateProvider] { [homebrew, npm, mise] }

    /// The rules every command an uninstall reads with must match.
    static let readOnlyRules = CommandAllowlist.readOnlyCheck.filter { $0.effect == .readOnly }
        + CommandAllowlist.dependentsLookup

    /// Everything installed that MacUp can uninstall, and what it can see but
    /// will not. `measureApps` adds up each app's size, which reads every file
    /// in it; the list is useful without it, and much faster.
    public func catalog(
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        uninstall: UninstallEnvironment,
        measureApps: Bool = true
    ) async -> UninstallCatalog {
        let log = CommandLog()
        var catalog = UninstallCatalog(createdAt: environment.now())

        async let homebrewReading = readHomebrew(configuration: configuration, environment: environment, log: log)
        async let npmReading = readInventory(npm, configuration: configuration, environment: environment, log: log)
        async let miseReading = readInventory(mise, configuration: configuration, environment: environment, log: log)
        let (brew, node, tools) = await (homebrewReading, npmReading, miseReading)

        catalog.providers = [brew.state, node.state, tools.state]
        if let installation = brew.installation { catalog.installations[.homebrew] = installation }
        if let installation = node.installation { catalog.installations[.npm] = installation }
        if let installation = tools.installation { catalog.installations[.mise] = installation }
        catalog.formulae = brew.formulae
        catalog.casks = brew.casks
        catalog.npmItems = node.items
        catalog.miseItems = tools.items

        var caskApps: [String: String] = [:]
        for cask in brew.casks {
            for path in cask.appPaths {
                caskApps[FileTree.canonicalPath(path) ?? path] = cask.token
            }
        }
        catalog.apps = await AppScanner(applicationDirectories: uninstall.applicationDirectories)
            .scan(caskApps: caskApps, measure: measureApps)
        catalog.packages = Self.packages(formulae: brew.formulae, casks: brew.casks, npm: node.items, mise: tools.items)
        catalog.manualInstalls = Self.manualInstalls(uninstall)
        catalog.commands = await log.records.sorted { $0.startedAt < $1.startedAt }
        return catalog
    }

    // MARK: Asking the package managers

    struct Reading {
        var state: UninstallProviderState
        var installation: ProviderInstallation?
        var items: [ManagedItem] = []
        var formulae: [ManagedItem] = []
        var casks: [HomebrewCask] = []
    }

    func context(
        for provider: any UpdateProvider,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        log: CommandLog
    ) -> ProviderContext {
        ProviderContext(
            runner: RecordingCommandRunner(
                base: ReadOnlyCommandGuard(base: environment.runner, rules: Self.readOnlyRules, allowsMetadataRefresh: false),
                log: log
            ),
            fileSystem: environment.fileSystem,
            environment: environment.processEnvironment,
            homeDirectory: PathDisplay.standardized(environment.homeDirectory),
            searchPath: SearchPath.parse(environment.processEnvironment["PATH"]),
            settings: configuration.configuration.settings(for: provider.id),
            system: environment.system,
            now: environment.now
        )
    }

    /// Finds the provider, or says why it could not be asked.
    func detect(
        _ provider: any UpdateProvider,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        log: CommandLog
    ) async -> (context: ProviderContext?, state: UninstallProviderState) {
        guard configuration.configuration.settings(for: provider.id).enabled else {
            return (nil, UninstallProviderState(
                provider: provider.id,
                state: .off,
                message: "\(provider.displayName) is turned off in MacUp's configuration, so MacUp asked it nothing."
            ))
        }
        var context = context(for: provider, configuration: configuration, environment: environment, log: log)
        let status = await provider.detect(context: context)
        switch status.availability {
        case .available:
            context.installation = status.installation
            return (context, UninstallProviderState(provider: provider.id, state: .available))
        case .unavailable:
            return (nil, UninstallProviderState(provider: provider.id, state: .notInstalled, message: status.error?.message))
        case .disabled, .failed:
            return (nil, UninstallProviderState(provider: provider.id, state: .failed, message: status.error?.message))
        }
    }

    private func readHomebrew(
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        log: CommandLog
    ) async -> Reading {
        let (context, state) = await detect(homebrew, configuration: configuration, environment: environment, log: log)
        guard let context else { return Reading(state: state) }
        do {
            let (formulae, casks) = try await homebrew.uninstallInventory(context: context, includeServices: true)
            return Reading(state: state, installation: context.installation, formulae: formulae.elements, casks: casks.elements)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading what Homebrew has installed")
            return Reading(
                state: UninstallProviderState(provider: .homebrew, state: .failed, message: failure.message),
                installation: context.installation
            )
        }
    }

    private func readInventory(
        _ provider: any UpdateProvider,
        configuration: LoadedConfiguration,
        environment: CheckEnvironment,
        log: CommandLog
    ) async -> Reading {
        let (context, state) = await detect(provider, configuration: configuration, environment: environment, log: log)
        guard let context else { return Reading(state: state) }
        do {
            let listing = try await provider.inventory(context: context)
            return Reading(state: state, installation: context.installation, items: listing.elements)
        } catch {
            let failure = MacUpError.wrapping(error, context: "Reading what \(provider.displayName) has installed")
            return Reading(
                state: UninstallProviderState(provider: provider.id, state: .failed, message: failure.message),
                installation: context.installation
            )
        }
    }

    // MARK: The list

    static func packages(
        formulae: [ManagedItem],
        casks: [HomebrewCask],
        npm: [ManagedItem],
        mise: [ManagedItem]
    ) -> [UninstallablePackage] {
        var packages: [UninstallablePackage] = []
        for formula in formulae.sorted(by: { $0.id < $1.id }) {
            let versions = formula.installedVersions.map(\.raw)
            let version = HomebrewProvider.versionInUse(formula) ?? versions.last
            packages.append(UninstallablePackage(
                target: formula.id.rawValue,
                packageID: formula.id,
                kind: .formula,
                name: formula.displayName,
                version: version,
                note: versions.count > 1 ? "\(versions.count) versions installed: " + versions.joined(separator: ", ") : nil
            ))
        }
        for cask in casks.sorted(by: { $0.id < $1.id }) {
            packages.append(UninstallablePackage(
                target: cask.id.rawValue,
                packageID: cask.id,
                kind: .cask,
                name: cask.name,
                version: cask.installedVersion,
                appPath: cask.appPaths.first
            ))
        }
        for item in npm.sorted(by: { $0.id < $1.id }) {
            packages.append(UninstallablePackage(
                target: item.id.rawValue,
                packageID: item.id,
                kind: .npmPackage,
                name: item.displayName,
                version: item.activeVersion?.raw
            ))
        }
        for tool in mise.sorted(by: { $0.id < $1.id }) {
            for version in tool.installedVersions.map(\.raw) {
                packages.append(UninstallablePackage(
                    target: tool.id.rawValue + "@" + version,
                    packageID: tool.id,
                    kind: .miseRuntime,
                    name: tool.displayName,
                    version: version,
                    note: tool.activeVersion?.raw == version ? "In use" : nil
                ))
            }
        }
        return packages
    }

    /// A python.org Python: its installer puts it in `/Library/Frameworks`,
    /// which only an administrator can change, so MacUp lists it with the
    /// steps python.org gives and removes none of it.
    static func manualInstalls(_ uninstall: UninstallEnvironment) -> [ManualInstall] {
        let framework = uninstall.pythonFramework
        guard FileTree.isDirectory(framework) else { return [] }
        let versions = (FileTree.names(in: framework + "/Versions") ?? []).filter { $0 != "Current" && !$0.hasPrefix(".") }
        var steps: [String] = []
        for version in versions {
            steps.append("In Finder, move the “Python \(version)” folder in Applications to the Trash.")
        }
        steps.append("In Terminal, run: sudo rm -rf \(CommandInvocation.quoted(framework))")
        steps.append("Then remove the links it made: run `ls -l /usr/local/bin | grep Python.framework`, and `sudo rm` each one it lists.")
        steps.append("Finally, `pkgutil --pkgs | grep org.python` lists its installer receipts; `sudo pkgutil --forget` each one.")
        return [ManualInstall(
            name: versions.isEmpty ? "Python from python.org" : "Python " + versions.joined(separator: ", ") + " from python.org",
            path: framework,
            reason: "python.org's installer puts Python where only an administrator can remove it, and MacUp never asks for a password.",
            steps: steps
        )]
    }
}
