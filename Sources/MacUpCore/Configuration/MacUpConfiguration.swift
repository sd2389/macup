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
    public var security: SecuritySettings

    public init(
        schemaVersion: Int = MacUpConfiguration.currentSchemaVersion,
        global: GlobalSettings = GlobalSettings(),
        providers: [String: ProviderSettings] = [:],
        items: [String: ItemSettings] = [:],
        schedule: ScheduleSettings = ScheduleSettings(),
        privacy: PrivacySettings = PrivacySettings(),
        security: SecuritySettings = SecuritySettings()
    ) {
        self.schemaVersion = schemaVersion
        self.global = global
        self.providers = providers
        self.items = items
        self.schedule = schedule
        self.privacy = privacy
        self.security = security
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

    /// Whether MacUp asks the device owner to confirm before it changes
    /// anything.
    ///
    /// This is a confirmation, not a security boundary: MacUp runs as you, so
    /// anyone at an unlocked Mac can run the package managers directly. What
    /// it does buy is a deliberate step in front of every change MacUp makes,
    /// in the app and in the CLI alike.
    public struct SecuritySettings: Sendable, Hashable, Codable {
        /// Ask before MacUp changes anything (today: the schedule).
        public var requireApproval: Bool
        /// Let the login password, or an unlocked Apple Watch, stand in when
        /// the sensor is unavailable. Without it, a Mac with no biometric
        /// sensor could never approve a change.
        public var allowPasswordFallback: Bool
        /// Let MacUp's own camera face match approve a change, as a shortcut
        /// before the macOS prompt. Off by default: it compares how alike two
        /// pictures look, so a photograph of the enrolled person passes.
        public var faceUnlock: Bool
        /// How close a live picture must be to an enrolled one. Smaller is
        /// stricter. There is no principled value; see `FaceComparator`.
        public var faceMatchThreshold: Double

        /// Written as a decimal so the value people read in the file and in
        /// `--json` is the value they set, not a binary-float neighbour of it.
        public static let defaultFaceMatchThreshold = 0.6

        public init(
            requireApproval: Bool = false,
            allowPasswordFallback: Bool = true,
            faceUnlock: Bool = false,
            faceMatchThreshold: Double = MacUpConfiguration.SecuritySettings.defaultFaceMatchThreshold
        ) {
            self.requireApproval = requireApproval
            self.allowPasswordFallback = allowPasswordFallback
            self.faceUnlock = faceUnlock
            self.faceMatchThreshold = faceMatchThreshold
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            requireApproval = try container.decodeIfPresent(Bool.self, forKey: .requireApproval) ?? false
            allowPasswordFallback = try container.decodeIfPresent(Bool.self, forKey: .allowPasswordFallback) ?? true
            faceUnlock = try container.decodeIfPresent(Bool.self, forKey: .faceUnlock) ?? false
            faceMatchThreshold = try container.decodeIfPresent(Double.self, forKey: .faceMatchThreshold)
                ?? Self.defaultFaceMatchThreshold
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, global, providers, items, schedule, privacy, security
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        global = try container.decodeIfPresent(GlobalSettings.self, forKey: .global) ?? GlobalSettings()
        providers = try container.decodeIfPresent([String: ProviderSettings].self, forKey: .providers) ?? [:]
        items = try container.decodeIfPresent([String: ItemSettings].self, forKey: .items) ?? [:]
        schedule = try container.decodeIfPresent(ScheduleSettings.self, forKey: .schedule) ?? ScheduleSettings()
        privacy = try container.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? PrivacySettings()
        security = try container.decodeIfPresent(SecuritySettings.self, forKey: .security) ?? SecuritySettings()
    }
}
