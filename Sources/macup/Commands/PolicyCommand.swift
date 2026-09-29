import ArgumentParser
import Foundation
import MacUpCore

extension UpdatePolicy: ExpressibleByArgument {}

struct PolicyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Read and change what MacUp may do with each item.",
        discussion: """
            A policy is one of Auto Update, Ask First, Ignore, or Pin. The rule for an \
            item wins over the rule for its provider, which wins over the default. An \
            item can also skip one version, and keep a note saying why it is held. \
            `macup policy list` reads; `set`, `clear`, `skip`, `unskip`, and `note` \
            change MacUp's own configuration file and no packages.

            Policy is the only thing standing between `macup update` and an item you \
            do not want touched, so MacUp is careful with it: it refuses to write a \
            configuration file it could not read completely, and refuses an edit whose \
            result it would not accept.
            """,
        subcommands: [
            PolicyListCommand.self, PolicySetCommand.self, PolicyClearCommand.self,
            PolicySkipCommand.self, PolicyUnskipCommand.self, PolicyNoteCommand.self,
        ],
        defaultSubcommand: PolicyListCommand.self,
        aliases: ["policies"]
    )
}

// MARK: - list

struct PolicyListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Show every policy rule and where it lives in the file (read-only)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let listing = PolicyListing(loaded)

        if json {
            context.print(try JSONOutput.encode(PolicyListDocument(listing)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            context.print(PolicyRenderer(listing: listing, style: style).render())
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

// MARK: - set

struct PolicySetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set the policy for one item, one provider, or the default.",
        discussion: """
            The target is a package ID such as brew:git or npm:@scope/name, a provider \
            name (homebrew, npm, mise, macos), or the word default for the rule \
            everything else falls back to.

            Setting a value that is already set changes nothing and says so. A provider \
            cannot be pinned and the default cannot be pin or inherit, because MacUp \
            would then refuse to use the configuration it had just written.

            Examples:
              macup policy set brew:postgresql ignore
              macup policy set npm:@anthropic-ai/claude-code ask
              macup policy set homebrew auto
              macup policy set default ask
            """
    )

    @Argument(help: "A package ID, a provider name, or default.")
    var target: String

    @Argument(help: "auto, ask, ignore, pin, or inherit.")
    var policy: UpdatePolicy

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        _ = try PolicyTarget(parsing: target)
    }

    func run() async throws {
        let subject = try PolicyTarget(parsing: target)
        try await PolicyEditing.apply(json: json) { editor in
            switch subject {
            case .item(let item): return try editor.setPolicy(policy, for: item)
            case .provider(let provider): return try editor.setPolicy(policy, for: provider)
            case .global: return try editor.setDefaultPolicy(policy)
            }
        }
    }
}

// MARK: - clear

struct PolicyClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove a rule so the item or provider inherits again.",
        discussion: """
            An item with no rule of its own follows its provider's rule; a provider set \
            to inherit follows the default. The default itself always has a value, so \
            change it with `macup policy set default ask` rather than clearing it.
            """
    )

    @Argument(help: "One or more package IDs, or provider names.")
    var targets: [String]

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        guard !targets.isEmpty else { throw ValidationError("Name at least one package ID or provider to clear.") }
        for target in targets {
            let subject = try PolicyTarget(parsing: target)
            if case .global = subject {
                throw ValidationError(
                    "The default policy always has a value. Set it with `macup policy set default ask` instead."
                )
            }
        }
    }

    func run() async throws {
        let subjects = try targets.map { try PolicyTarget(parsing: $0) }
        try await PolicyEditing.applyEach(json: json) { editor in
            try subjects.map { subject in
                switch subject {
                case .item(let item): return try editor.clearPolicy(for: item)
                // A provider always has a value, so "clear" means stop
                // deciding for this provider and fall through to the default.
                case .provider(let provider): return try editor.setPolicy(.inherit, for: provider)
                case .global: return try editor.setDefaultPolicy(.ask)
                }
            }
        }
    }
}

// MARK: - exclude

