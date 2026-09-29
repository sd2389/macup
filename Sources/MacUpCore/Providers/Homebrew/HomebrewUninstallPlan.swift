import Foundation

/// A cask Homebrew lists as installed, with what uninstalling it involves.
public struct HomebrewCask: Sendable, Hashable, Codable {
    public var id: PackageID
    public var name: String
    public var installedVersion: String?
    /// Homebrew holds it at its version.
    public var pinned: Bool
    /// Where its apps are, exactly as Homebrew reports each app's `target`.
    public var appPaths: [String]
    /// What its `zap` stanza lists, for a complete removal.
    public var zap: [ZapDirective]
    /// The `zap` steps that are not paths — stopping a launch agent,
    /// forgetting a package receipt, running a script — which MacUp does not
    /// carry out, described.
    public var zapStepsNotCarriedOut: [String]
    /// Why Homebrew's own uninstall of this cask needs an administrator, when
    /// it does.
    public var administratorReasons: [String]

    public init(
        id: PackageID,
        name: String,
        installedVersion: String?,
        pinned: Bool = false,
        appPaths: [String] = [],
        zap: [ZapDirective] = [],
        zapStepsNotCarriedOut: [String] = [],
        administratorReasons: [String] = []
    ) {
        self.id = id
        self.name = name
        self.installedVersion = installedVersion
        self.pinned = pinned
        self.appPaths = appPaths
        self.zap = zap
        self.zapStepsNotCarriedOut = zapStepsNotCarriedOut
        self.administratorReasons = administratorReasons
    }

    public var token: String { id.name }
}

/// Reads the casks in `brew info --json=v2 --installed` (confirmed against
/// Homebrew 7.0.7) for what uninstalling them involves.
///
/// Each installed cask has `token`, `name`, `installed`, `pinned`, and
/// `artifacts`, a list of one-key objects:
///
/// ```json
/// {"app": ["Redis Insight.app"], "target": "/Applications/Redis Insight.app"}
/// {"zap": [{"trash": ["~/Library/Caches/org.example.App"], "rmdir": "~/.example"}]}
/// {"uninstall": [{"quit": "org.example.App", "pkgutil": "org.example.pkg"}]}
/// ```
///
/// An app's `target` is where Homebrew put it, which is how MacUp tells a
/// cask's app from one you dragged in; an app without a `target` is not
/// claimed for Homebrew. The same command is on the check's read-only
/// allowlist, so reading it names no package and changes nothing.
enum HomebrewCaskParser {
    static func parse(_ data: Data, homeDirectory: String, command: String? = nil) throws -> ProviderListing<HomebrewCask> {
        guard let document = JSONValue.parse(data) else {
            throw MacUpError.parseFailed("Homebrew's installed-package list was not valid JSON.", command: command)
        }
        guard let casks = document["casks"]?.arrayValue else {
            throw MacUpError.parseFailed("Homebrew's installed-package list had no \"casks\" array.", command: command)
        }
        var listing = ProviderListing<HomebrewCask>()
        for entry in casks {
            guard let token = entry["token"]?.stringValue else {
                listing.skip(ProviderSupport.skippedEntry("(unnamed cask)", provider: .homebrew, reason: "The entry has no token."))
                continue
            }
            let id: PackageID
            do {
                id = try PackageID(.brewCask, token)
            } catch let error as PackageID.ValidationError {
                listing.skip(ProviderSupport.skippedName(token, reason: error, provider: .homebrew))
                continue
            }
            var cask = HomebrewCask(
                id: id,
                name: entry["name"]?.arrayValue?.first?.stringValue ?? token,
                installedVersion: entry["installed"]?.stringValue,
                pinned: entry["pinned"]?.boolValue ?? false
            )
            for artifact in entry["artifacts"]?.arrayValue ?? [] {
                read(artifact, into: &cask, homeDirectory: homeDirectory)
            }
            listing.elements.append(cask)
        }
        return listing
    }

