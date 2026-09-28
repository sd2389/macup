import Darwin
import Foundation

/// Checks the directories MacUp keeps its own files in (CLAUDE.md §13, §19).
///
/// A directory another user can write is a real problem, not a detail: they
/// could replace the configuration that decides what MacUp is allowed to
/// update, or rewrite the history that records what it did. A directory that
/// does not exist yet is not reported — that is the state of a Mac before
/// MacUp has ever saved anything.
public struct StateDirectoryCheck: DiagnosticCheck {
    public let id = "paths.directories"
    public let title = "Whether MacUp's own directories are usable and private"

    /// The user MacUp is running as. Settable so tests can describe a
    /// directory belonging to somebody else.
    public var userID: uid_t

    public init(userID: uid_t = getuid()) {
        self.userID = userID
    }

    private struct Directory {
        var path: String
        var purpose: String
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        let directories = [
            Directory(path: input.paths.configDirectory, purpose: "configuration"),
            Directory(path: input.paths.stateDirectory, purpose: "history and saved check results"),
            Directory(path: input.paths.launchAgentsDirectory, purpose: "the scheduled check's launchd agent"),
        ]
        var findings: [DiagnosticFinding] = []
        var seen: Set<String> = []
        for directory in directories where seen.insert(directory.path).inserted {
            guard input.environment.fileSystem.fileExists(atPath: directory.path) else { continue }
            guard let problem = DirectoryProblem.of(
                directory.path,
                fileSystem: input.environment.fileSystem,
                userID: userID
            ) else { continue }
            findings.append(finding(problem, directory: directory, input: input))
        }
        return findings
    }

    private func finding(
        _ problem: DirectoryProblem,
        directory: Directory,
        input: DiagnosticInput
    ) -> DiagnosticFinding {
        let path = input.display(directory.path)
        switch problem {
        case .writableByOtherUsers:
            return DiagnosticFinding(
                id: "paths.directoryWritableByOthers",
                severity: .error,
                provider: nil,
                title: "Another user can change MacUp's \(directory.purpose)",
                detail: "\(path) is writable by users other than you.",
                recommendation: "Run `chmod go-w \(path)`. MacUp refuses to write there while anybody else can, "
                    + "because it decides what MacUp is allowed to change."
            )
        case .ownedByAnotherUser:
            return DiagnosticFinding(
                id: "paths.directoryUnusable",
                severity: .error,
                provider: nil,
                title: "MacUp's \(directory.purpose) directory belongs to another user",
                detail: "\(path) is not owned by you, so MacUp cannot rely on what is in it.",
                recommendation: "A directory left behind by `sudo` is the usual cause. "
                    + "Give it back to your own account, or remove it and let MacUp create it again."
            )
        case .notADirectory:
            return DiagnosticFinding(
                id: "paths.directoryUnusable",
                severity: .error,
                provider: nil,
                title: "MacUp's \(directory.purpose) location is not a directory",
                detail: "\(path) exists but is not a directory.",
                recommendation: "Move whatever is at that path aside so MacUp can create the directory."
            )
        case .ownerCannotUseIt:
            return DiagnosticFinding(
                id: "paths.directoryUnusable",
                severity: .error,
                provider: nil,
                title: "MacUp cannot read and write its \(directory.purpose) directory",
                detail: "\(path) belongs to you but its permissions do not allow reading, writing, and listing.",
                recommendation: "Run `chmod u+rwx \(path)`."
            )
        case .uninspectable:
            return DiagnosticFinding(
                id: "paths.directoryUninspectable",
                severity: .warning,
                provider: nil,
                title: "MacUp could not inspect its \(directory.purpose) directory",
                detail: "Something exists at \(path), but MacUp could not read its owner or permissions.",
                recommendation: "MacUp treats this as unknown rather than assuming the directory is safe to use."
            )
        }
    }
}
