import ArgumentParser
import Foundation
import MacUpCore

extension RemovalMode: ExpressibleByArgument {}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Uninstall an app or a package, and the files it left behind.",
        discussion: """
            MacUp shows exactly what it would remove before it removes anything: what the \
            package manager will run, every leftover file with its size, and what it cannot \
            remove with the steps to do it yourself. Files that clearly belong to the item are \
            included; your data — chats, saved games, databases — and anything matched only by \
            name are left in place unless you add them.

            A target is a package ID (brew:mysql, brew-cask:firefox, npm:typescript, \
            mise:node@22), an app as app:<bundle-id>, an app name, or an app's path.

            At a terminal MacUp asks each time whether to move the files to the Trash or delete \
            them permanently, then asks you to confirm. Without a terminal, --mode and --yes \
            are required.

            Examples:
              macup uninstall --list
              macup uninstall ChatGPT --dry-run
              macup uninstall brew:mysql --include-data
              macup uninstall app:com.example.game --all --mode trash
            """
    )

    @Argument(help: "What to uninstall: a package ID, app:<bundle-id>, an app name, or an app path.")
    var target: String?

    @Flag(name: .long, help: "List what can be uninstalled. Reads only.")
    var list = false

    @Flag(name: .long, help: "List what apps you have already removed left behind in your Library. Reads only.")
    var orphans = false

    @Flag(name: .long, help: "Show what would be removed, and remove nothing.")
    var dryRun = false

    @Option(name: .long, help: "trash (recoverable until you empty the Trash) or delete (permanent). Asked at a terminal when left out.")
    var mode: RemovalMode?

    @Option(name: .customLong("include"), help: "Also remove this listed path, which is left in place by default. Repeatable.")
    var includes: [String] = []

    @Flag(name: .customLong("include-data"), help: "Also remove the data folders the plan lists: app data, databases, settings.")
    var includeData = false

    @Flag(name: .long, help: "Remove everything MacUp can remove: no residue. What only you can remove is still listed.")
    var all = false

    @Flag(name: [.customShort("y"), .long], help: "Confirm without asking.")
    var yes = false

    @Flag(name: .long, help: "Write the administrator-only part as a script you can read and run with sudo. Removes nothing itself.")
    var adminScript = false

    @Flag(name: .long, help: "Print machine-readable JSON. Never asks anything; a real uninstall needs --mode and --yes.")
    var json = false

    func validate() throws {
        if list && target != nil { throw ValidationError("--list lists everything; leave out the target.") }
        if adminScript && (list || orphans) { throw ValidationError("--admin-script needs a target.") }
        if orphans && target != nil { throw ValidationError("--orphans lists what was left behind; leave out the target.") }
        if list && orphans { throw ValidationError("Use --list or --orphans, not both.") }
        if !list && !orphans && target == nil {
            throw ValidationError("Name what to uninstall, or use --list or --orphans.")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        let uninstall = context.uninstallEnvironment
        let environment = context.checkEnvironment

        // Looking for what an app left behind means measuring folders in
        // ~/Library, so it happens only when it was asked for.
        let wantsOrphans = orphans || target?.hasPrefix(OrphanScanner.targetPrefix) == true
        let catalog = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await UninstallScanner().catalog(
                configuration: loaded,
                environment: environment,
                uninstall: uninstall,
                measureApps: false,
                includeOrphans: wantsOrphans
            )
        }
        if list {
            context.print(json ? try JSONOutput.encode(catalog) : UninstallRenderer(style: style).catalog(catalog))
            return
        }
        if orphans {
            context.print(json ? try JSONOutput.encode(catalog) : UninstallRenderer(style: style).orphans(catalog))
            return
        }

        let resolved: UninstallTarget
        switch UninstallTargetResolver.resolve(target ?? "", in: catalog, homeDirectory: uninstall.homeDirectory) {
        case .success(let found):
            resolved = found
        case .failure(let error):
            context.printError("error: " + TerminalText.sanitize(error.message))
            if !error.candidates.isEmpty {
                context.printError("Did you mean: " + error.candidates.map(TerminalText.sanitize).joined(separator: ", ") + "?")
            }
            context.printError("`macup uninstall --list` lists what MacUp can uninstall. Nothing was removed.")
            throw MacUpExitCode.usage.exitCode
        }

        try await UninstallWorkflow(
            target: resolved,
            catalog: catalog,
            dryRun: dryRun,
            mode: mode,
            includes: includes,
            includeData: includeData,
            all: all,
            yes: yes,
            json: json,
            adminScript: adminScript
        ).run(context: context, paths: paths, configuration: loaded, style: style)
    }
}

