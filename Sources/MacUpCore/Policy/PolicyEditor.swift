/// What one policy edit changed, so a caller can say so instead of just
/// reporting success.
///
/// `previousValue` and `newValue` are display strings — a policy name,
/// `true`/`false` for a provider being on or off, a skipped version, or a
/// note — because that is what the CLI prints and what `--json` consumers
/// read. The caller already knows the type it asked for.
public struct PolicyChange: Sendable, Hashable, Codable {
    public enum Subject: Sendable, Hashable, Codable {
        case item(PackageID)
        case provider(ProviderID)
        /// The global default policy.
        case global

        /// Encoded as `{"kind": "item", "id": "brew:git"}` rather than through
        /// the synthesized shape, so `--json` has a name worth depending on.
        private enum CodingKeys: String, CodingKey {
            case kind
            case id
        }

        private enum Kind: String, Codable {
            case item
            case provider
            case global
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .item: self = .item(try container.decode(PackageID.self, forKey: .id))
            case .provider: self = .provider(try container.decode(ProviderID.self, forKey: .id))
            case .global: self = .global
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .item(let item):
                try container.encode(Kind.item, forKey: .kind)
                try container.encode(item, forKey: .id)
            case .provider(let provider):
                try container.encode(Kind.provider, forKey: .kind)
                try container.encode(provider, forKey: .id)
            case .global:
                try container.encode(Kind.global, forKey: .kind)
            }
        }
    }

    public enum Setting: String, Sendable, Hashable, Codable, CaseIterable {
        case policy
        case enabled
        /// The one version of an item to leave out of plans.
        case skipVersion
        /// The user's note on an item.
        case note
    }

    public var subject: Subject
    public var setting: Setting
    /// The value before the edit. `nil` when no rule was set.
    public var previousValue: String?
    /// The value after the edit. `nil` when the rule was removed.
    public var newValue: String?
    /// False when the configuration already said this, so nothing was written.
    public var changed: Bool
    /// Where the value lives in the file, such as `items.brew:git.policy`.
    public var path: String
    /// One display-safe sentence describing the result.
    public var summary: String
    /// Warnings the edit introduced, such as setting `auto` for macOS, which
    /// is accepted and stored but has no effect in this version.
    public var warnings: [String]

    public init(
        subject: Subject,
        setting: Setting,
        previousValue: String?,
        newValue: String?,
        changed: Bool,
        path: String,
        summary: String,
        warnings: [String] = []
    ) {
        self.subject = subject
        self.setting = setting
        self.previousValue = previousValue
        self.newValue = newValue
        self.changed = changed
        self.path = path
        self.summary = summary
        self.warnings = warnings
    }
}

/// The one place MacUp changes a policy.
///
/// `macup policy set`, `macup policy clear`, `macup policy skip|unskip`,
/// `macup policy note`, `macup provider enable`, `macup provider disable`,
/// and the app's Settings, Updates, and Dashboard screens all go through
/// this, so there is a single source of truth for what a policy edit is
/// allowed to do (CLAUDE.md §12).
///
/// Three rules shape it, and all three are refusals.
///
/// An edit validates the package ID through ``PackageID`` first, so a typo or
/// an unsupported ecosystem never reaches the file.
///
/// An edit refuses a configuration that has errors. MacUp writes the file by
/// re-encoding what it understood, so rewriting a file it misread could drop
/// the very exclusions the user is relying on; that is worse than refusing.
/// This is also what keeps keys MacUp does not know: an unrecognized key is an
/// error (docs/CONFIGURATION.md), so a file containing one is refused and left
/// exactly as it was, rather than silently losing the key on the way out.
/// Editing the JSON document in place was the alternative, and it is worse for
/// this schema: `JSONSerialization` re-prints the numbers it parsed, so a
/// hand-written `"faceMatchThreshold": 0.6` would come back as
/// `0.59999999999999998`. Refusing keeps both the unknown key and the user's
/// own formatting of everything else.
///
/// An edit refuses to introduce an error of its own: the result is validated
/// before it is written, so `pin` cannot land on a whole provider and the
/// global default cannot become `pin` or `inherit`, both of which would leave
/// the configuration in the state that disables automatic modification.
public struct PolicyEditor: Sendable {
    public var store: ConfigurationStore

