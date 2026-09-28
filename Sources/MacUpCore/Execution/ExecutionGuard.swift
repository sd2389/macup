import Foundation

/// Wraps a runner so that, while a plan runs, the only commands that can be
/// launched are the ones that plan declared.
///
/// The plan is what the user reviewed before anything ran (CLAUDE.md §2.3,
/// §2.4), so the plan is exactly what MacUp is allowed to run. An invocation
/// has to match one of the plan's steps, or one of its verification commands,
/// by executable path and argument array. A modifying one has to match a
/// reviewed ``ModifyingCommandRule`` as well, so appearing in a plan cannot by
/// itself authorize a shape of command MacUp has never vetted.
///
/// This is defense in depth rather than the only check: policy has already
/// decided the item may change and the planner has already built the commands.
/// The guard is what makes "MacUp only runs what it showed you" structural
/// instead of a convention, and it fails closed on anything unexpected.
public struct ExecutionGuard: CommandRunning {
    public var base: any CommandRunning
    /// The plan being executed. Nothing outside it runs.
    public var plan: ExecutionPlan
    /// Shapes a modifying command may take at all. An empty list means MacUp
    /// may run nothing modifying, which is the right answer for a provider
    /// whose commands have not been reviewed yet.
    public var modifyingRules: [ModifyingCommandRule]
    /// Read-only shapes permitted alongside the plan's own commands.
    ///
    /// Verification usually has to locate the provider again before it can
    /// read back a version, and those lookups are not part of the change the
    /// user reviewed. They are bounded by the same allowlist a check uses, so
    /// they still cannot modify anything. The list is empty by default, so
    /// while a plan's own steps run the plan really is the whole permitted set.
    public var readOnlyRules: [CommandRule]

    public init(
        base: any CommandRunning,
        plan: ExecutionPlan,
        modifyingRules: [ModifyingCommandRule] = ModifyingCommandRules.all,
        readOnlyRules: [CommandRule] = []
    ) {
        self.base = base
        self.plan = plan
        self.modifyingRules = modifyingRules
        self.readOnlyRules = readOnlyRules
    }

    public func run(_ request: CommandRequest, output: CommandOutputHandler?) async throws -> CommandResult {
        let display = Redactor().redact(request.invocation.displayString)
        func refuse(_ reason: String, suggestion: String? = nil) -> MacUpError {
            MacUpError(.policyDenied, reason, command: display, recoverySuggestion: suggestion)
        }

        switch request.effect {
        case .modifying:
            guard declaresStep(request) else {
                throw refuse("MacUp refused to run a change that was not in the plan it showed you.")
            }
            guard modifyingRules.contains(where: { $0.matches(request) }) else {
                throw refuse(
                    "MacUp refused to run a change it has not reviewed.",
                    suggestion: "The plan asked for a command that is not one of the changes MacUp allows itself to make. Please report this with the item's name."
                )
            }
        case .readOnly:
            guard declaresStep(request) || declaresVerification(request) || matchesReadOnlyRule(request) else {
                throw refuse("MacUp refused to run a command that was not in the plan it showed you.")
            }
        case .metadataRefresh:
            guard declaresStep(request) || matchesReadOnlyRule(request) else {
                throw refuse("MacUp refused to refresh provider metadata because the plan did not say it would.")
            }
        }
        return try await base.run(request, output: output)
    }

    /// Whether the plan declares this exact command with this exact effect.
    ///
    /// The effect has to match as well, so a command the plan presented as a
    /// change cannot be slipped past labelled read-only, or the other way
    /// round. Either would make the plan the user read a poor description of
    /// what happened.
    private func declaresStep(_ request: CommandRequest) -> Bool {
        plan.steps.contains { $0.invocation == request.invocation && $0.effect == request.effect }
    }

    /// Verification commands are read-only by definition, so they are only
    /// ever matched for a read-only request.
    private func declaresVerification(_ request: CommandRequest) -> Bool {
        plan.verification.contains { $0.invocation == request.invocation }
    }

    private func matchesReadOnlyRule(_ request: CommandRequest) -> Bool {
        readOnlyRules.contains { $0.matches(request) }
    }
}