struct SelfUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-uninstall",
        abstract: "Remove MacUp itself from this Mac, with nothing left behind.",
        discussion: """
            Removes the MacUp app, every installed `macup` command, MacUp's settings, history, \
            and saved state, its scheduled check, its Keychain items, and its files in \
            ~/Library. Nothing else on your Mac is touched. MacUp shows the full list first, \
            asks whether to use the Trash or delete permanently, and asks you to confirm.
            """
    )

    @Flag(name: .long, help: "Show what would be removed, and remove nothing.")
    var dryRun = false

    @Option(name: .long, help: "trash or delete. Asked at a terminal when left out.")
    var mode: RemovalMode?

    @Flag(name: [.customShort("y"), .long], help: "Confirm without asking.")
    var yes = false

    @Flag(name: .long, help: "Print machine-readable JSON. Never asks anything.")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        let uninstall = context.uninstallEnvironment
        let environment = context.checkEnvironment
        let catalog = await UninstallScanner().catalog(
            configuration: loaded, environment: environment, uninstall: uninstall, measureApps: false
        )
        try await UninstallWorkflow(
            target: .macUp,
            catalog: catalog,
            dryRun: dryRun,
            mode: mode,
            includes: [],
            includeData: false,
            // Removing MacUp leaves nothing of MacUp behind: its own files are
            // all it lists, and none of them is anyone's data.
            all: true,
            yes: yes,
            json: json
        ).run(context: context, paths: paths, configuration: loaded, style: style)
    }
}

/// One uninstall from a resolved target to a recorded result, shared by both
/// commands.
struct UninstallWorkflow {
    var target: UninstallTarget
    var catalog: UninstallCatalog
    var dryRun: Bool
    var mode: RemovalMode?
    var includes: [String]
    var includeData: Bool
    var all: Bool
    var yes: Bool
    var json: Bool
    /// Write the administrator-only part as a script and stop. Nothing on the
    /// Mac is changed: the only thing written is MacUp's own file.
    var adminScript = false

    func run(context: CLIContext, paths: MacUpPaths, configuration loaded: LoadedConfiguration, style: TextStyle) async throws {
        let uninstall = context.uninstallEnvironment
        let environment = context.checkEnvironment
        let renderer = UninstallRenderer(style: style)
        let plan = await UninstallPlanner().plan(
            target, catalog: catalog, configuration: loaded, environment: environment, uninstall: uninstall, paths: paths
        )

        var selection = UninstallSelection(plan)
        if includeData { selection.includeData(from: plan) }
        if all { selection.includeEverything(from: plan) }
        let unmatched = selection.include(includes, from: plan, homeDirectory: uninstall.homeDirectory)
        guard unmatched.isEmpty else {
            context.printError("error: this uninstall does not list " + unmatched.map(TerminalText.sanitize).joined(separator: ", ")
                + ". MacUp removes only what its plan lists; `--dry-run` shows the list. Nothing was removed.")
            throw MacUpExitCode.usage.exitCode
        }

        if adminScript {
            try writeAdminScript(plan, context: context, paths: paths, style: style)
            return
        }
        if json && (dryRun || !plan.canRun) {
            context.print(try JSONOutput.encode(plan))
            if !plan.canRun { throw MacUpExitCode.failure.exitCode }
            return
        }
        if !json { context.print(renderer.plan(plan, selection: selection, dryRun: dryRun)) }
        guard plan.canRun else {
            context.printError("Nothing was removed.")
            throw MacUpExitCode.failure.exitCode
        }
        if dryRun { return }

        // How to remove: asked every time at a terminal, never assumed.
        let chosen: RemovalMode
        if let mode {
            chosen = mode
        } else if !json, context.standardOutputIsTerminal, let answer = context.askRemovalMode() {
            chosen = answer
        } else {
            context.printError("error: choose how to remove the files with --mode trash or --mode delete. Nothing was removed.")
            throw MacUpExitCode.usage.exitCode
        }

        let totals = plan.totals(for: selection.paths)
        let size = UninstallSizeText.text(totals.bytes, partial: totals.bytesArePartial)
        if !yes {
            guard !json, context.standardOutputIsTerminal else {
                context.printError("error: this is not a terminal, so MacUp cannot ask; pass --yes to confirm. Nothing was removed.")
                throw MacUpExitCode.usage.exitCode
            }
            let question = chosen == .delete
                ? "Delete \(TextStyle.plural(totals.count, "item")) (\(size)) permanently? This cannot be undone."
                : "Uninstall \(TerminalText.sanitize(plan.subject.name)) and move \(TextStyle.plural(totals.count, "item")) (\(size)) to the Trash?"
            context.print("")
            guard context.askToProceed(question) else {
                context.print("Nothing was removed.")
                return
            }
        }

        try await context.requireApproval(
            "uninstall \(TerminalText.sanitize(plan.subject.name)) from this Mac",
            loaded.configuration,
            paths: paths
        )

        let engine = UninstallEngine.standard(paths: paths)
        let scheduler = context.scheduler(paths: paths)
        let narrate = !json
        let chosenPaths = selection.paths
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(
                plan,
                selection: chosenPaths,
                mode: chosen,
                options: UninstallOptions(origin: .cli),
                configuration: loaded,
                environment: environment,
                uninstall: uninstall,
                scheduler: scheduler
            ) { progress in
                guard narrate else { return }
                switch progress {
                case .runningCommand(let command): context.print("  Running: " + TerminalText.sanitize(command))
                case .running(let action): context.print("  " + TerminalText.sanitize(action.summary))
                case .removing(let path, let index, let total):
                    context.print("  Removing \(index) of \(total): " + style.path(path))
                case .checking: context.print("  Checking what is left…")
                }
            }
        }