struct ExcludeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exclude",
        abstract: "Shorthand for `macup policy set <package-id> ignore`.",
        discussion: """
            An excluded item is never updated and never proposed. This writes the same \
            rule to the same place as `macup policy set … ignore`; there is one policy \
            source of truth and this is a shorter way to reach it.
            """
    )

    @Argument(help: "One or more package IDs, or provider names.")
    var targets: [String]

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func validate() throws {
        guard !targets.isEmpty else { throw ValidationError("Name at least one package ID to exclude.") }
        for target in targets {
            let subject = try PolicyTarget(parsing: target)
            if case .global = subject {
                throw ValidationError(
                    "Excluding everything is not what you want. Turn off a provider with `macup provider disable <id>`."
                )
            }
        }
    }

    func run() async throws {
        let subjects = try targets.map { try PolicyTarget(parsing: $0) }
        try await PolicyEditing.applyEach(json: json) { editor in
            try subjects.map { subject in
                switch subject {
                case .item(let item): return try editor.setPolicy(.ignore, for: item)
                case .provider(let provider): return try editor.setPolicy(.ignore, for: provider)
                case .global: return try editor.setDefaultPolicy(.ignore)
                }
            }
        }
    }
}

// MARK: - Targets

/// What a policy argument refers to.
///
/// A package ID always carries its namespace and therefore a colon, and a
/// provider name never does, so the two can never be confused for each other.
enum PolicyTarget {
    case item(PackageID)
    case provider(ProviderID)
    case global

    init(parsing value: String) throws {
        if value == "default" || value == "global" {
            self = .global
            return
        }
        if !value.contains(":") {
            let provider = ProviderID(rawValue: value)
            guard provider.isKnown else {
                throw ValidationError(
                    "'\(TerminalText.sanitize(value))' is not a package ID, a provider, or default. "
                        + "A package ID looks like brew:git. Known providers: "
                        + ProviderID.known.map(\.rawValue).joined(separator: ", ") + "."
                )
            }
            self = .provider(provider)
            return
        }
        do {
            self = .item(try PackageID(parsing: value))
        } catch let error as PackageID.ValidationError {
            throw ValidationError(error.description)
        }
    }
}

// MARK: - Writing

/// The one path every policy edit in the CLI takes.
///
/// `policy set|clear|skip|unskip|note`, `exclude`, and `provider
/// enable|disable` all come through here, so the configuration is checked, the device owner is
/// asked, and the result is reported the same way for all of them. The edit
/// itself is always ``PolicyEditor``'s: the CLI never writes the
/// configuration file.
enum PolicyEditing {
    /// `action` completes the approval prompt, "MacUp is trying to …".
    static func apply(
        json: Bool,
        approving action: String = "change what MacUp may update",
        _ edit: (PolicyEditor) throws -> PolicyChange
    ) async throws {
        try await applyEach(json: json, approving: action) { editor in [try edit(editor)] }
    }

    static func applyEach(
        json: Bool,
        approving action: String = "change what MacUp may update",
        _ edit: (PolicyEditor) throws -> [PolicyChange]
    ) async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()
        try context.requireReadableConfiguration(loaded)
        try await context.requireApproval(action, loaded.configuration, paths: paths)

        let changes: [PolicyChange]
        do {
            changes = try edit(PolicyEditor(store: store))
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            if let detail = error.detail {
                for line in detail.split(separator: "\n") {
                    context.printError("  " + TerminalText.sanitize(String(line)))
                }
            }
            if let suggestion = error.recoverySuggestion {
                context.printError(TerminalText.sanitize(suggestion))
            }
            throw MacUpExitCode.configurationInvalid.exitCode
        }

        if json {
            context.print(try JSONOutput.encode(PolicyChangeDocument(changes, path: loaded.path)))
            return
        }

        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        for change in changes {
            context.print(style.text(change.summary))
            for warning in change.warnings {
                context.print("  warning: " + style.text(warning))
            }
            // The same words the app shows beside a pinned item.
            if change.changed, change.setting == .policy, change.newValue == UpdatePolicy.pin.rawValue {
                context.print("  Pin is MacUp's own hold. It does not pin the item in its package manager, so running that tool yourself can still update it.")
            }
        }
        if changes.contains(where: \.changed) {
            context.print(style.dim("Saved to " + style.path(loaded.path) + "."))
            // A note changes nothing a plan decides, so there is nothing to go and look at.
            if changes.contains(where: { $0.changed && $0.setting != .note }) {
                context.print(style.dim("`macup plan` shows what this means for the updates available now."))
            }
        }
    }
}

// MARK: - Output

/// Human-readable output for `macup policy list`.
struct PolicyRenderer {
    let listing: PolicyListing
    let style: TextStyle

