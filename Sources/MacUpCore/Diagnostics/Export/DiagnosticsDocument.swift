import Foundation

/// A file a user can attach to a bug report: what MacUp found on this Mac,
/// with secrets, the user's name, environment variables, and — unless the
/// user asks for them — package names left out (CLAUDE.md §13, §16, §18).
///
/// It is built from a ``DiagnosticsSnapshot`` and nothing else, and
/// ``encoded()`` is the one rendering of it, so the preview a user reads and
/// the file that is saved are the same bytes. Every field is chosen here one
/// by one: nothing reaches the file because a model it is built from
/// happened to gain a property, and every string passes through
/// ``DiagnosticsScrubber`` on the way in.
///
/// Schema version 1. New fields may be added within a version; renaming or
/// removing a field requires a new version (docs/CLI.md).
public struct DiagnosticsDocument: Sendable, Hashable, Codable {
    public static let schemaVersion = 1
    /// How many history entries the file carries, newest first.
    public static let historyLimit = 50

    /// How package names appear in the file.
    public enum PackageNames: String, Sendable, Hashable, Codable {
        /// Replaced with placeholders such as `brew:package-1`.
        case placeholders
        /// Written as they are, because the user asked for them.
        case included
    }

    /// One provider as the check found it.
    public struct Provider: Sendable, Hashable, Codable {
        public var provider: ProviderID
        public var displayName: String
        public var availability: ProviderStatus.Availability
        public var version: String?
        public var executable: ResolvedExecutable?
        public var facts: [ProviderFact]
        public var installedCount: Int?
        public var updateCount: Int?
        public var unreadableUpdates: Int
        public var resultsIncomplete: Bool
        public var errors: [ProviderOperationError]
        public var durationSeconds: Double
    }

    /// The read-only check behind the file.
    public struct Check: Sendable, Hashable, Codable {
        public var mode: CheckReport.Mode
        public var startedAt: Date
        public var finishedAt: Date
        public var cancelled: Bool
        /// Finished, every checked provider succeeded, and none left updates out.
        public var complete: Bool
        public var summary: CheckReport.Summary
        public var updates: [Update]
        /// Every command the check ran or refused, as it was displayed.
        public var commands: [Command]
    }

    public struct Update: Sendable, Hashable, Codable {
        /// `brew:git`, or `brew:package-1` when names are left out.
        public var item: String
        public var kind: ItemKind
        public var installedVersion: String?
        public var availableVersion: String
        public var versionChange: VersionChange
        public var risk: RiskLevel
        public var signals: [RiskSignal]
        /// Who manages the item, outermost first, such as `npm → Node 24.19.0 → mise`.
        public var ownership: String?
    }

    public struct Command: Sendable, Hashable, Codable {
        public var command: String
        public var effect: CommandEffect
        public var outcome: CommandRecord.Outcome
        public var exitStatus: Int32?
        public var durationSeconds: Double
    }

    public struct Doctor: Sendable, Hashable, Codable {
        public var startedAt: Date
        public var finishedAt: Date
        public var cancelled: Bool
        public var summary: DoctorReport.Summary
        /// Most severe first, as `macup doctor` lists them.
        public var findings: [DiagnosticFinding]
    }

    public struct Configuration: Sendable, Hashable, Codable {
        public var path: String
        public var source: LoadedConfiguration.Source
        public var valid: Bool
        public var automaticModificationsAllowed: Bool
        public var migratedFromSchemaVersion: Int?
        public var issues: [ConfigurationIssue]
        public var schedule: MacUpConfiguration.ScheduleSettings
        public var security: MacUpConfiguration.SecuritySettings
    }

    public struct Policies: Sendable, Hashable, Codable {
        public var defaultPolicy: UpdatePolicy
        public var confirmMajorUpdates: Bool
        public var providers: [PolicyListing.ProviderRule]
        public var items: [ItemRule]
        /// Rules whose key MacUp could not read as a package ID. The
        /// configuration's issues say which, with the key masked like any name.
        public var unreadableItemRules: Int
    }

