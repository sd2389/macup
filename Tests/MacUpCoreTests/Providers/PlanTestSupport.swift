import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

/// A fixed instant, so a plan built twice from the same check is the same plan.
let planningInstant = Date(timeIntervalSince1970: 1_790_000_000)

extension ProviderHarness {
    /// A context bound to the detected installation, with a fixed clock.
    func planningContext(_ provider: some UpdateProvider) async throws -> ProviderContext {
        var context = try await detectedContext(provider)
        context.now = { planningInstant }
        return context
    }
}

extension ExecutionPlan {
    /// The one step of a single-step plan.
    var onlyStep: ExecutionStep {
        get throws { try #require(steps.count == 1 ? steps.first : nil, "expected exactly one step") }
    }

    /// The executable and arguments a reviewer would see.
    var command: (executable: String, arguments: [String]) {
        get throws {
            let step = try onlyStep
            return (step.invocation.executable, step.invocation.arguments)
        }
    }
}

/// Asserts that every step of a plan matches a rule in
/// ``ModifyingCommandRules/all``, as the execution guard will require.
func expectAllowedByRules(_ plan: ExecutionPlan, sourceLocation: SourceLocation = #_sourceLocation) {
    for step in plan.steps {
        let request = CommandRequest(
            executable: URL(fileURLWithPath: step.invocation.executable),
            arguments: step.invocation.arguments,
            effect: step.effect
        )
        #expect(
            ModifyingCommandRules.all.contains { $0.matches(request) },
            "no rule allows \(step.invocation.displayString)",
            sourceLocation: sourceLocation
        )
    }
}

/// Every plan a provider will build for the candidates in a fixture, so a
/// test can assert a property across all of them at once.
func plans(
    _ provider: some UpdateProvider,
    for candidates: [UpdateCandidate],
    context: ProviderContext
) async -> [Result<ExecutionPlan, any Error>] {
    var results: [Result<ExecutionPlan, any Error>] = []
    for candidate in candidates {
        do {
            results.append(.success(try await provider.makePlan(for: candidate, context: context)))
        } catch {
            results.append(.failure(error))
        }
    }
    return results
}
