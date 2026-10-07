import Foundation

/// Compares the schedule the configuration asks for with what launchd
/// actually has installed (CLAUDE.md §13, §15).
///
/// The two drift apart easily: editing the configuration by hand does not
/// install anything, and removing the configuration does not unload an agent.
/// Either way the user believes something is happening that is not, which is
/// the worst kind of silence for a maintenance tool. The findings come from
/// ``ScheduleStatus``'s structured fields rather than its display warnings, so
/// their identifiers are stable enough for scripts to match on.
public struct ScheduleCheck: DiagnosticCheck {
    public let id = "schedule.agent"
    public let title = "Whether the scheduled check is really installed"

    public init() {}

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        // Nothing was read about scheduling, so there is nothing to compare.
        guard let schedule = input.schedule else { return [] }
        var findings: [DiagnosticFinding] = []

        if schedule.enabledInConfiguration && !schedule.agentInstalled {
            findings.append(DiagnosticFinding(
                id: "schedule.notInstalled",
                severity: .error,
                provider: nil,
                title: "Scheduled checks are turned on, but nothing is installed to run them",
                detail: "The configuration asks for a check \(input.display(schedule.schedule)), "
                    + "and there is no launchd agent at \(input.display(schedule.agentPath)).",
                recommendation: "Run `macup schedule enable` to install the agent, "
                    + "or turn scheduling off so the configuration matches the machine.",
                fix: DiagnosticFix(
                    action: .installScheduleAgent,
                    summary: "Install the scheduled run the configuration asks for",
                    detail: "Writes \(input.display(schedule.agentPath)) and loads it with launchd. "
                        + "It will run: \(input.display(schedule.command))."
                )
            ))
        }

        if !schedule.enabledInConfiguration && schedule.agentInstalled {
            findings.append(DiagnosticFinding(
                id: "schedule.installedWhileDisabled",
                severity: .warning,
                provider: nil,
                title: "A scheduled check is installed while the configuration has scheduling off",
                detail: "The agent at \(input.display(schedule.agentPath)) is still there and launchd may run it.",
                recommendation: "Run `macup schedule disable` to unload and remove it.",
                fix: DiagnosticFix(
                    action: .removeScheduleAgent,
                    summary: "Remove the agent the configuration no longer asks for",
                    detail: "Unloads \(input.display(schedule.label)) from launchd and deletes "
                        + "\(input.display(schedule.agentPath)). Nothing else is changed."
                )
            ))
        }

        guard schedule.agentInstalled else { return findings }

        if schedule.agentLoaded == false {
            findings.append(DiagnosticFinding(
                id: "schedule.notLoaded",
                severity: .warning,
                provider: nil,
                title: "launchd has not loaded the scheduled check",
                detail: "The agent exists at \(input.display(schedule.agentPath)), "
                    + "but launchd does not know about \(input.display(schedule.label)), so nothing runs until you log in again.",
                recommendation: "Run `macup schedule enable` to load it now.",
                fix: DiagnosticFix(
                    action: .installScheduleAgent,
                    summary: "Load the scheduled run with launchd",
                    detail: "Writes \(input.display(schedule.agentPath)) again and loads it. "
                        + "It will run: \(input.display(schedule.command))."
                )
            ))
        }
        if schedule.agentLoaded == nil {
            findings.append(DiagnosticFinding(
                id: "schedule.stateUnknown",
                severity: .info,
                provider: nil,
                title: "MacUp could not ask launchd about the scheduled check",
                detail: "The agent exists at \(input.display(schedule.agentPath)); "
                    + "whether launchd has it loaded is unknown.",
                recommendation: "MacUp reports this as unknown rather than assuming the check is running."
            ))
        }
        if schedule.agentMatchesConfiguration == false {
            findings.append(DiagnosticFinding(
                id: "schedule.doesNotMatchConfiguration",
                severity: .warning,
                provider: nil,
                title: "The installed scheduled check does not match the configuration",
                detail: "The configuration asks for a check \(input.display(schedule.schedule)); "
                    + "the agent at \(input.display(schedule.agentPath)) was installed with different settings.",
                recommendation: "Run `macup schedule enable` to replace the agent with the current settings.",
                fix: DiagnosticFix(
                    action: .installScheduleAgent,
                    summary: "Replace the agent with what the configuration says",
                    detail: "Writes \(input.display(schedule.agentPath)) from the current settings and loads it. "
                        + "It will run: \(input.display(schedule.command))."
                )
            ))
        }
        if !schedule.executableExists {
            findings.append(DiagnosticFinding(
                id: "schedule.commandMissing",
                severity: .error,
                provider: nil,
                title: "The scheduled check points at a command that is gone",
                detail: "The agent runs \(input.display(schedule.executablePath)), which is no longer an executable file.",
                recommendation: "Reinstall macup, then run `macup schedule enable` so the agent points at the new location."
            ))
        }
        return findings
    }
}
