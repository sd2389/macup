import ArgumentParser
import Foundation
import MacUpCore

extension MacUpConfiguration.ScheduleSettings.Frequency: ExpressibleByArgument {}
extension MacUpConfiguration.ScheduleSettings.Weekday: ExpressibleByArgument {}

struct ScheduleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Check automatically on a schedule. A scheduled check never updates anything.",
        discussion: """
            MacUp installs a launchd user agent that runs `macup check --save-state` \
            at the time you choose. The scheduled run is the same read-only check as \
            `macup check`: it installs, upgrades, and removes nothing. It writes its \
            report to ~/.local/state/macup/last-check.json and its diagnostics to \
            ~/.local/state/macup/scheduler.log.

            The agent runs as you, not as root, and `macup schedule disable` removes \
            it completely. Scheduled updating does not exist: the agent is only ever \
            allowed to run a check, so nothing MacUp installs can update a package \
            while you are not there. Run `macup update` yourself when you want a \
            change.
            """,
        subcommands: [ScheduleStatusCommand.self, ScheduleEnableCommand.self, ScheduleDisableCommand.self],
        defaultSubcommand: ScheduleStatusCommand.self
    )
}

// MARK: - status

struct ScheduleStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the scheduled check, when it next runs, and what it last found (read-only)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let status = await context.scheduler(paths: paths).status(loaded.configuration.schedule)

        if json {
            context.print(try JSONOutput.encode(ScheduleDocument(status)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(ScheduleRenderer(status: status, style: style).render())
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

// MARK: - enable

struct ScheduleEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Install the launchd agent that runs a read-only check on a schedule.",
        discussion: """
            Options you leave out keep their current value. Running this again \
            replaces the installed agent, so changing the time takes effect now \
            rather than at the next login.
            """
    )

    @Option(help: "How often to check: daily or weekly.")
    var frequency: MacUpConfiguration.ScheduleSettings.Frequency?

    @Option(help: "Local time to check, as 24-hour HH:mm, for example 23:00.")
    var time: String?

    @Option(help: "Day for a weekly check. Weekly defaults to Sunday.")
    var weekday: MacUpConfiguration.ScheduleSettings.Weekday?

    @Flag(
        inversion: .prefixedNo,
        help: "Refresh package metadata before checking. Without it a nightly check reads metadata that may be weeks old and reports almost nothing. A refresh never upgrades a package."
    )
    var refresh: Bool?

    func validate() throws {
        if let time {
            do {
                _ = try LaunchAgent.clockTime(time)
            } catch let error as MacUpError {
                throw ValidationError(error.message)
            }
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()

        // Fail closed: MacUp will not write to a configuration it could not
        // understand, because saving would discard whatever is in the file.
        if loaded.hasErrors {
            context.printError("error: MacUp will not change a configuration it cannot read.")
            for issue in loaded.issues where issue.severity == .error {
                let location = issue.path.isEmpty ? "" : TerminalText.sanitize(issue.path) + ": "
                context.printError("  \(location)\(TerminalText.sanitize(issue.message))")
            }
            context.printError("Fix \(PathDisplay.abbreviatingHome(loaded.path, homeDirectory: context.homeDirectory)) and try again.")
            throw MacUpExitCode.configurationInvalid.exitCode
        }

        let approval = await context.approval("change MacUp's scheduled check", loaded.configuration, paths: paths)
        guard approval.allowsChange else {
            context.printError("error: \(TerminalText.sanitize(approval.explanation ?? "MacUp did not get your approval."))")
            context.printError("Nothing was changed.")
            throw MacUpExitCode.notApproved.exitCode
        }

        var configuration = loaded.configuration
        if let frequency { configuration.schedule.frequency = frequency }
        if let time { configuration.schedule.time = time }
        if let weekday { configuration.schedule.weekday = weekday }
        if let refresh { configuration.schedule.refresh = refresh }
        configuration.schedule.enabled = true

        let scheduler = context.scheduler(paths: paths)
        let agent: LaunchAgent
        do {
            // Install first. If writing the configuration then fails, an
            // installed agent that is not recorded is easier to explain, and
            // to remove, than a recorded schedule that never runs.
            agent = try await scheduler.install(configuration.schedule)
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            if let suggestion = error.recoverySuggestion {
                context.printError(TerminalText.sanitize(suggestion))
            }
            throw MacUpExitCode.failure.exitCode
        }

        do {
            try store.save(configuration)
        } catch {
            let message = (error as? MacUpError)?.message ?? "The configuration could not be written."
            context.printError("error: \(TerminalText.sanitize(message))")
            context.printError("The agent is installed and will run. Use `macup schedule disable` to remove it.")
            throw MacUpExitCode.failure.exitCode
        }

        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        var lines = ["Scheduled check: \(configuration.schedule.summary)."]
        lines.append("  Runs: " + style.path(agent.invocation.displayString))
        if let next = agent.nextRun() {
            lines.append("  Next: " + ScheduleRenderer.dateText(next))
        }
        lines.append("  Agent: " + style.path(scheduler.agentPath))
        lines.append("This check is read-only. It will not install, upgrade, or remove anything.")
        lines.append("Turn it off with `macup schedule disable`.")
        context.print(lines.joined(separator: "\n"))
    }
}

// MARK: - disable

struct ScheduleDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Remove the scheduled check and its launchd agent."
    )

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()
        let scheduler = context.scheduler(paths: paths)

        let approval = await context.approval("turn off MacUp's scheduled check", loaded.configuration, paths: paths)
        guard approval.allowsChange else {
            context.printError("error: \(TerminalText.sanitize(approval.explanation ?? "MacUp did not get your approval."))")
            context.printError("Nothing was changed.")
            throw MacUpExitCode.notApproved.exitCode
        }

        var removed = false
        do {
            removed = try await scheduler.remove()
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            throw MacUpExitCode.failure.exitCode
        }

        var configurationCleared = false
        if loaded.configuration.schedule.enabled {
            if loaded.hasErrors {
                context.printError(
                    "warning: the configuration file has errors, so MacUp left it alone. The agent is removed."
                )
            } else {
                var configuration = loaded.configuration
                configuration.schedule.enabled = false
                do {
                    try store.save(configuration)
                    configurationCleared = true
                } catch {
                    let message = (error as? MacUpError)?.message ?? "The configuration could not be written."
                    context.printError("error: \(TerminalText.sanitize(message))")
                    throw MacUpExitCode.failure.exitCode
                }
            }
        }

        if removed || configurationCleared {
            context.print("Scheduled check removed. Nothing runs automatically.")
        } else {
            context.print("No scheduled check was installed. Nothing to remove.")
        }
    }
}

