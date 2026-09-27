import ArgumentParser
import Foundation
import MacUpCore

struct SecurityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "security",
        abstract: "Ask for Touch ID (or whatever this Mac has) before MacUp changes anything.",
        discussion: """
            MacUp can require the device owner's approval before it makes a change. \
            macOS asks, using whatever this Mac has: Touch ID, Face ID or Optic ID \
            on hardware that has them, with your login password or an unlocked Apple \
            Watch as the fallback. MacUp never sees your fingerprint, your face, or \
            your password; it asks macOS a yes-or-no question and is told yes or no.

            Be clear about what this is: a confirmation, not a lock. MacUp runs as \
            you, so anyone at your unlocked Mac can run brew, npm, or mise directly \
            without it. What it buys is a deliberate step in front of every change \
            MacUp itself makes, in the app and here alike.

            Today the only change MacUp can make is the scheduled check. The \
            execution engine uses the same gate when it arrives.
            """,
        subcommands: [SecurityStatusCommand.self, SecurityRequireCommand.self, SecurityFaceCommand.self],
        defaultSubcommand: SecurityStatusCommand.self
    )
}

struct SecurityStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show what this Mac can ask for, and whether MacUp asks (read-only)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        let settings = loaded.configuration.security
        let capability = ApprovalGate(settings: settings, authorizer: context.authorizer).capability

        if json {
            context.print(try JSONOutput.encode(SecurityDocument(settings: settings, capability: capability)))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            var lines = [style.bold("Approval") + " · " + (settings.requireApproval ? "required before MacUp changes anything" : "not required")]
            lines.append("  This Mac: \(capability.kind.displayName)" + (capability.isAvailable ? ", ready" : ", not available"))
            if let reason = capability.unavailableReason {
                lines.append("  " + style.text(reason))
            }
            lines.append("  Password or Apple Watch fallback: " + (settings.allowPasswordFallback ? (capability.hasFallback ? "allowed" : "allowed, but macOS cannot use it right now") : "not allowed"))
            if settings.requireApproval && !capability.isAvailable && !(settings.allowPasswordFallback && capability.hasFallback) {
                lines.append("  " + style.text("MacUp cannot ask you anything right now, so it will refuse to change the schedule. Edit the configuration file to turn approval off."))
            }
            lines.append("")
            lines.append(settings.requireApproval
                ? "Turn it off with `macup security require off`."
                : "Turn it on with `macup security require on`.")
            lines.append("This is a confirmation, not a lock: MacUp runs as you, and so do brew, npm, and mise.")
            context.print(lines.joined(separator: "\n"))
        }
        if loaded.hasErrors { throw MacUpExitCode.configurationInvalid.exitCode }
    }
}

struct SecurityRequireCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "require",
        abstract: "Turn the approval requirement on or off.",
        discussion: """
            Turning it off needs the same approval as any other change, when it is \
            currently on. If this Mac can no longer ask you at all, edit the \
            configuration file directly: it is your file, and MacUp never locks you \
            out of it.
            """
    )

    enum State: String, ExpressibleByArgument, CaseIterable {
        case on, off
    }

    @Argument(help: "on or off.")
    var state: State

    @Flag(
        inversion: .prefixedNo,
        help: "Allow your login password or an unlocked Apple Watch to stand in when the sensor cannot be used."
    )
    var passwordFallback: Bool?

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()

        if loaded.hasErrors {
            context.printError("error: MacUp will not change a configuration it cannot read.")
            for issue in loaded.issues where issue.severity == .error {
                let location = issue.path.isEmpty ? "" : TerminalText.sanitize(issue.path) + ": "
                context.printError("  \(location)\(TerminalText.sanitize(issue.message))")
            }
            throw MacUpExitCode.configurationInvalid.exitCode
        }

        // Changing this setting is itself a change, so it goes through the gate
        // that is in force now, not the one being asked for.
        let approval = await context.approval("change when MacUp asks for your approval", loaded.configuration, paths: paths)
        guard approval.allowsChange else {
            context.printError("error: \(TerminalText.sanitize(approval.explanation ?? "MacUp did not get your approval."))")
            context.printError("Nothing was changed.")
            throw MacUpExitCode.notApproved.exitCode
        }

        var configuration = loaded.configuration
        configuration.security.requireApproval = state == .on
        if let passwordFallback { configuration.security.allowPasswordFallback = passwordFallback }

        let capability = ApprovalGate(settings: configuration.security, authorizer: context.authorizer).capability
        let canAsk = capability.isAvailable || (configuration.security.allowPasswordFallback && capability.hasFallback)
        if configuration.security.requireApproval && !canAsk {
            context.printError("error: this Mac cannot ask you to confirm right now, so requiring approval would stop MacUp changing anything.")
            if let reason = capability.unavailableReason {
                context.printError("  " + TerminalText.sanitize(reason))
            }
            throw MacUpExitCode.notApproved.exitCode
        }

        do {
            try store.save(configuration)
        } catch {
            let message = (error as? MacUpError)?.message ?? "The configuration could not be written."
            context.printError("error: \(TerminalText.sanitize(message))")
            throw MacUpExitCode.failure.exitCode
        }

        if configuration.security.requireApproval {
            context.print("MacUp will ask for \(capability.kind == .none ? "your approval" : capability.kind.displayName) before it changes anything.")
        } else {
            context.print("MacUp will not ask for approval before it changes anything.")
        }
    }
}

/// The machine-readable form of `macup security status`.
struct SecurityDocument: Encodable {
    let schemaVersion = 1
    let kind = "security"
    let requireApproval: Bool
    let allowPasswordFallback: Bool
    let biometry: String
    let biometryDisplayName: String
    let biometricsAvailable: Bool
    let fallbackAvailable: Bool
    let unavailableReason: String?

    init(settings: MacUpConfiguration.SecuritySettings, capability: BiometricCapability) {
        requireApproval = settings.requireApproval
        allowPasswordFallback = settings.allowPasswordFallback
        biometry = capability.kind.rawValue
        biometryDisplayName = capability.kind.displayName
        biometricsAvailable = capability.isAvailable
        fallbackAvailable = capability.hasFallback
        unavailableReason = capability.unavailableReason
    }
}
