/// MacUp's configuration file, schema version 1 (CLAUDE.md §14).
///
/// Missing sections take conservative defaults. Unknown keys and invalid
/// values are reported by ``ConfigurationValidator`` and disable automatic
/// modification; they are never silently reinterpreted.
public struct MacUpConfiguration: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var global: GlobalSettings
    /// Keyed by provider ID (`homebrew`, `npm`, `mise`, `macos`).
    public var providers: [String: ProviderSettings]
    /// Keyed by package ID (`brew:git`, `npm:@scope/name`, ...).
    public var items: [String: ItemSettings]
    public var schedule: ScheduleSettings
    public var privacy: PrivacySettings

    public init(
        schemaVersion: Int = MacUpConfiguration.currentSchemaVersion,
        global: GlobalSettings = GlobalSettings(),
        providers: [String: ProviderSettings] = [:],
        items: [String: ItemSettings] = [:],
        schedule: ScheduleSettings = ScheduleSettings(),
        privacy: PrivacySettings = PrivacySettings()
    ) {
        self.schemaVersion = schemaVersion
        self.global = global
        self.providers = providers
        self.items = items
        self.schedule = schedule
        self.privacy = privacy
    }

    /// Used when no configuration file exists: every provider enabled,
    /// everything Ask First, scheduling off, no telemetry.
    public static let defaults = MacUpConfiguration(
        providers: Dictionary(uniqueKeysWithValues: ProviderID.known.map { ($0.rawValue, ProviderSettings()) })
    )

    public func settings(for provider: ProviderID) -> ProviderSettings {
        providers[provider.rawValue] ?? ProviderSettings()
    }

    public struct GlobalSettings: Sendable, Hashable, Codable {
        public var defaultPolicy: UpdatePolicy
        public var confirmMajorUpdates: Bool

        public init(defaultPolicy: UpdatePolicy = .ask, confirmMajorUpdates: Bool = true) {
            self.defaultPolicy = defaultPolicy
            self.confirmMajorUpdates = confirmMajorUpdates
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            defaultPolicy = try container.decodeIfPresent(UpdatePolicy.self, forKey: .defaultPolicy) ?? .ask
            confirmMajorUpdates = try container.decodeIfPresent(Bool.self, forKey: .confirmMajorUpdates) ?? true
        }
    }

    public struct ProviderSettings: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var policy: UpdatePolicy
        /// Explicit executable to use instead of searching. Absolute path only.
        public var executablePath: String?

        public init(enabled: Bool = true, policy: UpdatePolicy = .inherit, executablePath: String? = nil) {
            self.enabled = enabled
            self.policy = policy
            self.executablePath = executablePath
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            policy = try container.decodeIfPresent(UpdatePolicy.self, forKey: .policy) ?? .inherit
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        }
    }

    public struct ItemSettings: Sendable, Hashable, Codable {
        public var policy: UpdatePolicy

        public init(policy: UpdatePolicy) {
            self.policy = policy
        }
    }

    public struct ScheduleSettings: Sendable, Hashable, Codable {
        public enum Frequency: String, Sendable, Hashable, Codable, CaseIterable {
            case daily
            case weekly
        }

        public enum Weekday: String, Sendable, Hashable, Codable, CaseIterable {
            case monday, tuesday, wednesday, thursday, friday, saturday, sunday
        }

        public var enabled: Bool
        public var frequency: Frequency
        /// Local time as `HH:mm` (24-hour).
        public var time: String
        public var weekday: Weekday?
        /// Whether a scheduled check refreshes provider metadata first.
        /// Without it `brew outdated` reads metadata that may be weeks old,
        /// so a nightly check would report almost nothing. A refresh updates
        /// package lists only; it never upgrades an installed package.
        public var refresh: Bool

        public init(
            enabled: Bool = false,
            frequency: Frequency = .daily,
            time: String = "23:00",
            weekday: Weekday? = nil,
            refresh: Bool = true
        ) {
            self.enabled = enabled
            self.frequency = frequency
            self.time = time
            self.weekday = weekday
            self.refresh = refresh
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            frequency = try container.decodeIfPresent(Frequency.self, forKey: .frequency) ?? .daily
            time = try container.decodeIfPresent(String.self, forKey: .time) ?? "23:00"
            weekday = try container.decodeIfPresent(Weekday.self, forKey: .weekday)
            refresh = try container.decodeIfPresent(Bool.self, forKey: .refresh) ?? true
        }

        /// The day a weekly schedule runs when the configuration does not name
        /// one. Stated here rather than left implicit, and shown by
        /// `macup schedule status`.
        public static let defaultWeekday = Weekday.sunday
    }

    public struct PrivacySettings: Sendable, Hashable, Codable {
        public var telemetry: Bool

        public init(telemetry: Bool = false) {
            self.telemetry = telemetry
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            telemetry = try container.decodeIfPresent(Bool.self, forKey: .telemetry) ?? false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, global, providers, items, schedule, privacy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        global = try container.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? GlobalSettings()
        providers = try container.decodeIfPresent([String: ProviderSettings].self, forKey: .providers) ?? [:]
        items = try container.decodeIfPresent([String: ItemSettings].self, forKey: .items) ?? [:]
        schedule = try container.decodeIfPresent(ScheduleSettings.self, forKey: .schedule) ?? ScheduleSettings()
        privacy = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? PrivacySettings()
    }
}
