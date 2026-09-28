import Foundation

/// Compares the `PATH` MacUp ran with against the one a terminal would have
/// (CLAUDE.md §13, docs/COMMAND_EXECUTION.md).
///
/// An app launched from Finder inherits launchd's minimal environment, so it
/// reads the login shell's environment at startup to find the tools a terminal
/// finds. When that read fails the app falls back to its own environment, and
/// then it can miss Homebrew in a custom prefix or anything `mise activate`
/// puts on `PATH`. This is the check that says so.
///
/// Reading the login shell is the one command Doctor runs itself, through the
/// same ``CommandRunning`` as everything else; the captured environment is
/// compared and then dropped, never logged or stored (CLAUDE.md §17).
public struct ShellEnvironmentCheck: DiagnosticCheck {
    /// Reads a login shell's environment. Injectable so tests describe a
    /// machine instead of starting a shell.
    public typealias Reader = @Sendable (DiagnosticInput) async throws -> (shell: String, environment: [String: String])

    public let id = "environment.loginShell"
    public let title = "Whether MacUp sees the same PATH your terminal does"
    public var read: Reader

    public init(read: @escaping Reader = ShellEnvironmentCheck.loginShell) {
        self.read = read
    }

    /// The real login shell, resolved from the account database and checked
    /// against `/etc/shells` by ``LoginShellEnvironment``.
    public static let loginShell: Reader = { input in
        let shell = LoginShellEnvironment.userLoginShell(fileSystem: input.environment.fileSystem)
        let environment = try await LoginShellEnvironment.capture(
            shell: shell,
            runner: input.environment.runner,
            homeDirectory: input.environment.homeDirectory,
            baseEnvironment: input.environment.processEnvironment
        )
        return (shell, environment)
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        let shellEnvironment: [String: String]
        let shell: String
        do {
            (shell, shellEnvironment) = try await read(input)
        } catch {
            return [unreadable(MacUpError.wrapping(error, context: "Reading your login shell's environment"), input: input)]
        }

        let mine = input.searchPath
        let theirs = SearchPath.parse(shellEnvironment["PATH"])
        let missing = theirs.filter { !mine.contains($0) }
        let extra = mine.filter { !theirs.contains($0) }
        guard !missing.isEmpty || !extra.isEmpty else { return [] }

        var parts: [String] = []
        if !missing.isEmpty {
            parts.append("\(shellName(shell)) has \(DiagnosticText.list(missing.map(input.display))), which MacUp did not.")
        }
        if !extra.isEmpty {
            parts.append("MacUp had \(DiagnosticText.list(extra.map(input.display))), which \(shellName(shell)) did not.")
        }
        // Directories MacUp is missing are the serious half: a tool that lives
        // only there is one MacUp will not find at all. Having extra ones only
        // means MacUp could reach a copy the shell would not, which is normal
        // when it runs from an IDE or an editor's terminal.
        return [DiagnosticFinding(
            id: "environment.pathDiffersFromLoginShell",
            severity: missing.isEmpty ? .info : .warning,
            provider: nil,
            title: "MacUp's PATH is not the one your shell uses",
            detail: parts.joined(separator: " "),
            recommendation: missing.isEmpty
                ? "MacUp resolves tools from its own PATH, so it can reach a copy your shell would not. "
                    + "It shows the exact path it chose for every provider."
                : "A tool that lives only in one of those directories is one MacUp will not find. "
                    + "MacUp shows the exact path it chose for every provider."
        )]
    }

    private func unreadable(_ error: MacUpError, input: DiagnosticInput) -> DiagnosticFinding {
        DiagnosticFinding(
            id: "environment.loginShellUnreadable",
            severity: .warning,
            provider: nil,
            title: "MacUp could not read your login shell's environment",
            detail: input.display(error.message)
                + " MacUp used the environment it was started with, which may not include every tool a terminal finds.",
            recommendation: "MacUp cannot tell whether its PATH matches your shell's. "
                + "Adding `[[ -n $MACUP_RESOLVING_ENVIRONMENT ]] && return` early in your shell profile "
                + "lets it skip slow startup work."
        )
    }

    private func shellName(_ shell: String) -> String {
        let name = (shell as NSString).lastPathComponent
        return name.isEmpty ? "your login shell" : name
    }
}
