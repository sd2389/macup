import ArgumentParser

/// Process exit codes. Documented in docs/CLI.md; keep them stable.
enum MacUpExitCode: Int32, CaseIterable {
    /// The command completed.
    case success = 0
    /// An unexpected internal error.
    case failure = 1
    /// A check completed, but at least one provider failed or left updates out;
    /// results are partial.
    case providerErrors = 2
    /// The configuration is invalid. Read-only commands still ran; automatic
    /// modifications stay disabled until it is fixed.
    case configurationInvalid = 3
    /// `macup update` ran but at least one item failed. What succeeded is
    /// still recorded in history.
    case updateFailed = 4
    /// `macup doctor` found something that needs attention: an error or a
    /// warning. Notes alone are exit code 0.
    case attentionRequired = 5
    /// Invalid command-line usage.
    case usage = 64
    /// `macup diagnostics export` could not create its file: something is
    /// already there, it is a symbolic link, or the folder is missing or not
    /// writable. Nothing was written.
    case cannotCreateOutput = 73
    /// The device owner did not approve the change, or MacUp could not ask.
    /// Nothing was changed.
    case notApproved = 77
    /// Interrupted with Ctrl+C.
    case cancelled = 130

    var exitCode: ExitCode { ExitCode(rawValue) }
}