    func render() -> String {
        var lines = [style.bold("Policies")]
        if let file = listing.configurationFile {
            lines[0] += style.dim(" · " + style.path(file))
        }
        if !listing.automaticModificationsAllowed {
            lines.append("The configuration has errors, so MacUp will change nothing until they are fixed. "
                + "The rules below are only what it could still read.")
        }

        lines.append("")
        lines.append("Default: " + style.bold(listing.defaultPolicy.displayName) + style.dim("  global.defaultPolicy"))
        lines.append("  " + style.dim(listing.confirmMajorUpdates
            ? "A major version change still waits for you, even on an item set to Auto Update."
            : "A major version change of an ordinary package does not wait for you."))

        lines.append("")
        lines.append(style.bold("Providers"))
        let nameWidth = listing.providers.map(\.provider.displayName.count).max() ?? 0
        let policyWidth = listing.providers.map { effective($0).count }.max() ?? 0
        for rule in listing.providers {
            var line = "  " + TextStyle.pad(style.safe(rule.provider.displayName), to: nameWidth)
                + "  " + TextStyle.pad(rule.enabled ? "enabled" : "disabled", to: 8)
                + "  " + TextStyle.pad(effective(rule), to: policyWidth)
                + "  " + style.dim(style.safe(rule.path))
            if !rule.explicit { line += style.dim("  (not in the file; MacUp's default)") }
            lines.append(line)
        }

        lines.append("")
        if listing.items.isEmpty {
            lines.append(style.bold("Items") + style.dim(" · no rules of their own"))
        } else {
            lines.append(style.bold("Items") + style.dim(" · " + TextStyle.plural(listing.items.count, "rule")))
            let idWidth = listing.items.map { style.safe($0.item.rawValue).count }.max() ?? 0
            let itemPolicyWidth = listing.items.map { effective($0).count }.max() ?? 0
            // A skipped version and a note sit under the item's own line.
            let indent = String(repeating: " ", count: idWidth + 4)
            for rule in listing.items {
                lines.append("  " + TextStyle.pad(style.safe(rule.item.rawValue), to: idWidth)
                    + "  " + TextStyle.pad(effective(rule), to: itemPolicyWidth)
                    + "  " + style.dim(style.safe(rule.path)))
                if let version = rule.skipVersion {
                    lines.append(indent + "Skips " + style.safe(version)
                        + style.dim("  " + style.safe("items.\(rule.item.rawValue).skipVersion")))
                }
                if let note = rule.note {
                    lines.append(indent + "Note: " + style.safe(note))
                }
            }
        }
        for key in listing.unreadableItemKeys {
            lines.append("  " + style.safe(key) + "  " + "not a package ID, so MacUp ignores this rule")
        }

        lines.append("")
        if listing.isDefault {
            lines.append("Nothing is customized: every provider is on and everything is \(listing.defaultPolicy.displayName).")
        }
        lines.append("Change one with `macup policy set <package-id> <auto|ask|ignore|pin>`.")
        lines.append(style.dim("Skip one version with `macup policy skip <package-id>`; "
            + "keep a note with `macup policy note <package-id> \"…\"`."))
        return lines.joined(separator: "\n")
    }

    /// The policy as written, and what it resolves to when that differs, so a
    /// listing never hides an inherited answer behind the word "inherit".
    private func effective(_ rule: PolicyListing.ProviderRule) -> String {
        Self.effective(written: rule.policy, resolved: rule.effectivePolicy)
    }

    private func effective(_ rule: PolicyListing.ItemRule) -> String {
        Self.effective(written: rule.policy, resolved: rule.effectivePolicy)
    }

    private static func effective(written: UpdatePolicy, resolved: UpdatePolicy) -> String {
        written == resolved
            ? written.displayName
            : written.displayName + " → " + resolved.displayName
    }
}

/// The machine-readable form of `macup policy list`.
struct PolicyListDocument: Encodable {
    let schemaVersion = 1
    let kind = "policyList"
    let macupVersion = MacUp.version
    let listing: PolicyListing

    init(_ listing: PolicyListing) {
        self.listing = listing
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, macupVersion
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(macupVersion, forKey: .macupVersion)
        try listing.encode(to: encoder)
    }
}

/// The machine-readable form of a policy edit.
struct PolicyChangeDocument: Encodable {
    let schemaVersion = 1
    let kind = "policyChange"
    let macupVersion = MacUp.version
    let configurationFile: String
    let changes: [PolicyChange]

    init(_ changes: [PolicyChange], path: String) {
        self.changes = changes
        self.configurationFile = path
    }
}
