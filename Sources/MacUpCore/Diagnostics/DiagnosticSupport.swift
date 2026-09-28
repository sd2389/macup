import Darwin
import Foundation

extension DiagnosticInput {
    /// The search path the check actually ran with, already sanitized.
    var searchPath: [String] { SearchPath.parse(environment.processEnvironment["PATH"]) }

    var resolver: ExecutableResolver { ExecutableResolver(fileSystem: environment.fileSystem) }

    /// Keeps usernames and anything secret-shaped out of findings, because a
    /// report is meant to be readable aloud and pasted into an issue
    /// (CLAUDE.md §16, §18).
    var redactor: Redactor { Redactor(homeDirectory: environment.homeDirectory) }

    /// Turns paths, provider output, and error text into something safe to
    /// print. Provider output is untrusted input, so every value that reaches
    /// a finding goes through here.
    func display(_ text: String) -> String {
        TerminalText.sanitize(redactor.redact(text))
    }

    func report(for provider: ProviderID) -> ProviderReport? {
        report.providers.first { $0.provider == provider }
    }

    /// Reports for the providers that were found and run.
    var availableReports: [ProviderReport] {
        report.providers.filter { $0.availability == .available }
    }

    /// Whether a provider already reported this concern while being checked.
    /// A Doctor check covering the same ground stands down rather than saying
    /// it twice, since provider findings reach the report on their own.
    func providerReported(_ findingID: String) -> Bool {
        report.providers.contains { $0.findings.contains { $0.id == findingID } }
    }

    /// mise's data directory, following mise's own environment variables, so
    /// checks can recognize a mise-managed executable by its path.
    var miseDataDirectory: String {
        NodeManager.miseDataDirectory(
            environment: environment.processEnvironment,
            homeDirectory: environment.homeDirectory
        )
    }
}

/// Formatting shared by the diagnostic checks, so findings read the same way
/// wherever they come from.
enum DiagnosticText {
    /// Joins values into a sentence fragment, keeping the list short enough to
    /// read. A finding explains what MacUp saw; it is not a dump.
    static func list(_ values: [String], limit: Int = 6) -> String {
        guard values.count > limit else { return values.joined(separator: ", ") }
        return values.prefix(limit).joined(separator: ", ") + ", and \(values.count - limit) more"
    }
}

/// Why MacUp cannot rely on one of its own directories, or `nil` when the
/// directory is usable and only its owner can change it.
///
/// The ownership rules match ``ExecutableResolver``: root and the user are
/// trusted, and group write is tolerated only for `wheel` and `admin`, whose
/// members can already become root.
enum DirectoryProblem: Sendable, Hashable {
    case uninspectable
    case notADirectory
    case ownedByAnotherUser
    case writableByOtherUsers
    case ownerCannotUseIt

    /// macOS's `admin` group.
    private static let adminGroup: gid_t = 80

    static func of(_ path: String, fileSystem: any FileSystem, userID: uid_t) -> DirectoryProblem? {
        guard let ownership = fileSystem.ownership(ofPath: path) else { return .uninspectable }
        guard fileSystem.isDirectory(atPath: path) else { return .notADirectory }
        guard ownership.uid == userID else { return .ownedByAnotherUser }
        let groupMayWrite = ownership.mode & S_IWGRP != 0 && ownership.gid != 0 && ownership.gid != adminGroup
        if ownership.mode & S_IWOTH != 0 || groupMayWrite { return .writableByOtherUsers }
        let ownerNeeds: mode_t = S_IRUSR | S_IWUSR | S_IXUSR
        guard ownership.mode & ownerNeeds == ownerNeeds else { return .ownerCannotUseIt }
        return nil
    }
}

extension DiagnosticFinding {
    /// The order findings appear in a report: most severe first, then by
    /// identifier, then by the text itself.
    ///
    /// The ordering is total so that two runs over the same machine produce
    /// the same `--json`, including when one identifier appears several times
    /// (a provider can skip more than one unreadable entry).
    static func isOrderedBefore(_ lhs: DiagnosticFinding, _ rhs: DiagnosticFinding) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return (lhs.detail ?? "") < (rhs.detail ?? "")
    }
}
