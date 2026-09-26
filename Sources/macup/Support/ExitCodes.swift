import ArgumentParser

/// Process exit codes. Documented in docs/CLI.md; keep them stable.
enum MacUpExitCode: Int32, CaseIterable {
    /// The command completed.
    case success = 0
    /// An unexpected internal error.
    case failure = 1
    /// A check completed, but at least one provider failed; results are partial.
    case providerErrors = 2
    /// The configuration is invalid. Read-only commands still ran; automatic
    /// modifications stay disabled until it is fixed.
    case configurationInvalid = 3
    /// Invalid command-line usage.
    case usage = 64
    /// Interrupted with Ctrl+C.
    case cancelled = 130

    var exitCode: ExitCode { ExitCode(rawValue) }
}
