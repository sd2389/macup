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
    public var message: String

    public init(
        item: PackageID,
        outcome: Outcome,
        expectedVersion: String?,
        observedVersion: String?,
        message: String
    ) {
        self.item = item
        self.outcome = outcome
        self.expectedVersion = expectedVersion
        self.observedVersion = observedVersion
        self.message = message
    }
}

/// One line of MacUp's update history (CLAUDE.md §13, §16).
/// History records attempts and skips, never secrets.
public struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var timestamp: Date
    public var origin: ExecutionOrigin
    public var item: PackageID
    public var versionBefore: String?
    public var versionTarget: String?
    public var versionAfter: String?
    /// Redacted display form of the command(s) run.
    public var command: String?
    public var outcome: ExecutionResult.Outcome
    public var verification: VerificationResult.Outcome?
    /// Redacted, display-safe error summary.
    public var errorSummary: String?
    public var skipReason: String?
    public var durationSeconds: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        origin: ExecutionOrigin,
        item: PackageID,
        versionBefore: String?,
        versionTarget: String?,
        versionAfter: String?,
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
        self.command = command
        self.outcome = outcome
        self.verification = verification
        self.errorSummary = errorSummary
        self.skipReason = skipReason
        self.durationSeconds = durationSeconds
    }

    public var provider: ProviderID { item.provider }
}
