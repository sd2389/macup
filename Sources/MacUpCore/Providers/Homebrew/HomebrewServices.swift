import Foundation

/// One formula's entry in `brew services list --json`.
struct HomebrewService: Sendable, Hashable {
    /// Homebrew's own word for it: `started`, `scheduled`, `stopped`,
    /// `none`, `error`, `unknown`, or `other`. `none` means it is not
    /// registered with launchd at all.
    var status: String
    /// The last exit code launchd recorded, when Homebrew reports one.
    var exitCode: Int32?
    /// Registered for the whole Mac rather than for this user, so restarting
    /// it takes `sudo`.
    var runsAsRoot: Bool
}

/// What MacUp learned from `brew services list --json`, or why it learned
/// nothing.
enum HomebrewServiceReading: Sendable, Hashable {
    /// Service state by formula name, the names whose entries MacUp could
    /// not read, and what it noticed along the way.
    case listed(services: [String: HomebrewService], unreadable: Set<String>, findings: [DiagnosticFinding])
    /// No usable answer. `ran` is false when MacUp chose not to ask at all.
    case unavailable(reason: String, ran: Bool)
}

/// Parses `brew services list --json` (confirmed against Homebrew 7.0.6):
///
/// ```json
/// [{"name": "mysql", "status": "started", "user": "example",
///   "file": "/Users/example/Library/LaunchAgents/homebrew.mxcl.mysql.plist", "exit_code": null}]
/// ```
///
/// Homebrew lists every installed formula that defines a service, whether
/// or not it is registered, and prints `[]` when there are none. `name` is
/// the formula's short name, even for a formula from another tap. Only
/// `name`, `status`, `user`, and `exit_code` are read.
enum HomebrewServicesParser {
    static let statuses: Set<String> = ["started", "scheduled", "stopped", "none", "error", "unknown", "other"]

    static func parse(_ data: Data, command: String? = nil) throws -> HomebrewServiceReading {
        guard let document = JSONValue.parse(data) else {
            throw MacUpError.parseFailed("Homebrew's list of services was not valid JSON.", command: command)
        }
        guard let entries = document.arrayValue else {
            throw MacUpError.parseFailed("Homebrew's list of services was not the list MacUp expected.", command: command)
        }

        var services: [String: HomebrewService] = [:]
        var unreadable: Set<String> = []
        var findings: [DiagnosticFinding] = []
        for entry in entries {
            guard let name = entry["name"]?.stringValue, !name.isEmpty else {
                findings.append(ProviderSupport.skippedEntry("(unnamed service)", provider: .homebrew, reason: "The entry has no name."))
                continue
            }
            // A status MacUp does not know could mean running or not, so the
            // formula is marked unknown rather than read one way or the other.
            guard let status = entry["status"]?.stringValue, statuses.contains(status) else {
                services[name] = nil
                unreadable.insert(name)
                findings.append(ProviderSupport.skippedEntry(
                    name,
                    provider: .homebrew,
                    reason: "Homebrew gave this service a status MacUp does not recognize, so MacUp cannot say whether it is running."
                ))
                continue
            }
            var exitCode: Int32?
            if case .number(let value)? = entry["exit_code"], value.rounded() == value, abs(value) <= Double(Int32.max) {
                exitCode = Int32(value)
            }
            let service = HomebrewService(status: status, exitCode: exitCode, runsAsRoot: entry["user"]?.stringValue == "root")
            // Two different answers for one formula are no answer at all.
            if let earlier = services[name], earlier != service {
                services[name] = nil
                unreadable.insert(name)
            } else if !unreadable.contains(name) {
                services[name] = service
            }
        }
        return .listed(services: services, unreadable: unreadable, findings: findings)
    }
}

extension HomebrewProvider {
    static let servicesArguments = ["services", "list", "--json"]

    /// Whether `brew services` can run here without Homebrew adding a tap.
    ///
    /// Homebrew now has the command built in. An older Homebrew got it from
    /// the homebrew/services tap, and running it without that tap makes
    /// Homebrew clone the tap first: a download and a change to Homebrew
    /// that a read-only check must not start. So MacUp looks for the
    /// command's own file, built in or tapped, and does not ask otherwise.
    /// If a later Homebrew moves that file, MacUp stops asking and says it
    /// could not tell, which is the safe way to be wrong.
    static func hasServicesCommand(_ installation: ProviderInstallation, fileSystem: any FileSystem) -> Bool {
        let executable = installation.executable.canonicalPath
        guard executable.hasSuffix("/bin/brew") else { return false }
        let repository = String(executable.dropLast("/bin/brew".count))
        return [
            "/Library/Homebrew/cmd/services.rb",
            "/Library/Taps/homebrew/homebrew-services/cmd/services.rb",
        ].contains { fileSystem.fileExists(atPath: repository + $0) }
    }

    /// Reads which formulae run as services. Never throws: an inventory is
    /// still worth having when this part of it is missing, and the reading
    /// says why it is.
    func readServices(_ installation: ProviderInstallation, context: ProviderContext) async -> HomebrewServiceReading {
        guard Self.hasServicesCommand(installation, fileSystem: context.fileSystem) else {
            return .unavailable(
                reason: "This Homebrew has no `brew services` of its own, and running it would make Homebrew add "
                    + "the homebrew/services tap first, so MacUp did not ask.",
                ran: false
            )
        }
        do {
            let result = try await run(Self.servicesArguments, installation, context: context, timeout: .seconds(120))
            guard result.succeeded else {
                let failure = MacUpError.commandFailed(result, "`brew services list` failed.")
                return .unavailable(reason: [failure.message, failure.detail].compactMap { $0 }.joined(separator: "\n"), ran: true)
            }
            return try HomebrewServicesParser.parse(result.standardOutput, command: result.invocation.displayString)
        } catch {
            return .unavailable(reason: MacUpError.wrapping(error, context: "Reading Homebrew's services").message, ran: true)
        }
    }