    public init(store: ConfigurationStore) {
        self.store = store
    }

    public init(paths: MacUpPaths) {
        self.init(store: ConfigurationStore(paths: paths))
    }

    // MARK: Item policies

    /// Sets the rule for one item. A skipped version and a note on the item
    /// are kept: changing the rule is not a reason to forget either.
    @discardableResult
    public func setPolicy(_ policy: UpdatePolicy, for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .policy) { configuration in
            let previous = configuration.items[item.rawValue]?.policy
            var settings = configuration.items[item.rawValue] ?? MacUpConfiguration.ItemSettings(policy: policy)
            settings.policy = policy
            configuration.items[item.rawValue] = settings
            return (previous?.rawValue, policy.rawValue)
        }
    }

    /// Sets the rule for one item named as text, as the CLI receives it.
    ///
    /// Throws ``PackageID/ValidationError`` for anything that is not a package
    /// ID, without touching the file.
    @discardableResult
    public func setPolicy(_ policy: UpdatePolicy, forItem item: String) throws -> PolicyChange {
        try setPolicy(policy, for: try PackageID(parsing: item))
    }

    /// Removes the rule for one item, so it inherits again.
    ///
    /// Only the rule: a skipped version or a note stays, under an entry
    /// that says `inherit`, because clearing a rule should not quietly bring
    /// back a version the user skipped. With neither, the entry goes.
    @discardableResult
    public func clearPolicy(for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .policy) { configuration in
            guard var settings = configuration.items[item.rawValue] else { return (nil, nil) }
            let previous = settings.policy
            settings.policy = .inherit
            configuration.items[item.rawValue] = settings.isEmpty ? nil : settings
            return (previous.rawValue, nil)
        }
    }

    /// Removes the rule for one item named as text, as the CLI receives it.
    @discardableResult
    public func clearPolicy(forItem item: String) throws -> PolicyChange {
        try clearPolicy(for: try PackageID(parsing: item))
    }

    // MARK: Skipped versions

    /// Leaves one version of an item out of plans (`items.<id>.skipVersion`).
    ///
    /// The item keeps its rule, and a different version on offer brings it
    /// back under that rule. `version` is compared exactly with what the
    /// provider offers, so pass it as a check reported it. A second skip
    /// replaces the first: there is one skipped version per item.
    @discardableResult
    public func skipVersion(_ version: String, for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .skipVersion, warnings: { Self.skipWarnings(for: item, in: $0) }) { configuration in
            var settings = configuration.items[item.rawValue] ?? MacUpConfiguration.ItemSettings(policy: .inherit)
            let previous = settings.skipVersion
            settings.skipVersion = version
            configuration.items[item.rawValue] = settings
            return (previous, version)
        }
    }

    /// Stops skipping a version, so it follows the item's rule again.
    @discardableResult
    public func clearSkippedVersion(for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .skipVersion) { configuration in
            guard var settings = configuration.items[item.rawValue], let previous = settings.skipVersion else {
                return (nil, nil)
            }
            settings.skipVersion = nil
            configuration.items[item.rawValue] = settings.isEmpty ? nil : settings
            return (previous, nil)
        }
    }

    // MARK: Notes

    /// Stores the user's note on an item (`items.<id>.note`), exactly as
    /// given. Nothing MacUp decides reads it.
    @discardableResult
    public func setNote(_ note: String, for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .note) { configuration in
            var settings = configuration.items[item.rawValue] ?? MacUpConfiguration.ItemSettings(policy: .inherit)
            let previous = settings.note
            settings.note = note
            configuration.items[item.rawValue] = settings
            return (previous, note)
        }
    }

    /// Removes the note on an item.
    @discardableResult
    public func clearNote(for item: PackageID) throws -> PolicyChange {
        try apply(.item(item), .note) { configuration in
            guard var settings = configuration.items[item.rawValue], let previous = settings.note else {
                return (nil, nil)
            }
            settings.note = nil
            configuration.items[item.rawValue] = settings.isEmpty ? nil : settings
            return (previous, nil)
        }
    }

    /// A skip on an item a rule already holds does nothing until that rule
    /// changes. It is stored anyway — the user may be about to change the
    /// rule — and the change says so.
    private static func skipWarnings(for item: PackageID, in configuration: MacUpConfiguration) -> [String] {
        switch PolicyEngine(configuration: configuration).effectivePolicy(for: item).policy {
        case .ignore:
            ["\(item.rawValue) is ignored, so MacUp leaves every version of it alone; the skip matters only if that changes."]
        case .pin:
            ["\(item.rawValue) is pinned in MacUp, so it stays at its current version; the skip matters only if that changes."]
        case .auto, .ask, .inherit:
            []
        }
    }

    // MARK: Provider policies

    /// Sets the rule every item of one provider inherits.
    ///
    /// A provider the file does not mention already has a value — the built-in
    /// default — so this reports that value rather than "not set", and writes
    /// nothing when it is what was asked for.
    @discardableResult
    public func setPolicy(_ policy: UpdatePolicy, for provider: ProviderID) throws -> PolicyChange {
        try apply(.provider(provider), .policy) { configuration in
            var settings = configuration.settings(for: provider)
            let previous = settings.policy
            guard previous != policy else { return (previous.rawValue, policy.rawValue) }
            settings.policy = policy
            configuration.providers[provider.rawValue] = settings
            return (previous.rawValue, policy.rawValue)
        }
    }

    /// Turns a provider on or off. A provider that is off is never run and
    /// never proposes an update.
    @discardableResult
    public func setProviderEnabled(_ enabled: Bool, for provider: ProviderID) throws -> PolicyChange {
        try apply(.provider(provider), .enabled) { configuration in
            var settings = configuration.settings(for: provider)
            let previous = settings.enabled
            guard previous != enabled else { return (String(previous), String(enabled)) }
            settings.enabled = enabled
            configuration.providers[provider.rawValue] = settings
            return (String(previous), String(enabled))
        }
    }

    // MARK: Global default

    /// Sets the policy that applies when no provider or item rule does.
    @discardableResult
    public func setDefaultPolicy(_ policy: UpdatePolicy) throws -> PolicyChange {
        try apply(.global, .policy) { configuration in
            let previous = configuration.global.defaultPolicy
            configuration.global.defaultPolicy = policy
            return (previous.rawValue, policy.rawValue)
        }
    }

    // MARK: Writing

    /// Loads, checks, mutates, re-checks, and writes — the only path that
    /// changes a policy, so every rule above is enforced exactly once.
    /// `extraWarnings` reads the edited configuration, for warnings that are
    /// about what the edit means rather than about a value in the file.
    private func apply(
        _ subject: PolicyChange.Subject,
        _ setting: PolicyChange.Setting,
        warnings extraWarnings: (MacUpConfiguration) -> [String] = { _ in [] },
        _ mutate: (inout MacUpConfiguration) -> (previous: String?, new: String?)
    ) throws -> PolicyChange {
        let loaded = store.load()
        guard !loaded.hasErrors else { throw Self.unreadable(loaded) }

        var configuration = loaded.configuration
        let (previous, new) = mutate(&configuration)
        let path = Self.path(subject, setting)
        let changed = configuration != loaded.configuration

        var warnings: [String] = []
        if changed {
            let issues = ConfigurationValidator.semanticIssues(in: configuration)
            // Any error here is one this edit would introduce: the
            // configuration on disk had none, or it would have been refused
            // above.
            let errors = issues.filter { $0.severity == .error }
            guard errors.isEmpty else { throw Self.wouldBreak(errors, path: path) }
            warnings = issues
                .filter { $0.severity == .warning && $0.path.hasPrefix(path) }
                .map(\.message) + extraWarnings(configuration)

            // A file MacUp read at an older schema version has been upgraded
            // in memory, and writing the edit would persist that upgrade. Back
            // the original up first, which is the promise persistMigration
            // makes (docs/CONFIGURATION.md).
            if loaded.migratedFromSchemaVersion != nil {
                try store.persistMigration(of: loaded)
            }
            try store.save(configuration)
        }

        return PolicyChange(
            subject: subject,
            setting: setting,
            previousValue: previous,
            newValue: new,
            changed: changed,
            path: path,
            summary: Self.summary(subject, setting, previous: previous, new: new, changed: changed),
            warnings: warnings
        )
    }

    private static func path(_ subject: PolicyChange.Subject, _ setting: PolicyChange.Setting) -> String {
        switch subject {
        case .item(let item): "items.\(item.rawValue).\(setting.rawValue)"
        case .provider(let provider): "providers.\(provider.rawValue).\(setting.rawValue)"
        case .global: "global.defaultPolicy"
        }
    }

    private static func summary(
        _ subject: PolicyChange.Subject,
        _ setting: PolicyChange.Setting,
        previous: String?,
        new: String?,
        changed: Bool
    ) -> String {
        // A package ID is already checked, but a provider ID is whatever the
        // caller built, and this sentence is printed.
        let name: String
        switch subject {
        case .item(let item): name = item.rawValue
        case .provider(let provider): name = TerminalText.sanitize(provider.displayName)
        case .global: name = "The default policy"
        }

        // Both are the user's own text, so they are sanitized for display.
        let previousText = previous.map(TerminalText.sanitize)
        let newText = new.map(TerminalText.sanitize)
        switch (setting, changed, previousText, newText) {
        case (.skipVersion, false, _, nil):
            return "\(name) skips no version, so there was nothing to stop skipping."
        case (.skipVersion, false, _, let version?):
            return "\(name) already skips \(version); nothing was changed."
        case (.skipVersion, true, let version?, nil):
            return "\(name) no longer skips \(version), so that version follows the item's rule again."
        case (.skipVersion, true, let replaced?, let version?):
            return "\(name) now skips \(version) instead of \(replaced)."
        case (.skipVersion, true, nil, let version?):
            return "\(name) now skips \(version). MacUp will leave that version alone and offer the next one."
        case (.note, false, _, nil):
            return "\(name) has no note, so there was nothing to remove."
        case (.note, false, _, _?):
            return "\(name) already has this note; nothing was changed."
        case (.note, true, _?, nil):
            return "\(name) no longer has a note."
        case (.note, true, _?, let note?):
            return "\(name)'s note is now \"\(note)\"."
        case (.note, true, nil, let note?):
            return "\(name) now has a note: \"\(note)\"."
        default:
            // A policy or a provider switch, described below.
            break
        }

        guard changed else {
            if new == nil {
                return "No rule was set for \(name), so there was nothing to clear."
            }
            return "\(name) is already \(display(new, setting: setting)); nothing was changed."
        }
        if new == nil {
            return "\(name) no longer has a rule of its own and inherits again "
                + "(it was \(display(previous, setting: setting)))."
        }
        guard let previous else {
            return "\(name) is now \(display(new, setting: setting))."
        }
        return "\(name): \(display(previous, setting: setting)) → \(display(new, setting: setting))."
    }

    /// The value as a person reads it: policies have display names, and a
    /// provider is on or off rather than true or false.
    private static func display(_ value: String?, setting: PolicyChange.Setting) -> String {
        guard let value else { return "not set" }
        switch setting {
        case .policy:
            return UpdatePolicy(rawValue: value)?.displayName ?? value
        case .enabled:
            return value == "true" ? "enabled" : "disabled"
        case .skipVersion, .note:
            return TerminalText.sanitize(value)
        }
    }

    private static func unreadable(_ loaded: LoadedConfiguration) -> MacUpError {
        MacUpError(
            .configurationInvalid,
            "MacUp did not change anything because it could not read every rule in \(loaded.path). "
                + "Writing the file back would replace the rules it misread, which could drop items you excluded.",
            detail: detail(loaded.issues.filter { $0.severity == .error }),
            recoverySuggestion: "Fix the problems listed above, which `macup config show` also reports, and try again."
        )
    }

    private static func wouldBreak(_ errors: [ConfigurationIssue], path: String) -> MacUpError {
        MacUpError(
            .configurationInvalid,
            "MacUp did not change \(TerminalText.sanitize(path)) because the result would be a configuration it refuses to use.",
            detail: detail(errors)
        )
    }

    private static func detail(_ issues: [ConfigurationIssue]) -> String {
        issues
            .map { $0.path.isEmpty ? "- \($0.message)" : "- \(TerminalText.sanitize($0.path)): \($0.message)" }
            .joined(separator: "\n")
    }
}
