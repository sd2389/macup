import ArgumentParser
import Foundation
import MacUpCore

// MARK: - skip

struct PolicySkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Leave one version of an item out of plans until a different one is offered.",
        discussion: """
            Skipping is Ignore for one version. While that exact version is the one on \
            offer, MacUp leaves the item alone, even one set to Auto Update. When a \
            different version is offered, the item follows its rule again and there is \
            nothing to undo. An item that is ignored or pinned stays that way.

            Without --version, MacUp runs a read-only check of the item's provider and \
            skips the version it finds on offer. With --version, it skips the version \
            you name, compared exactly as the provider writes it: 26.7.0 does not skip \
            26.7.0_2.

            This changes MacUp's own configuration file and no packages.

            Examples:
              macup policy skip brew:mysql
              macup policy skip npm:typescript --version 6.0.0
            """
    )

    @Argument(help: "A package ID, for example brew:mysql.")
    var item: String

    @Option(help: "The version to skip, exactly as `macup check` shows it. Default: the version on offer now.")
    var version: String?

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        _ = try ItemArgument.parse(item)
        if let version, let problem = MacUpConfiguration.ItemSettings.problem(withSkipVersion: version) {
            throw ValidationError(problem)
        }
    }

    func run() async throws {
        let item = try ItemArgument.parse(self.item)
        let version: String
        if let named = self.version {
            version = named
        } else {
            version = try await OfferedVersion.find(item, json: json)
        }
        try await PolicyEditing.apply(json: json, approving: "skip \(item.rawValue) \(TerminalText.sanitize(version))") { editor in
            try editor.skipVersion(version, for: item)
        }
    }
}

// MARK: - unskip

struct PolicyUnskipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unskip",
        abstract: "Stop skipping a version, so it follows the item's rule again.",
        discussion: """
            An item keeps at most one skipped version, and it stops mattering by itself \
            once a different version is offered, so this is only needed to take back a \
            skip while that version is still the one on offer.
            """
    )

    @Argument(help: "One or more package IDs.")
    var items: [String]

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        guard !items.isEmpty else { throw ValidationError("Name at least one package ID to stop skipping.") }
        for item in items { _ = try ItemArgument.parse(item) }
    }

    func run() async throws {
        let items = try self.items.map(ItemArgument.parse)
        try await PolicyEditing.applyEach(json: json) { editor in
            try items.map { try editor.clearSkippedVersion(for: $0) }
        }
    }
}

// MARK: - note

struct PolicyNoteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Keep a short note on an item, such as why it is held, or remove it.",
        discussion: """
            The note is yours. MacUp stores it exactly as you wrote it, shows it beside \
            the item in `macup policy list`, `macup check`, `macup plan`, and the app, \
            and never acts on it. A note is one line of up to \
            \(MacUpConfiguration.ItemSettings.maximumNoteLength) characters.

            Examples:
              macup policy note brew:php "waiting for PHP 8.4 support"
              macup policy note brew:php --clear
            """
    )

    @Argument(help: "A package ID, for example brew:php.")
    var item: String

    @Argument(help: "The note, in quotes. Leave it out with --clear.")
    var text: String?

    @Flag(help: "Remove the note.")
    var clear = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        _ = try ItemArgument.parse(item)
        switch (text, clear) {
        case (nil, false):
            throw ValidationError("Give the note to keep, in quotes, or --clear to remove it.")
        case (.some, true):
            throw ValidationError("Give a note or --clear, not both.")
        case (let text?, false):
            if let problem = MacUpConfiguration.ItemSettings.problem(withNote: text) {
                throw ValidationError(problem)
            }
        case (nil, true):
            break
        }
    }

    func run() async throws {
        let item = try ItemArgument.parse(self.item)
        try await PolicyEditing.apply(json: json, approving: "change the note on \(item.rawValue)") { editor in
            if let text { return try editor.setNote(text, for: item) }
            return try editor.clearNote(for: item)
        }
    }
}

// MARK: - Support

/// An argument that has to name one item. A skipped version and a note
/// belong to a single item, never to a provider or the default.
enum ItemArgument {
    static func parse(_ value: String) throws -> PackageID {
        do {
            return try PackageID(parsing: value)
        } catch let error as PackageID.ValidationError {
            throw ValidationError(error.description)
        }
    }
}

/// The version of one item a read-only check finds on offer, for `macup
/// policy skip` without `--version`.
///
/// Only the item's own provider is checked. When nothing is on offer, MacUp
/// says why and skips nothing: guessing a version would store a skip that
/// might never match, or match the wrong thing.
enum OfferedVersion {
    static func find(_ item: PackageID, json: Bool) async throws -> String {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        // The edit would be refused anyway, so refuse before checking anything.
        try context.requireReadableConfiguration(loaded)

        let provider = item.provider.displayName
        if !json {
            context.printError("Checking \(provider) for the version of \(item.rawValue) on offer. Nothing is changed.")
        }
        let engine = context.engine
        let environment = context.checkEnvironment
        let report = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await engine.run(
                configuration: loaded,
                options: CheckOptions(providers: [item.provider]),
                environment: environment
            )
        }
        if report.cancelled { throw MacUpExitCode.cancelled.exitCode }
        if let candidate = report.updates.first(where: { $0.id == item }) {
            let version = candidate.availableVersion.raw
            // Provider output is untrusted. A version the configuration could
            // not hold is refused here, before anyone is asked to approve it.
            if let problem = MacUpConfiguration.ItemSettings.problem(withSkipVersion: version) {
                context.printError("error: MacUp cannot skip the version \(provider) offers for \(item.rawValue). \(problem)")
                throw MacUpExitCode.configurationInvalid.exitCode
            }
            return version
        }

        let checked = report.providers.first { $0.provider == item.provider }
        if checked?.availability == .disabled {
            context.printError("error: \(provider) is turned off in MacUp, so it cannot see which version of \(item.rawValue) is on offer.")
            context.printError("Turn it on with `macup provider enable \(item.provider.rawValue)`, or name the version with --version.")
            throw MacUpExitCode.usage.exitCode
        }
        if checked?.availability == .unavailable {
            context.printError("error: MacUp could not find \(provider) on this Mac, so no version of \(item.rawValue) is on offer.")
            context.printError("To skip a version anyway, name it with --version.")
            throw MacUpExitCode.usage.exitCode
        }
        if checked == nil || checked?.hasErrors == true || checked?.resultsIncomplete == true {
            context.printError("error: MacUp could not finish checking \(provider), so it does not know which version of \(item.rawValue) is on offer.")
            context.printError("`macup check --verbose` shows what went wrong. To skip a version anyway, name it with --version.")
            throw MacUpExitCode.providerErrors.exitCode
        }
        context.printError("error: " + PackageSelection.unmatchedMessage([item]))
        context.printError("To skip a version before it is offered, name it with --version.")
        throw MacUpExitCode.usage.exitCode
    }
}