    /// Records each formula's service state, and what MacUp could not read.
    ///
    /// A formula that defines a service but whose state MacUp could not read
    /// is marked unknown. It is never taken to be not running: "MacUp could
    /// not tell" and "nothing is running" are different answers.
    static func annotate(
        _ items: [ManagedItem],
        services reading: HomebrewServiceReading
    ) -> (items: [ManagedItem], findings: [DiagnosticFinding]) {
        var findings: [DiagnosticFinding] = []
        switch reading {
        case .listed(_, _, let noticed):
            findings = noticed
        case .unavailable(let reason, let ran):
            // Not asking matters only when something here could be a service.
            if ran || items.contains(where: { $0.details["definesService"] == "true" }) {
                findings.append(DiagnosticFinding(
                    id: "homebrew.servicesUnreadable",
                    severity: ran ? .warning : .info,
                    provider: .homebrew,
                    title: "MacUp could not read which Homebrew services are running",
                    detail: reason,
                    recommendation: "Until it can, MacUp does not say whether an update would change a formula that is "
                        + "running as a service. `brew services list` shows them."
                ))
            }
        }

        let annotated = items.map { item -> ManagedItem in
            guard item.kind == .formula else { return item }
            var item = item
            let name = item.id.name.split(separator: "/").last.map(String.init) ?? item.id.name
            let definesService = item.details["definesService"] == "true"
            switch reading {
            case .listed(let services, let unreadable, _):
                if let service = services[name] {
                    item.details["serviceStatus"] = service.status
                    if let exitCode = service.exitCode { item.details["serviceExitCode"] = String(exitCode) }
                    if service.runsAsRoot { item.details["serviceRunsAsRoot"] = "true" }
                } else if unreadable.contains(name) || definesService {
                    // Homebrew lists every formula with a service, so one
                    // missing from the list is a gap, not an answer.
                    item.details["serviceStatusUnknown"] = "true"
                }
            case .unavailable:
                if definesService { item.details["serviceStatusUnknown"] = "true" }
            }
            return item
        }
        return (annotated, findings)
    }

    /// What upgrading a formula Homebrew runs as a service does to that
    /// service, as a risk signal and a note.
    ///
    /// Homebrew does not restart a service when it upgrades the formula (its
    /// own caveat says to restart it afterwards), and a service's launchd job
    /// starts it through `opt/<name>`, which the upgrade points at the new
    /// version. So a running service carries on with the old version until it
    /// next starts, and from then on runs the new one. Only a service that is
    /// running now carries the signal: for the others the next start simply
    /// runs the new version, which is what an upgrade is for.
    static func serviceImpact(of item: ManagedItem) -> (signals: Set<RiskSignal>, notes: [String]) {
        let name = item.displayName
        if item.details["serviceStatusUnknown"] == "true" {
            return ([], [
                "MacUp could not read from Homebrew whether \(name) runs as a service, so it cannot say whether this "
                    + "upgrade would change one that is running.",
            ])
        }
        guard let status = item.details["serviceStatus"], status != "none" else { return ([], []) }
        let asRoot = item.details["serviceRunsAsRoot"] == "true"
        switch status {
        case "started":
            let restart = ShellWord.isPlain(name)
                ? "with `\(asRoot ? "sudo " : "")brew services restart \(name)`"
                : "with `brew services restart`"
            return ([.runsAsService], [
                "\(name) is running now as a Homebrew service. The upgrade replaces the files it starts from, but the "
                    + "service keeps running the old version until it restarts: when you restart it, and also when you "
                    + (asRoot ? "restart your Mac." : "next log in or restart your Mac.")
                    + " MacUp never restarts services. Restart it yourself when you are ready, \(restart).",
            ])
        case "scheduled":
            return ([], ["Homebrew runs \(name) as a scheduled service. Its next run after the upgrade uses the new version."])
        case "error":
            let code = item.details["serviceExitCode"].map { " (exit code \($0))" } ?? ""
            return ([], [
                "\(name) is set up as a Homebrew service, and its last run ended with an error\(code). The next time "
                    + "it starts, whether you start it or launchd does, it runs the new version.",
            ])
        default:
            return ([], [
                "\(name) is set up as a Homebrew service but is not running now (Homebrew reports it as \(status)). "
                    + "The next time it starts, it runs the new version.",
            ])
        }
    }

    /// A database moving to a new major version gets the note that its data
    /// may be converted the first time the new version starts, and the
    /// signal that keeps the update Ask First. Anything else is unchanged.
    ///
    /// Worked out from the candidate's own versions, after the installed
    /// version has been corrected to the one in use, because an interrupted
    /// upgrade leaves a folder named after the new version that would
    /// otherwise make the change look like none at all. A version change
    /// MacUp cannot classify might be a major one, so it is treated as one.
    static func addingDataImpact(_ candidate: UpdateCandidate) -> UpdateCandidate {
        guard candidate.kind == .formula, RuntimeCatalog.isDatabase(candidate.displayName) else { return candidate }
        let name = candidate.displayName
        let consequence = "the first time the new version starts, it may convert your data files to its own format, "
            + "and that cannot be undone. Back up your data before you upgrade."
        switch candidate.versionChange {
        case .major:
            return candidate.adding(
                signals: [.mayMigrateData],
                notes: ["\(name) is a database, and this is a new major version: \(consequence)"]
            )
        case .unknown, .prerelease:
            return candidate.adding(
                signals: [.mayMigrateData],
                notes: ["\(name) is a database, and MacUp cannot tell whether this is a new major version. If it is, \(consequence)"]
            )
        default:
            return candidate
        }
    }
}
