import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Scheduled-check launch agent")
struct LaunchAgentTests {
    typealias Settings = MacUpConfiguration.ScheduleSettings

    private func paths(_ home: String = "/Users/example") -> MacUpPaths {
        MacUpPaths.standard(homeDirectory: home)
    }

    private func propertyList(_ agent: LaunchAgent) throws -> [String: Any] {
        let data = try agent.propertyListData()
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(object as? [String: Any])
    }

    @Test("The agent runs a read-only check, and only that")
    func runsAReadOnlyCheck() throws {
        let agent = try LaunchAgent.scheduledCheck(
            settings: Settings(enabled: true, time: "23:00", refresh: true),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        let plist = try propertyList(agent)
        #expect(plist["Label"] as? String == "com.macup.check")
        #expect(
            plist["ProgramArguments"] as? [String]
                == ["/usr/local/bin/macup", "check", "--save-state", "--refresh"]
        )
        // No upgrade, install, or cleanup argument can appear: the agent only
        // ever runs `check`.
        let arguments = try #require(plist["ProgramArguments"] as? [String]).dropFirst()
        #expect(arguments.first == "check")
        #expect(!arguments.contains { ["update", "upgrade", "install", "cleanup"].contains($0) })
    }

    @Test("Enabling a schedule does not also run a check at every login")
    func doesNotRunAtLoad() throws {
        let agent = try LaunchAgent.scheduledCheck(settings: Settings(), executable: "/usr/local/bin/macup", paths: paths())
        let plist = try propertyList(agent)
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["StandardErrorPath"] as? String == "/Users/example/.local/state/macup/scheduler.log")
    }

    @Test("Daily runs every day; weekly names a day, defaulting to Sunday")
    func calendarIntervals() throws {
        let daily = try LaunchAgent.scheduledCheck(
            settings: Settings(frequency: .daily, time: "09:05"),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        let dailyInterval = try #require(try propertyList(daily)["StartCalendarInterval"] as? [String: Any])
        #expect(dailyInterval["Hour"] as? Int == 9)
        #expect(dailyInterval["Minute"] as? Int == 5)
        #expect(dailyInterval["Weekday"] == nil)

        let weekly = try LaunchAgent.scheduledCheck(
            settings: Settings(frequency: .weekly, time: "23:00", weekday: .wednesday),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        let weeklyInterval = try #require(try propertyList(weekly)["StartCalendarInterval"] as? [String: Any])
        #expect(weeklyInterval["Weekday"] as? Int == 3)

        let defaulted = try LaunchAgent.scheduledCheck(
            settings: Settings(frequency: .weekly, time: "23:00", weekday: nil),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        let defaultedInterval = try #require(try propertyList(defaulted)["StartCalendarInterval"] as? [String: Any])
        #expect(defaultedInterval["Weekday"] as? Int == 0)
        #expect(Settings(frequency: .weekly).summary == "every Sunday at 23:00")
    }

    @Test("Turning the refresh off removes the argument, and nothing else")
    func refreshIsOptional() throws {
        let agent = try LaunchAgent.scheduledCheck(
            settings: Settings(refresh: false),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        #expect(agent.invocation.arguments == ["check", "--save-state"])
    }

    @Test("Directory overrides travel with the agent; otherwise it carries no environment")
    func environmentOverrides() throws {
        let plain = try LaunchAgent.scheduledCheck(settings: Settings(), executable: "/usr/local/bin/macup", paths: paths())
        #expect(try propertyList(plain)["EnvironmentVariables"] == nil)

        let overridden = try MacUpPaths.resolve(
            homeDirectory: "/Users/example",
            environment: [MacUpPaths.stateDirectoryVariable: "/tmp/state"]
        )
        let agent = try LaunchAgent.scheduledCheck(settings: Settings(), executable: "/usr/local/bin/macup", paths: overridden)
        let environment = try #require(try propertyList(agent)["EnvironmentVariables"] as? [String: String])
        #expect(environment == [MacUpPaths.stateDirectoryVariable: "/tmp/state"])
    }

    @Test("A time MacUp cannot read is refused, not guessed at")
    func refusesUnreadableTimes() throws {
        for value in ["25:00", "9:00", "23:60", "23", "", "2300", "23:0o", "23:00 ", "١٢:٣٠"] {
            #expect(throws: MacUpError.self) { try LaunchAgent.clockTime(value) }
        }
        #expect(try LaunchAgent.clockTime("00:00") == (0, 0))
        #expect(try LaunchAgent.clockTime("23:59") == (23, 59))
    }

    @Test("A command MacUp cannot name absolutely is never scheduled")
    func refusesRelativeExecutables() {
        #expect(throws: MacUpError.self) {
            try LaunchAgent.scheduledCheck(settings: Settings(), executable: "macup", paths: paths())
        }
        #expect(throws: MacUpError.self) {
            try LaunchAgent.scheduledCheck(settings: Settings(), executable: "./macup", paths: paths())
        }
    }

    @Test("The next run is the next occurrence of the chosen time")
    func nextRun() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let agent = try LaunchAgent.scheduledCheck(
            settings: Settings(frequency: .weekly, time: "23:00", weekday: .monday),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        // Wednesday 2026-09-23, 10:00 local.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 10)))
        let next = try #require(agent.nextRun(after: now, calendar: calendar))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 28)  // the following Monday
        #expect(components.hour == 23)
        #expect(components.minute == 0)
    }

    @Test("An installed agent can be compared with the configuration")
    func comparesInstalledAgents() throws {
        let agent = try LaunchAgent.scheduledCheck(
            settings: Settings(time: "23:00"),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        #expect(agent.matches(installedPropertyList: try propertyList(agent)))

        let different = try LaunchAgent.scheduledCheck(
            settings: Settings(time: "07:30"),
            executable: "/usr/local/bin/macup",
            paths: paths()
        )
        #expect(!agent.matches(installedPropertyList: try propertyList(different)))
    }
}
