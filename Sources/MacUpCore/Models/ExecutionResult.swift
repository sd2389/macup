import Foundation

/// The outcome of running one execution plan.
public struct ExecutionResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        case succeeded
        case failed
        case skipped
        case cancelled
        case timedOut
    }

    public struct StepResult: Sendable, Hashable, Codable {
        /// Display form of the command, redacted.
        public var command: String
        public var exitStatus: Int32?
        public var durationSeconds: Double
        /// Redacted excerpt of the command's error output.
        public var errorExcerpt: String?

        public init(command: String, exitStatus: Int32?, durationSeconds: Double, errorExcerpt: String? = nil) {
            self.command = command
            self.exitStatus = exitStatus
            self.durationSeconds = durationSeconds
            self.errorExcerpt = errorExcerpt
        }
    }

    public var planID: UUID
    public var item: PackageID
    public var outcome: Outcome
    public var startedAt: Date
    public var finishedAt: Date
    public var steps: [StepResult]
    public var error: MacUpError?
    /// Why the plan was skipped, for example a policy that changed after planning.
    public var skipReason: String?

    public init(
        planID: UUID,
        item: PackageID,
        outcome: Outcome,
        startedAt: Date,
        finishedAt: Date,
        steps: [StepResult] = [],
        error: MacUpError? = nil,
        skipReason: String? = nil
    ) {
        self.planID = planID
        self.item = item
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.steps = steps
        self.error = error
        self.skipReason = skipReason
    }
}

/// Whether an update actually reached its target.
///
/// MacUp also reads an item back after an attempt that ran a command and did
/// not succeed, and this is what it found then: not a confirmation, but the
/// state the attempt left behind.
public struct VerificationResult: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// The expected version is installed.
        case verified
        /// A different version is installed than the one planned.
        case targetNotReached
        /// Verification could not complete (for example the executable disappeared).
        case failed
        /// No verification was attempted.
        case notPerformed
    }

    public var item: PackageID
    public var outcome: Outcome
    public var expectedVersion: String?
    public var observedVersion: String?
    /// What else the read-back showed that a person would want to know,
    /// beyond the version: for example that no version is linked, or that an
    /// install never finished. `nil` when there is nothing to add. Built from
    /// provider output, so it is made display-safe wherever it is shown.
    public var observedState: String?
    public var message: String

    public init(
        item: PackageID,
        outcome: Outcome,
        expectedVersion: String?,
        observedVersion: String?,
        observedState: String? = nil,
        message: String
    ) {
        self.item = item
        self.outcome = outcome
        self.expectedVersion = expectedVersion
        self.observedVersion = observedVersion
        self.observedState = observedState
        self.message = message
    }
}

/// One line of MacUp's update history (CLAUDE.md §13, §16).
/// History records attempts and skips, never secrets.
///
/// Fields are only ever added, and every added one is optional, so a line
/// written by an older MacUp still decodes. Such a line simply lacks what
/// that version did not record, and is shown without it rather than with a
/// guess (``HistoryHeadline``).
public struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var timestamp: Date
    public var origin: ExecutionOrigin
    /// The package the entry is about. `nil` only for an uninstall of an app
    /// no package manager owns, or of MacUp itself, which ``uninstall``
    /// names instead.
    public var item: PackageID?
    public var versionBefore: String?
    public var versionTarget: String?
    /// The version MacUp read back afterwards. Recorded after a success, and
    /// after an attempt that ran a command and did not succeed; `nil` when
    /// nothing was read back.
    public var versionAfter: String?
    /// What else that read-back showed, in a sentence, when there was
    /// something worth saying: for example that no version is linked any
    /// more. Redacted like every other string here.
    public var stateAfter: String?
    /// Redacted display form of the command(s) run.
    public var command: String?
    public var outcome: ExecutionResult.Outcome
    public var verification: VerificationResult.Outcome?
    /// Redacted, display-safe error summary.
    public var errorSummary: String?
    public var skipReason: String?
    public var durationSeconds: Double?
    /// What an uninstall removed, kept, and skipped. `nil` for an update.
    public var uninstall: UninstallRecord?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        origin: ExecutionOrigin,
        item: PackageID?,
        versionBefore: String?,
        versionTarget: String?,
        versionAfter: String?,
        stateAfter: String? = nil,
        command: String?,
        outcome: ExecutionResult.Outcome,
        verification: VerificationResult.Outcome?,
        errorSummary: String? = nil,
        skipReason: String? = nil,
        durationSeconds: Double? = nil
    ) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.timestamp = timestamp
        self.origin = origin
        self.item = item
        self.versionBefore = versionBefore
        self.versionTarget = versionTarget
        self.versionAfter = versionAfter
        self.stateAfter = stateAfter
        self.command = command
        self.outcome = outcome
        self.verification = verification
        self.errorSummary = errorSummary
        self.skipReason = skipReason
        self.durationSeconds = durationSeconds
    }

    /// The provider of the package, when there is one.
    public var provider: ProviderID? { item?.provider }

    /// What the entry is about, as the command line names it: `brew:mysql`,
    /// `app:com.openai.chat`, `mise:node@22.1.0`, or `macup`.
    public var subjectID: String { uninstall?.target ?? item?.rawValue ?? "unknown" }

    /// What the entry is about, as a person names it.
    public var subjectName: String { uninstall?.name ?? item?.name ?? subjectID }
}
