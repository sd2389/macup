import ArgumentParser
import MacUpCore

struct MacUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macup",
        abstract: "Understand, review, and maintain your Mac development environment.",
        discussion: """
            MacUp checks Homebrew, npm (global packages), mise, and macOS for updates, \
            shows you exactly what it would run, and applies the ones you allow.

            One command changes packages: `macup update`. It shows the plan first, \
            asks about anything set to Ask First, runs one item at a time, and records \
            what happened. A few commands change MacUp's own configuration file and no \
            packages: `macup policy set|clear|skip|unskip|note` (and `macup exclude`), \
            `macup provider enable|disable`, `macup schedule enable|disable`, and `macup \
            security require`. Everything else — including plain `macup` — only reads.

            Examples:
              macup                   See what is outdated
              macup plan              See exactly what an update would run
              macup explain brew:git  Everything MacUp knows about one item
              macup update --dry-run  The same, launching nothing
              macup update            Apply what your policy allows
              macup update brew:git   Apply one item
              macup policy list       What MacUp may do with each item
              macup exclude brew:postgresql   Never update this one
              macup doctor            What is odd about this Mac
              macup history           What MacUp has changed
              macup security          Ask for Touch ID before MacUp changes anything
            """,
        version: MacUp.version,
        subcommands: [
            CheckCommand.self,
            PlanCommand.self,
            ExplainCommand.self,
            UpdateCommand.self,
            PolicyCommand.self,
            ExcludeCommand.self,
            ProviderCommand.self,
            DoctorCommand.self,
            HistoryCommand.self,
            ConfigCommand.self,
            ScheduleCommand.self,
            SecurityCommand.self,
        ],
        defaultSubcommand: CheckCommand.self
    )
}