        if json {
            context.print(try JSONOutput.encode(report))
        } else {
            context.print("")
            context.print(renderer.report(report, rollback: plan.rollback(for: chosen)))
        }
        switch report.outcome {
        case .uninstalled: return
        case .cancelled: throw MacUpExitCode.cancelled.exitCode
        case .refused: throw MacUpExitCode.failure.exitCode
        case .incomplete, .failed: throw MacUpExitCode.updateFailed.exitCode
        }
    }

    /// Writes the administrator-only part of the plan as a script, and says
    /// what to do with it. MacUp changes nothing on the Mac here: it writes
    /// one file of its own, and `sudo` asks the person for their password
    /// when they run it (docs/TRUST_AND_SECURITY.md, "Privilege").
    private func writeAdminScript(
        _ plan: UninstallPlan,
        context: CLIContext,
        paths: MacUpPaths,
        style: TextStyle
    ) throws {
        guard plan.cannotRemove.contains(where: { !$0.commands.isEmpty }) else {
            context.printError("error: nothing in this uninstall needs an administrator, so there is no script to write.")
            if let vendor = plan.vendorUninstaller {
                context.printError(TerminalText.sanitize(vendor.summary))
            }
            throw MacUpExitCode.usage.exitCode
        }
        let script: AdminRemovalScript
        do {
            script = try AdminRemovalScriptWriter.write(plan, paths: paths)
        } catch {
            let message = (error as? MacUpError)?.message ?? "The script could not be written."
            context.printError("error: " + TerminalText.sanitize(message))
            throw MacUpExitCode.failure.exitCode
        }

        if json {
            context.print(try JSONOutput.encode(AdminScriptDocument(script, plan: plan)))
            return
        }
        context.print(style.bold("Wrote the administrator-only part of this uninstall"))
        context.print("  " + style.path(script.path))
        context.print("  " + TextStyle.plural(script.items.count, "item") + ", removed permanently. Root does not use the Trash.")
        context.print("")
        for item in script.items {
            context.print("  " + style.path(item.path))
        }
        if !script.refused.isEmpty {
            context.print("")
            context.print(style.bold("Not in the script; the written steps are the only way"))
            for (item, reason) in script.refused {
                context.print("  " + style.path(item.path) + style.dim("  " + style.text(reason)))
            }
        }
        if let vendor = plan.vendorUninstaller {
            context.print("")
            context.print(style.text(vendor.summary))
            context.print(style.dim("  " + vendor.path))
        }
        context.print("")
        context.print("Read it, then run it. sudo asks for your password; MacUp never sees it:")
        context.print("  " + style.path(script.command))
    }
}

/// `macup uninstall <target> --admin-script --json`.
private struct AdminScriptDocument: Encodable {
    let kind = "adminRemovalScript"
    let macupVersion = MacUp.version
    let target: String
    let path: String
    let command: String
    let items: [String]
    let refused: [Refused]
    let vendorUninstaller: VendorUninstaller?

    struct Refused: Encodable {
        let path: String
        let reason: String
    }

    init(_ script: AdminRemovalScript, plan: UninstallPlan) {
        target = plan.subject.target
        path = script.path
        command = script.command
        items = script.items.map(\.path)
        refused = script.refused.map { Refused(path: $0.item.path, reason: $0.reason) }
        vendorUninstaller = plan.vendorUninstaller
    }
}