    public struct ItemRule: Sendable, Hashable, Codable {
        public var item: String
        public var policy: UpdatePolicy
        public var effectivePolicy: UpdatePolicy
        /// The one version the user skipped, which is why an item can be
        /// left out of a plan its policy would otherwise allow.
        public var skipVersion: String?
        /// Whether the user wrote a note on the item. The note is their own
        /// words, so only its existence goes in the file.
        public var hasNote: Bool
    }

    public struct History: Sendable, Hashable, Codable {
        /// Newest first, at most ``DiagnosticsDocument/historyLimit``.
        public var entries: [HistoryItem]
        public var unreadableLines: Int
        public var olderEntriesNotRead: Bool
        /// Why the history could not be read, when it could not.
        public var problem: String?
    }

    public struct HistoryItem: Sendable, Hashable, Codable {
        public var timestamp: Date
        public var origin: ExecutionOrigin
        public var item: String
        public var versionBefore: String?
        public var versionTarget: String?
        public var versionAfter: String?
        public var command: String?
        public var outcome: ExecutionResult.Outcome
        public var verification: VerificationResult.Outcome?
        public var errorSummary: String?
        public var skipReason: String?
        public var durationSeconds: Double?
    }

    public var schemaVersion: Int
    public var kind: String
    public var macupVersion: String
    public var createdAt: Date
    public var packageNames: PackageNames
    public var system: SystemInfo
    public var providers: [Provider]
    public var check: Check?
    public var doctor: Doctor?
    public var configuration: Configuration
    public var policies: Policies
    public var history: History
    /// What the file deliberately does not contain, in words, so whoever
    /// reads it knows what is missing and why.
    public var leftOut: [String]

    public init(_ snapshot: DiagnosticsSnapshot, includePackageNames: Bool) {
        let packageNames: PackageNames = includePackageNames ? .included : .placeholders
        let scrub = DiagnosticsScrubber(
            homeDirectory: snapshot.homeDirectory,
            packageNames: includePackageNames ? nil : PackageNameMask(names: Self.packageNames(in: snapshot))
        )
        schemaVersion = Self.schemaVersion
        kind = "diagnostics"
        macupVersion = MacUp.version
        createdAt = snapshot.createdAt
        self.packageNames = packageNames
        leftOut = Self.leftOut(packageNames: packageNames)
        system = SystemInfo(
            productVersion: scrub.text(snapshot.system.productVersion),
            buildVersion: scrub.text(snapshot.system.buildVersion),
            architecture: scrub.text(snapshot.system.architecture)
        )
        // Placeholders are numbered in the order they are first used, so the
        // sections are built in the order the file lists them (its keys are
        // sorted): check, configuration, doctor, history, policies, providers.
        check = snapshot.check.map { Self.check($0, scrub) }
        configuration = Self.configuration(snapshot.configuration, scrub)
        doctor = snapshot.doctor.map { Self.doctor($0, scrub) }
        history = Self.history(snapshot.history, problem: snapshot.historyProblem, scrub)
        policies = Self.policies(PolicyListing(snapshot.configuration), scrub)
        providers = (snapshot.check?.providers ?? snapshot.doctor?.providers ?? []).map { Self.provider($0, scrub) }
    }