// MARK: - Output

/// The machine-readable form of `macup schedule status`.
struct ScheduleDocument: Encodable {
    let schemaVersion = 1
    let kind = "schedule"
    let status: ScheduleStatus

    init(_ status: ScheduleStatus) {
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, kind
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try status.encode(to: encoder)
    }
}

struct ScheduleRenderer {
    let status: ScheduleStatus
    let style: TextStyle

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func render() -> String {
        var lines: [String] = []
        lines.append(style.bold("Scheduled check") + " · " + state)
        lines.append("  When: \(status.schedule)")
        lines.append("  Runs: " + style.path(status.command))
        if status.agentInstalled, let next = status.nextRun {
            lines.append("  Next: " + Self.dateText(next))
        }
        lines.append("  Metadata refresh: " + (status.refreshesMetadata ? "yes" : "no"))
        if status.agentInstalled {
            lines.append("  Agent: " + style.path(status.agentPath))
            lines.append("  Log: " + style.path(status.logPath))
        }
        lines.append(contentsOf: lastCheckLines)
        for warning in status.warnings {
            lines.append("  warning: " + style.text(warning))
        }
        if !status.agentInstalled {
            lines.append("")
            lines.append("Turn it on with `macup schedule enable`, or choose a time: `macup schedule enable --time 09:00`.")
        }
        lines.append("")
        lines.append("A scheduled check is read-only. MacUp updates nothing on a schedule.")
        return lines.joined(separator: "\n")
    }

    private var state: String {
        if status.isActive { return "on" }
        if status.agentInstalled { return "installed, but not running" }
        return "off"
    }

    private var lastCheckLines: [String] {
        guard let last = status.lastCheck else { return [] }
        if last.unreadable {
            return ["  Last check: the saved report at \(style.path(last.path)) could not be read."]
        }
        var text = last.finishedAt.map(Self.dateText) ?? "at an unrecorded time"
        if let updates = last.updatesAvailable {
            text += " · " + TextStyle.plural(updates, "update") + " found"
        }
        if let errors = last.providersWithErrors, errors > 0 {
            text += " · " + TextStyle.plural(errors, "provider") + " failed"
        }
        return ["  Last check: " + text]
    }
}
