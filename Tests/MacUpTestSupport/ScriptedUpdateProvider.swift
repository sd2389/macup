import Foundation
import MacUpCore

/// A provider whose verification answer a test writes in advance.
///
/// The execution engine only ever asks a provider to confirm an update, so
/// detection, inventory, and outdated are deliberately inert: a test that
/// reaches them has gone somewhere the engine should not.
public struct ScriptedUpdateProvider: UpdateProvider {
    public let id: ProviderID
    public let capabilities: Set<ProviderCapability> = [
        .detect, .outdated, .planUpdates, .updateSelectedItems, .verifyUpdates,
    ]
    /// What `verify` answers, or throws.
    public var verification: @Sendable (ExecutionResult, UpdateCandidate, ProviderContext) async throws -> VerificationResult

    public init(
        id: ProviderID = .homebrew,
        verification: @escaping @Sendable (ExecutionResult, UpdateCandidate, ProviderContext) async throws -> VerificationResult
    ) {
        self.id = id
        self.verification = verification
    }

    /// Answers that the planned version is now installed.
    public static func confirming(_ id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: .verified,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: candidate.availableVersion.raw,
                message: "\(candidate.displayName) is now \(candidate.availableVersion.raw)."
            )
        }
    }

    /// Answers that a different version is installed than the one planned.
    public static func reporting(observed: String, for id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, candidate, _ in
            VerificationResult(
                item: candidate.id,
                outcome: .targetNotReached,
                expectedVersion: candidate.availableVersion.raw,
                observedVersion: observed,
                message: "\(candidate.displayName) is \(observed), not \(candidate.availableVersion.raw)."
            )
        }
    }

    /// Fails to confirm anything.
    public static func failing(_ error: MacUpError, for id: ProviderID = .homebrew) -> ScriptedUpdateProvider {
        ScriptedUpdateProvider(id: id) { _, _, _ in throw error }
    }

    public func detect(context: ProviderContext) async -> ProviderStatus {
        ProviderStatus(provider: id, availability: .unavailable)
    }

    public func inventory(context: ProviderContext) async throws -> ProviderListing<ManagedItem> {
        ProviderListing()
    }

    public func outdated(context: ProviderContext) async throws -> ProviderListing<UpdateCandidate> {
        ProviderListing()
    }

    public func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        try await verification(result, candidate, context)
    }
}
