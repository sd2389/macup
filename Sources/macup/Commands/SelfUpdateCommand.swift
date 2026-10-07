import ArgumentParser
import Foundation
import MacUpCore

struct SelfUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Update MacUp itself, through whatever installed it.",
        discussion: """
            MacUp opens no network connection of its own, so it never asks a server \
            whether a new version exists. When Homebrew installed MacUp, Homebrew's own \
            outdated list — the one every `macup check` already reads — says whether \
            there is a newer version, and updating is an ordinary Homebrew update: the \
            same plan, the same confirmation, the same history as any other item.

            A copy you downloaded and moved into place yourself is not something MacUp \
            can update. It says so, and prints where the releases are. MacUp never \
            downloads, unpacks, or replaces itself.

            Exit status: 0 nothing to do, or the update succeeded; 2 Homebrew failed, so \
            MacUp cannot say whether an update exists; 3 the configuration is invalid; \
            4 the update failed; 77 the device owner did not approve; 130 cancelled.
            """
    )

    @Flag(name: .long, help: "Show what would run and launch nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Confirm the update instead of asking.")
    var yes = false

    @Flag(help: "Refresh Homebrew's package metadata first, so the answer is not from a stale list.")
    var refresh = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1). Never asks anything; use --yes.")
    var json = false

    @Flag(name: .shortAndLong, help: "Show every command MacUp ran, with its exit status and timing.")
    var verbose = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)

        let (check, plan) = await PlanWorkflow.checkAndPlan(
            PlanRequest(selection: nil, intent: .interactive, refreshMetadata: refresh),
            configuration: loaded,
            context: context
        )
        if plan.cancelled {
            context.printError("Cancelled before MacUp finished looking. Nothing was changed.")
            throw MacUpExitCode.cancelled.exitCode
        }

        let status = SelfUpdate.status(
            check: check,
            executablePath: context.executablePath,
            appBundlePath: context.uninstallEnvironment.currentAppBundle,
            fileSystem: context.checkEnvironment.fileSystem
        )

        if json, !status.hasUpdate {
            context.print(try JSONOutput.encode(SelfUpdateDocument(status)))
            return
        }
        if !json {
            context.print(style.bold(style.text(status.headline)))
            for installation in status.installations {
                var line = "  " + installation.displayName
                if let path = installation.path { line += " · " + style.path(path) }
                context.print(style.dim(line))
            }
        }

        guard status.hasUpdate else {
            if !status.isManagedByHomebrew, !json {
                context.print("")
                context.print("Download the next version yourself: " + style.path(status.releasesURL))
                context.print(style.dim("MacUp never downloads or replaces itself."))
            }
            if status.unknownReason != nil { throw MacUpExitCode.providerErrors.exitCode }
            return
        }

        // Only MacUp's own items, so a self-update never carries anything
        // else along with it.
        let items = Set(status.updates.map(\.id))
        var ours = plan
        ours.planned = plan.planned.filter { items.contains($0.item) }
        ours.skipped = plan.skipped.filter { items.contains($0.item) }

        guard !ours.planned.isEmpty else {
            if !json {
                context.print("")
                context.print("MacUp will not update itself: " + style.text(
                    ours.skipped.first?.reason ?? "your policy does not allow it."
                ))
                context.print(style.dim("`macup policy set \(items.first?.rawValue ?? "brew:macup") ask` changes that."))
            } else {
                context.print(try JSONOutput.encode(SelfUpdateDocument(status)))
            }
            return
        }
        if !json { context.print("") }

        _ = try await UpdateRun(dryRun: dryRun, yes: yes, json: json, verbose: verbose)
            .apply(ours, configuration: loaded, paths: paths, context: context, style: style) { _ in
                "update MacUp itself on this Mac"
            }
    }
}

/// `macup self-update --json` when there is nothing to run: what MacUp is,
/// how it was installed, and whether Homebrew has anything newer.
struct SelfUpdateDocument: Encodable {
    struct Installation: Encodable {
        let kind: String
        let item: String?
        let path: String?
    }

    let schemaVersion = 1
    let kind = "selfUpdate"
    let macupVersion = MacUp.version
    let runningVersion: String
    let managedByHomebrew: Bool
    let updateAvailable: Bool
    let availableVersion: String?
    let installations: [Installation]
    let unknownReason: String?
    let releasesURL: String

    init(_ status: SelfUpdateStatus) {
        runningVersion = status.runningVersion
        managedByHomebrew = status.isManagedByHomebrew
        updateAvailable = status.hasUpdate
        availableVersion = status.updates.first?.availableVersion.raw
        installations = status.installations.map { installation -> Installation in
            Installation(
                kind: installation.kind.rawValue,
                item: installation.item?.rawValue,
                path: installation.path
            )
        }
        unknownReason = status.unknownReason
        releasesURL = status.releasesURL
    }
}