    /// The file's bytes, which are also exactly what a preview shows: sorted
    /// keys, ISO 8601 dates, one trailing newline, and nothing a terminal
    /// would act on, so printing it is as safe as saving it.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = TerminalText.escapingUnsafeScalars(inJSON: String(decoding: try encoder.encode(self), as: UTF8.self))
        return Data((json + "\n").utf8)
    }

    // MARK: What is in it, in words

    /// What the file contains, for a preview to list beside the text itself.
    public static func included(packageNames: PackageNames) -> [String] {
        var lines = [
            "MacUp's version, and this Mac's macOS version, build, and architecture.",
            "Which package managers MacUp found, their versions, and the executables it uses.",
            "What a read-only check found just now: how many updates, their versions and risk, the commands it ran, and any errors.",
            "Doctor's findings, which can name folders on your PATH.",
            "Whether your configuration is valid and what is wrong with it, with your schedule and approval settings.",
            "Your update policies.",
            "The last \(historyLimit) entries in MacUp's history.",
        ]
        if packageNames == .included {
            lines.append("Package names, because you chose to include them.")
        }
        return lines
    }

    /// What the file deliberately leaves out. Written into the file as well.
    public static func leftOut(packageNames: PackageNames) -> [String] {
        var lines: [String] = []
        if packageNames == .placeholders {
            lines.append(
                "Package names. Each is replaced with a placeholder such as brew:package-1, the same one everywhere in the file. "
                    + "Runtimes and package managers MacUp itself knows by name, such as node, python, and npm, are kept."
            )
        }
        lines += [
            "The list of what is installed. Only how many items each package manager has.",
            "Your notes on items. Only whether an item has one.",
            "Environment variables and their values.",
            "Passwords, tokens, and authorization headers, which are replaced with <redacted> wherever they appear.",
            "Your user name. Your home folder is written as ~, and the name on its own as <user>.",
            "The output of the commands MacUp ran, apart from short excerpts of errors.",
        ]
        return lines
    }

    // MARK: Building

    /// Every package name the file could mention, with the other names a
    /// provider gives it, so the mask can find it in free text as well as in
    /// the fields that hold an ID.
    ///
    /// Installed items are included although the file never lists them: a
    /// provider's error message can name any of them.
    static func packageNames(in snapshot: DiagnosticsSnapshot) -> [(name: String, alsoKnownAs: [String])] {
        var names: [(name: String, alsoKnownAs: [String])] = []
        func add(_ id: PackageID, _ displayName: String? = nil) {
            var others = displayName.map { [$0] } ?? []
            // A mise tool from another backend (`npm:@acme/cli`) is written
            // without its backend almost everywhere else.
            if let colon = id.name.firstIndex(of: ":") {
                others.append(String(id.name[id.name.index(after: colon)...]))
            }
            names.append((id.name, others))
            // An npm scope names its owner, often an employer, and messages
            // name it on its own.
            if id.name.hasPrefix("@"), let slash = id.name.firstIndex(of: "/") {
                names.append((String(id.name[..<slash]), []))
            }
        }
        for update in snapshot.check?.updates ?? [] {
            add(update.id, update.displayName)
        }
        for report in (snapshot.check?.providers ?? []) + (snapshot.doctor?.providers ?? []) {
            for item in report.items ?? [] {
                add(item.id, item.displayName)
                // A third-party tap names who publishes it.
                if let tap = item.details["tap"], !tap.hasPrefix("homebrew/") {
                    names.append((tap, []))
                }
            }
        }
        for entry in snapshot.history?.entries ?? [] {
            add(entry.item)
        }
        for key in snapshot.configuration.configuration.items.keys.sorted() {
            if let id = try? PackageID(parsing: key) {
                add(id)
            } else {
                // Not a package ID, but still the user's own words for one.
                names.append((key, [TerminalText.sanitize(key)]))
            }
        }
        return names
    }

    private static func check(_ report: CheckReport, _ scrub: DiagnosticsScrubber) -> Check {
        let commands = report.commands.map { record in
            Command(
                command: scrub.text(record.command),
                effect: record.effect,
                outcome: record.outcome,
                exitStatus: record.exitStatus,
                durationSeconds: milliseconds(record.durationSeconds)
            )
        }
        let updates = report.updates.map { update in
            Update(
                item: scrub.item(update.id),
                kind: update.kind,
                installedVersion: scrub.text(update.installedVersion?.raw),
                availableVersion: scrub.text(update.availableVersion.raw),
                versionChange: update.versionChange,
                risk: update.risk.level,
                signals: update.signals,
                ownership: scrub.text(update.ownership?.summary)
            )
        }
        return Check(
            mode: report.mode,
            startedAt: report.startedAt,
            finishedAt: report.finishedAt,
            cancelled: report.cancelled,
            complete: report.isComplete,
            summary: report.summary,
            updates: updates,
            commands: commands
        )
    }

    private static func configuration(_ loaded: LoadedConfiguration, _ scrub: DiagnosticsScrubber) -> Configuration {
        var schedule = loaded.configuration.schedule
        // Whatever was typed there, even if it is not a time.
        schedule.time = scrub.text(schedule.time)
        return Configuration(
            path: scrub.text(loaded.path),
            source: loaded.source,
            valid: !loaded.hasErrors,
            automaticModificationsAllowed: loaded.allowsAutomaticModification,
            migratedFromSchemaVersion: loaded.migratedFromSchemaVersion,
            issues: loaded.issues.map { issue in
                ConfigurationIssue(issue.severity, scrub.text(issue.path), scrub.text(issue.message))
            },
            schedule: schedule,
            security: loaded.configuration.security
        )
    }

    private static func doctor(_ report: DoctorReport, _ scrub: DiagnosticsScrubber) -> Doctor {
        Doctor(
            startedAt: report.startedAt,
            finishedAt: report.finishedAt,
            cancelled: report.cancelled,
            summary: report.summary,
            findings: report.findings.map(scrub.finding)
        )
    }

    private static func history(_ reading: HistoryReading?, problem: String?, _ scrub: DiagnosticsScrubber) -> History {
        let entries = (reading?.entries ?? []).prefix(historyLimit).map { entry in
            HistoryItem(
                timestamp: entry.timestamp,
                origin: entry.origin,
                item: scrub.item(entry.item),
                versionBefore: scrub.text(entry.versionBefore),
                versionTarget: scrub.text(entry.versionTarget),
                versionAfter: scrub.text(entry.versionAfter),
                command: scrub.text(entry.command),
                outcome: entry.outcome,
                verification: entry.verification,
                errorSummary: scrub.text(entry.errorSummary),
                skipReason: scrub.text(entry.skipReason),
                durationSeconds: entry.durationSeconds.map(milliseconds)
            )
        }
        return History(
            entries: Array(entries),
            unreadableLines: reading?.unreadableLines ?? 0,
            olderEntriesNotRead: reading?.olderEntriesNotRead ?? false,
            problem: scrub.text(problem)
        )
    }

    private static func policies(_ listing: PolicyListing, _ scrub: DiagnosticsScrubber) -> Policies {
        Policies(
            defaultPolicy: listing.defaultPolicy,
            confirmMajorUpdates: listing.confirmMajorUpdates,
            providers: listing.providers.map { rule in
                // A provider the file names but MacUp does not know is the
                // user's own text, so it is scrubbed like any other.
                PolicyListing.ProviderRule(
                    provider: rule.provider.isKnown ? rule.provider : ProviderID(rawValue: scrub.text(rule.provider.rawValue)),
                    enabled: rule.enabled,
                    policy: rule.policy,
                    effectivePolicy: rule.effectivePolicy,
                    explicit: rule.explicit
                )
            },
            items: listing.items.map { rule in
                ItemRule(
                    item: scrub.item(rule.item),
                    policy: rule.policy,
                    effectivePolicy: rule.effectivePolicy,
                    skipVersion: scrub.text(rule.skipVersion),
                    hasNote: rule.note?.isEmpty == false
                )
            },
            unreadableItemRules: listing.unreadableItemKeys.count
        )
    }

    private static func provider(_ report: ProviderReport, _ scrub: DiagnosticsScrubber) -> Provider {
        Provider(
            provider: report.provider,
            displayName: report.displayName,
            availability: report.availability,
            version: scrub.text(report.version),
            executable: report.executable.map { executable in
                ResolvedExecutable(
                    path: scrub.text(executable.path),
                    canonicalPath: scrub.text(executable.canonicalPath),
                    source: executable.source
                )
            },
            facts: report.facts.map { ProviderFact(key: $0.key, label: $0.label, value: scrub.text($0.value)) },
            installedCount: report.installedCount,
            updateCount: report.updateCount,
            unreadableUpdates: report.unreadableUpdates,
            resultsIncomplete: report.resultsIncomplete,
            errors: report.errors.map { ProviderOperationError(operation: $0.operation, error: scrub.error($0.error)) },
            durationSeconds: milliseconds(report.durationSeconds)
        )
    }

    /// Seconds to the millisecond. Anything finer is noise in a bug report.
    private static func milliseconds(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}
