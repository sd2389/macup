import Foundation

/// The launchd user agent that runs MacUp on a schedule.
///
/// The agent is a per-user LaunchAgent, never a privileged daemon, and it
/// runs one of exactly two commands (ADR-023):
///
/// - `macup check --save-state`, which cannot modify anything, and is what a
///   schedule runs unless the person turned installing on;
/// - `macup update --scheduled`, which installs only the updates whose rule
///   is Auto Update, refuses anything that may ask for a password or need a
///   restart, and records every attempt and every skip.
///
/// `scripts/check-trust-invariants.sh` fails the build if any other command
/// shape appears here. Everything about the agent is derived here so the
/// property list on disk and what `macup schedule status` reports come from
/// one place.
public struct LaunchAgent: Sendable, Hashable {
    /// The launchd service label. Stable: `macup schedule disable` and any
    /// manual `launchctl` cleanup depend on it.
    public static let label = "com.macup.check"
    public static let fileName = label + ".plist"

    /// When launchd should start the job. launchd fires a missed calendar job
    /// once after the Mac wakes, so a machine asleep at the chosen time still
    /// checks.
    public struct CalendarInterval: Sendable, Hashable {
        public var hour: Int
        public var minute: Int
        /// launchd's weekday numbering: 0 is Sunday … 6 is Saturday.
        /// `nil` runs every day.
        public var weekday: Int?

        public init(hour: Int, minute: Int, weekday: Int? = nil) {
            self.hour = hour
            self.minute = minute
            self.weekday = weekday
        }
    }

    public var label: String
    /// The exact executable and argument array launchd runs. Stored as a
    /// ``CommandInvocation`` so the plist and the human-readable command come
    /// from the same value and cannot disagree.
    public var invocation: CommandInvocation
    public var calendarInterval: CalendarInterval
    public var standardErrorPath: String
    public var environmentVariables: [String: String]

    public init(
        label: String = LaunchAgent.label,
        invocation: CommandInvocation,
        calendarInterval: CalendarInterval,
        standardErrorPath: String,
        environmentVariables: [String: String] = [:]
    ) {
        self.label = label
        self.invocation = invocation
        self.calendarInterval = calendarInterval
        self.standardErrorPath = standardErrorPath
        self.environmentVariables = environmentVariables
    }

    /// Builds the agent for a scheduled run: a read-only check, or an
    /// Auto-Update-only run when the configuration says to install.
    ///
    /// - Parameter executable: absolute path of the `macup` binary to schedule.
    public static func scheduledCheck(
        settings: MacUpConfiguration.ScheduleSettings,
        executable: String,
        paths: MacUpPaths
    ) throws -> LaunchAgent {
        guard executable.hasPrefix("/") else {
            throw MacUpError(
                .configurationInvalid,
                "MacUp could not determine its own absolute path, so it will not schedule anything.",
                recoverySuggestion: "Install macup to a fixed location (for example `make install`) and try again."
            )
        }
        let time = try clockTime(settings.time)
        var arguments = settings.installsAutoUpdates ? ["update", "--scheduled"] : ["check", "--save-state"]
        if settings.refresh { arguments.append("--refresh") }

        var environment: [String: String] = [:]
        if paths.configDirectorySource == .environment {
            environment[MacUpPaths.configDirectoryVariable] = paths.configDirectory
        }
        if paths.stateDirectorySource == .environment {
            environment[MacUpPaths.stateDirectoryVariable] = paths.stateDirectory
        }
        if paths.launchAgentsDirectorySource == .environment {
            environment[MacUpPaths.launchAgentsDirectoryVariable] = paths.launchAgentsDirectory
        }

        return LaunchAgent(
            invocation: CommandInvocation(executable: executable, arguments: arguments),
            calendarInterval: CalendarInterval(
                hour: time.hour,
                minute: time.minute,
                weekday: settings.frequency == .weekly ? launchdWeekday(settings.resolvedWeekday) : nil
            ),
            standardErrorPath: paths.schedulerLogFile,
            environmentVariables: environment
        )
    }

    /// Parses `HH:mm` without guessing: anything else is refused.
    public static func clockTime(_ value: String) throws -> (hour: Int, minute: Int) {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else {
            throw MacUpError(
                .configurationInvalid,
                "schedule.time must be 24-hour HH:mm, for example 23:00; found '\(TerminalText.sanitize(value))'."
            )
        }
        return (hour, minute)
    }

    public static func launchdWeekday(_ weekday: MacUpConfiguration.ScheduleSettings.Weekday) -> Int {
        switch weekday {
        case .sunday: return 0
        case .monday: return 1
        case .tuesday: return 2
        case .wednesday: return 3
        case .thursday: return 4
        case .friday: return 5
        case .saturday: return 6
        }
    }

    /// The property list launchd reads, as a dictionary. Kept separate from
    /// the serialized form so an installed agent can be compared with the one
    /// the current configuration describes.
    public var propertyList: [String: Any] {
        var interval: [String: Any] = ["Hour": calendarInterval.hour, "Minute": calendarInterval.minute]
        if let weekday = calendarInterval.weekday { interval["Weekday"] = weekday }

        var plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [invocation.executable] + invocation.arguments,
            "StartCalendarInterval": interval,
            // Login is not a schedule. Without this, enabling a nightly check
            // would also run one on every login.
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            // The check writes its report itself; stdout would only duplicate it.
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": standardErrorPath,
        ]
        if !environmentVariables.isEmpty { plist["EnvironmentVariables"] = environmentVariables }
        return plist
    }

    /// The property list launchd reads. Written as XML so a person can open
    /// the file and see exactly what was installed.
    public func propertyListData() throws -> Data {
        do {
            return try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        } catch {
            throw MacUpError(.configurationInvalid, "MacUp could not build the launchd property list.")
        }
    }

    /// Whether an already-installed property list describes this same agent.
    public func matches(installedPropertyList other: [String: Any]) -> Bool {
        NSDictionary(dictionary: propertyList).isEqual(to: other)
    }

    /// The next time launchd would start the job, for display only.
    /// `nil` when the calendar cannot produce one.
    public func nextRun(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = calendarInterval.hour
        components.minute = calendarInterval.minute
        components.second = 0
        // DateComponents counts weekdays from 1 for Sunday; launchd counts from 0.
        if let weekday = calendarInterval.weekday { components.weekday = weekday + 1 }
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}

extension MacUpConfiguration.ScheduleSettings {
    /// The weekday a weekly schedule uses, including the documented default
    /// when the configuration does not name one.
    public var resolvedWeekday: Weekday { weekday ?? Self.defaultWeekday }

    /// A short human description, for example "every day at 23:00".
    public var summary: String {
        switch frequency {
        case .daily: return "every day at \(time)"
        case .weekly: return "every \(resolvedWeekday.rawValue.capitalized) at \(time)"
        }
    }
}