    private static func read(_ artifact: JSONValue, into cask: inout HomebrewCask, homeDirectory: String) {
        if artifact["app"] != nil, let target = artifact["target"]?.stringValue {
            let path = target.hasPrefix("~/") ? homeDirectory + target.dropFirst() : target
            if FileTree.isPlainAbsolute(path) { cask.appPaths.append(path) }
        }
        if artifact["pkg"] != nil || artifact["installer"] != nil {
            cask.administratorReasons.append(
                "It installs through a macOS installer package, and removing what the package put in place needs an administrator."
            )
        }
        for directive in artifact["uninstall"]?.arrayValue ?? [] {
            if directive["pkgutil"] != nil {
                cask.administratorReasons.append("Its uninstall steps remove a macOS installer package's files, which needs an administrator.")
            }
            if directive["kext"] != nil {
                cask.administratorReasons.append("Its uninstall steps unload a kernel extension, which needs an administrator.")
            }
            if directive["script"] != nil || directive["early_script"] != nil {
                cask.administratorReasons.append("Its uninstall steps run a script MacUp cannot see into, which may need an administrator.")
            }
            let paths = ["delete", "trash", "rmdir"].flatMap { directive[$0]?.stringList ?? [] }
            if paths.contains(where: { !$0.hasPrefix("~") }) {
                cask.administratorReasons.append("Its uninstall steps remove files outside your home folder, which needs an administrator.")
            }
        }
        for directive in artifact["zap"]?.arrayValue ?? [] {
            for action in [ZapDirective.Action.trash, .delete, .rmdir] {
                for pattern in directive[action.rawValue]?.stringList ?? [] {
                    cask.zap.append(ZapDirective(action: action, pattern: pattern))
                }
            }
            for key in (directive.objectValue ?? [:]).keys.sorted() where !["trash", "delete", "rmdir"].contains(key) {
                cask.zapStepsNotCarriedOut.append(zapStepDescription(key))
            }
        }
    }

    private static func zapStepDescription(_ key: String) -> String {
        switch key {
        case "launchctl": "Its zap also removes launchd jobs, which MacUp does not do; any it left are listed below if MacUp found them."
        case "pkgutil": "Its zap also forgets installer-package receipts, which needs an administrator, so MacUp does not do it."
        case "quit", "signal": "Its zap also quits the app, which MacUp does not do: quit it yourself first."
        case "script": "Its zap also runs a script, which MacUp does not run."
        case "kext": "Its zap also unloads a kernel extension, which needs an administrator, so MacUp does not do it."
        case "login_item": "Its zap also removes a login item, which MacUp does not do: check System Settings → General → Login Items."
        default: "Its zap has a step MacUp does not recognize (\(TerminalText.sanitize(key))), so MacUp does not carry it out."
        }
    }
}

/// Uninstalling Homebrew formulae and casks (docs/PROVIDER_NOTES.md).
///
/// The commands were confirmed against `brew help uninstall` and `brew help
/// services` (Homebrew 7.0.7):
///
/// - `brew uninstall --formula --force <name>` removes every installed
///   version. `--ignore-dependencies` is never passed: when other formulae
///   need this one, MacUp refuses and names them, and Homebrew would refuse
///   anyway.
/// - `brew uninstall --cask <token>` removes the cask and its app. `--zap`
///   is never passed: MacUp removes the paths a zap lists itself, so each one
///   follows the reader's ticks and chosen mode.
/// - `brew services stop <name>` first, when the formula is registered as a
///   service, so no launch agent is left pointing at a program that is gone.
///
/// `brew uninstall` runs `brew autoremove` afterwards unless
/// `HOMEBREW_NO_AUTOREMOVE` is set, which would remove formulae the reader
/// never saw in the plan, and it can ask for `sudo` part-way through. Neither
/// has a command-line flag, so both are switched off in the environment
/// (``uninstallEnvironment(context:)``), where `HOMEBREW_NO_SUDO` makes
/// Homebrew fail with a message rather than prompt for a password.
extension HomebrewProvider {
    static let uninstallEnvironmentPolicy = modifyingEnvironmentPolicy.adding(overrides: [
        "HOMEBREW_NO_AUTOREMOVE": "1",
        "HOMEBREW_NO_SUDO": "1",
    ])

    public func uninstallEnvironment(context: ProviderContext) -> [String: String] {
        let searchPath = context.installation.map { childSearchPath($0.executable) } ?? SearchPath.system
        return Self.uninstallEnvironmentPolicy.environment(from: context.environment, searchPath: searchPath)
    }

    static func formulaUninstallArguments(_ name: String) -> [String] { ["uninstall", "--formula", "--force", name] }
    static func caskUninstallArguments(_ token: String) -> [String] { ["uninstall", "--cask", token] }
    static func serviceStopArguments(_ name: String) -> [String] { ["services", "stop", name] }

