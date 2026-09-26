import ArgumentParser
import MacUpCore

struct MacUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macup",
        abstract: "Understand, review, and maintain your Mac development environment.",
        discussion: """
            MacUp is conservative with changes and aggressive with information. It \
            orchestrates the package managers you already use and never changes anything \
            you did not authorize. This version is read-only: running `macup` with no \
            subcommand performs `macup check`.
            """,
        version: MacUp.version,
        subcommands: [CheckCommand.self, ProviderCommand.self, ConfigCommand.self],
        defaultSubcommand: CheckCommand.self
    )
}
