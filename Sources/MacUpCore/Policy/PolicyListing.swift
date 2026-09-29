/// Every policy rule the configuration sets, in a stable order.
///
/// This is what `macup policy list` prints and what the app's Settings screen
/// shows. It reports the rules as written, not what they would decide for a
/// particular update: ``PolicyEngine/decide(_:intent:)`` does that, because
/// risk is part of the answer and a listing has no candidate to judge.
///
/// Nothing here reads or writes a file. Build one from a
/// ``LoadedConfiguration`` the caller already has.
public struct PolicyListing: Sendable, Hashable, Codable {
    /// A rule the user set for one item.
    public struct ItemRule: Sendable, Hashable, Codable, Identifiable {
        public var item: PackageID
        /// The policy as written. May be `inherit`, which the user is allowed
        /// to state explicitly.
        public var policy: UpdatePolicy
        /// What the rule resolves to once `inherit` is followed.
        public var effectivePolicy: UpdatePolicy
        /// Where the rule lives in the file, such as `items.brew:git.policy`.
        public var path: String
        public var source: PolicyDecision.Source
        /// The one version the user skipped, as written. Whether it is the
        /// version on offer now takes a check to say; see ``skips(_:)``.
        public var skipVersion: String?
        /// The user's note on the item, verbatim.
        public var note: String?

        public init(
            item: PackageID,
            policy: UpdatePolicy,
            effectivePolicy: UpdatePolicy,
            skipVersion: String? = nil,
            note: String? = nil
        ) {
            self.item = item
            self.policy = policy
            self.effectivePolicy = effectivePolicy
            self.path = "items.\(item.rawValue).policy"
            self.source = .item
            self.skipVersion = skipVersion
            self.note = note
        }

        public var id: PackageID { item }
        public var provider: ProviderID { item.provider }

        /// Whether `offered` is the version this rule skips, compared the way
        /// the engine compares it.
        public func skips(_ offered: AvailableVersion) -> Bool {
            MacUpConfiguration.ItemSettings(policy: policy, skipVersion: skipVersion).skips(offered)
        }
    }

    /// One provider's rule. Every known provider appears, whether or not the
    /// file mentions it, so a caller can show the whole set without inventing
    /// the defaults itself.
    public struct ProviderRule: Sendable, Hashable, Codable, Identifiable {
        public var provider: ProviderID
        public var enabled: Bool
        /// The policy as written. `inherit` means this provider's items fall
        /// through to the global default.
        public var policy: UpdatePolicy
        /// What this provider's items get when no per-item rule applies.
        public var effectivePolicy: UpdatePolicy
        /// True when the configuration has a section for this provider; false
        /// when this row is the built-in default for a provider the
        /// configuration does not mention.
        public var explicit: Bool
        /// Where the rule lives in the file, such as `providers.npm`.
        public var path: String
        public var source: PolicyDecision.Source

        public init(
            provider: ProviderID,
            enabled: Bool,
            policy: UpdatePolicy,
            effectivePolicy: UpdatePolicy,
            explicit: Bool
        ) {
            self.provider = provider
            self.enabled = enabled
            self.policy = policy
            self.effectivePolicy = effectivePolicy
            self.explicit = explicit
            self.path = "providers.\(provider.rawValue)"
            self.source = .provider
        }

        public var id: ProviderID { provider }
    }

    /// The global default, which applies when nothing more specific does.
    /// This is the policy in effect, so a file that says `inherit` — which has
    /// nothing above it to inherit from, and which the validator rejects —
    /// reports as `ask`, the same answer the engine gives.
    public var defaultPolicy: UpdatePolicy
    /// Whether a major version change of an ordinary package waits for
    /// confirmation even when the item is set to update automatically.
    public var confirmMajorUpdates: Bool
    /// Known providers in display order, then any other provider the file
    /// names, so the order does not change between runs.
    public var providers: [ProviderRule]
    /// Item rules sorted by package ID.
    public var items: [ItemRule]
    /// Keys under `items` that are not package IDs, kept so a listing never
    /// drops a rule silently. They are display-safe; the errors that explain
    /// them come from ``ConfigurationValidator``.
    public var unreadableItemKeys: [String]
    /// False when the configuration has errors. The rules below are then
    /// whatever MacUp could still read, and none of them permit a change.
    public var automaticModificationsAllowed: Bool
    /// The file these rules came from, when the caller knows it.
    public var configurationFile: String?

    public init(
        configuration: MacUpConfiguration,
        automaticModificationsAllowed: Bool = true,
        configurationFile: String? = nil
    ) {
        // The engine resolves precedence, so a listing can never disagree with
        // the decision the user will actually get.
        let engine = PolicyEngine(configuration: configuration)
        let fallback = configuration.global.defaultPolicy == .inherit
            ? UpdatePolicy.ask
            : configuration.global.defaultPolicy
        defaultPolicy = fallback
        confirmMajorUpdates = configuration.global.confirmMajorUpdates
        self.automaticModificationsAllowed = automaticModificationsAllowed
        self.configurationFile = configurationFile

        let named = configuration.providers.keys.map { ProviderID(rawValue: $0) }
        providers = Set(ProviderID.known + named).sorted().map { provider in
            let settings = configuration.providers[provider.rawValue]
            let policy = settings?.policy ?? MacUpConfiguration.ProviderSettings().policy
            return ProviderRule(
                provider: provider,
                enabled: settings?.enabled ?? MacUpConfiguration.ProviderSettings().enabled,
                policy: policy,
                effectivePolicy: policy == .inherit ? fallback : policy,
                explicit: settings != nil
            )
        }

        var rules: [ItemRule] = []
        var unreadable: [String] = []
        for (key, settings) in configuration.items {
            guard let item = try? PackageID(parsing: key) else {
                unreadable.append(TerminalText.sanitize(key))
                continue
            }
            rules.append(ItemRule(
                item: item,
                policy: settings.policy,
                effectivePolicy: engine.effectivePolicy(for: item).policy,
                skipVersion: settings.skipVersion,
                note: settings.note
            ))
        }
        items = rules.sorted { $0.item < $1.item }
        unreadableItemKeys = unreadable.sorted()
    }

    public init(_ loaded: LoadedConfiguration) {
        self.init(
            configuration: loaded.configuration,
            automaticModificationsAllowed: loaded.allowsAutomaticModification,
            configurationFile: loaded.path
        )
    }

    /// True when nothing is customized: no item rules, and every provider
    /// enabled and inheriting.
    public var isDefault: Bool {
        items.isEmpty
            && unreadableItemKeys.isEmpty
            && providers.allSatisfy { $0.enabled && $0.policy == .inherit }
    }

    public func rule(for provider: ProviderID) -> ProviderRule? {
        providers.first { $0.provider == provider }
    }

    public func rule(for item: PackageID) -> ItemRule? {
        items.first { $0.item == item }
    }
}
