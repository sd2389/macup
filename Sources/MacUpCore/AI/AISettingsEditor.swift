import Foundation

/// What turning AI help on or off changed.
public struct AISettingsChange: Sendable, Hashable, Codable {
    public var previousValue: Bool
    public var newValue: Bool
    /// False when the configuration already said this, so nothing was written.
    public var changed: Bool
    public var path: String
    public var summary: String

    public init(previousValue: Bool, newValue: Bool, changed: Bool, summary: String) {
        self.previousValue = previousValue
        self.newValue = newValue
        self.changed = changed
        path = "ai.enabled"
        self.summary = summary
    }
}

/// Changes the `ai` section, with the same refusals as ``PolicyEditor``: it
/// will not rewrite a configuration it could not read, and it will not write
/// one it would then refuse to use. Writes go through
/// ``ConfigurationStore/save(_:)``, so they are atomic and owner-only.
///
/// Turning AI help off leaves no `ai` section behind when the rest of it is
/// the default, so the file goes back to the shape it had before.
public struct AISettingsEditor: Sendable {
    public var store: ConfigurationStore

    public init(store: ConfigurationStore) {
        self.store = store
    }

    public init(paths: MacUpPaths) {
        self.init(store: ConfigurationStore(paths: paths))
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) throws -> AISettingsChange {
        let loaded = store.load()
        guard !loaded.hasErrors else {
            throw MacUpError(
                .configurationInvalid,
                "MacUp did not change AI help because it could not read every setting in \(loaded.path). "
                    + "While the file has errors, AI help stays off.",
                detail: loaded.issues
                    .filter { $0.severity == .error }
                    .map { $0.path.isEmpty ? "- \($0.message)" : "- \(TerminalText.sanitize($0.path)): \($0.message)" }
                    .joined(separator: "\n"),
                recoverySuggestion: "Fix the problems listed above, which `macup config show` also reports, and try again."
            )
        }

        var configuration = loaded.configuration
        let previous = configuration.aiSettings.enabled
        guard previous != enabled else {
            return AISettingsChange(
                previousValue: previous,
                newValue: enabled,
                changed: false,
                summary: enabled ? "AI help is already on; nothing was changed." : "AI help is already off; nothing was changed."
            )
        }

        var settings = configuration.aiSettings
        settings.enabled = enabled
        configuration.ai = settings == MacUpConfiguration.AISettings() ? nil : settings

        let errors = ConfigurationValidator.semanticIssues(in: configuration).filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw MacUpError(
                .configurationInvalid,
                "MacUp did not change ai.enabled because the result would be a configuration it refuses to use.",
                detail: errors.map { "- \(TerminalText.sanitize($0.path)): \($0.message)" }.joined(separator: "\n")
            )
        }
        if loaded.migratedFromSchemaVersion != nil {
            try store.persistMigration(of: loaded)
        }
        try store.save(configuration)
        return AISettingsChange(
            previousValue: previous,
            newValue: enabled,
            changed: true,
            summary: enabled
                ? "AI help from TypeSafe is on. Nothing has been sent; MacUp asks TypeSafe only when you ask it something."
                : "AI help from TypeSafe is off. MacUp sends nothing to TypeSafe."
        )
    }
}