    /// The steps that uninstall a formula: stop its service when it has one
    /// registered, then remove every version.
    func uninstallSteps(formula item: ManagedItem, installation: ProviderInstallation) throws -> [ExecutionStep] {
        let name = try PlanSupport.argument(naming: item.id)
        var steps: [ExecutionStep] = []
        if let status = item.details["serviceStatus"], status != "none" {
            steps.append(ExecutionStep(
                summary: "Stop the \(name) service and remove its launch agent",
                invocation: CommandInvocation(executable: installation.executable.path, arguments: Self.serviceStopArguments(name)),
                effect: .modifying,
                expectsNetwork: false,
                mayRequirePrivilege: false,
                timeoutSeconds: 180
            ))
        }
        steps.append(ExecutionStep(
            summary: "Uninstall every installed version of \(name)",
            invocation: CommandInvocation(executable: installation.executable.path, arguments: Self.formulaUninstallArguments(name)),
            effect: .modifying,
            expectsNetwork: false,
            mayRequirePrivilege: false,
            timeoutSeconds: 900
        ))
        return steps
    }

    func uninstallSteps(cask: HomebrewCask, installation: ProviderInstallation) throws -> [ExecutionStep] {
        let token = try PlanSupport.argument(naming: cask.id)
        return [ExecutionStep(
            summary: "Uninstall the cask \(token)",
            invocation: CommandInvocation(executable: installation.executable.path, arguments: Self.caskUninstallArguments(token)),
            effect: .modifying,
            expectsNetwork: false,
            mayRequirePrivilege: false,
            timeoutSeconds: 900
        )]
    }

    /// What Homebrew has installed, for the uninstaller: formulae with their
    /// service state, and casks with their apps and zap lists. One read of
    /// `brew info --json=v2 --installed`, plus `brew services list --json`
    /// when asked.
    func uninstallInventory(
        context: ProviderContext,
        includeServices: Bool
    ) async throws -> (formulae: ProviderListing<ManagedItem>, casks: ProviderListing<HomebrewCask>) {
        let installation = try await requireInstallation(context)
        async let services: HomebrewServiceReading? = includeServices ? readServices(installation, context: context) : nil
        let result = try await run(Self.installedInfoArguments, installation, context: context)
        guard result.succeeded else {
            throw MacUpError.commandFailed(result, "`brew info` failed.")
        }
        var formulae = try HomebrewInventoryParser.parse(
            result.standardOutput,
            ownership: nil,
            command: result.invocation.displayString
        )
        if let prefix = installation.fact("prefix") {
            formulae.elements = Self.annotate(formulae.elements, prefix: prefix, fileSystem: context.fileSystem)
        }
        if let services = await services {
            let annotated = Self.annotate(formulae.elements, services: services)
            formulae.elements = annotated.items
            formulae.findings += annotated.findings
        }
        let casks = try HomebrewCaskParser.parse(
            result.standardOutput,
            homeDirectory: context.homeDirectory,
            command: result.invocation.displayString
        )
        return (formulae, casks)
    }

    /// Whether Homebrew still lists the item, read back after an uninstall.
    func confirmUninstalled(_ item: PackageID, context: ProviderContext) async -> UninstallCheck {
        let summary = "Homebrew no longer lists \(item.name)"
        do {
            let installation = try PlanSupport.installation(context, id)
            let result = try await run(Self.installedInfoArguments, installation, context: context)
            guard result.succeeded else {
                return UninstallCheck(summary: summary, passed: nil, detail: "`brew info` failed afterwards, so MacUp could not check.")
            }
            let formulae = try HomebrewInventoryParser.parse(result.standardOutput, ownership: nil)
            let casks = try HomebrewCaskParser.parse(result.standardOutput, homeDirectory: context.homeDirectory)
            let listed = formulae.elements.contains { $0.id == item } || casks.elements.contains { $0.id == item }
            return UninstallCheck(
                summary: summary,
                passed: !listed,
                detail: listed ? "Homebrew still lists \(item.name) as installed." : nil
            )
        } catch {
            return UninstallCheck(
                summary: summary,
                passed: nil,
                detail: MacUpError.wrapping(error, context: "Reading Homebrew's installed packages back").message
            )
        }
    }
}
