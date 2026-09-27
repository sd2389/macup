import ArgumentParser
import MacUpCore

struct MacUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macup",
        abstract: "Understand, review, and maintain your Mac development environment.",
        discussion: """
            MacUp checks Homebrew, npm (global packages), mise, and macOS for updates \
            and tells you what is outdated. This version is read-only: it never \
            installs, upgrades, or removes anything.

            Examples:
              macup                   See what is outdated
              macup check --verbose   Also see who manages each item and why
              macup check --json      Machine-readable output for scripts
              macup providers         Which installation of each tool MacUp uses
              macup config            The settings MacUp is using
              macup schedule          Whether MacUp checks automatically
            """,
        version: MacUp.version,
        subcommands: [CheckCommand.self, ProviderCommand.self, ConfigCommand.self, ScheduleCommand.self],
        defaultSubcommand: CheckCommand.self
    )
}
