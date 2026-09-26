import Foundation
import Testing

@testable import MacUpCore

@Suite("Model encoding and decoding")
struct ModelCodingTests {
    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: encoder.encode(value))
    }

    private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let date = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Update candidates round-trip and use stable keys")
    func candidate() throws {
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "npm:@anthropic-ai/claude-code"),
            kind: .globalPackage,
            displayName: "@anthropic-ai/claude-code",
            installedVersion: "2.1.282",
            availableVersion: "2.1.283",
            ownership: OwnershipChain([OwnershipLink(label: "npm 11.17.0", path: "/usr/local/bin/npm")]),
            notes: ["A note."],
            details: ["location": "/usr/local/lib/node_modules/@anthropic-ai/claude-code"]
        )
        #expect(try roundTrip(candidate) == candidate)
        let object = try jsonObject(candidate)
        #expect(object["id"] as? String == "npm:@anthropic-ai/claude-code")
        #expect(object["installedVersion"] as? String == "2.1.282")
        #expect(object["availableVersion"] as? String == "2.1.283")
        #expect(object["versionChange"] as? String == "patch")
        #expect((object["risk"] as? [String: Any])?["level"] as? String == "low")
    }

    @Test("Items, statuses, and findings round-trip")
    func statusAndItems() throws {
        let item = ManagedItem(
            id: try PackageID(parsing: "mise:node"),
            kind: .tool,
            displayName: "node",
            installedVersions: ["24.18.0", "24.19.0"],
            activeVersion: "24.19.0",
            details: ["requestedVersion": "24"]
        )
        #expect(try roundTrip(item) == item)

        let status = ProviderStatus(
            provider: .homebrew,
            availability: .available,
            installation: ProviderInstallation(
                executable: ResolvedExecutable(path: "/opt/homebrew/bin/brew", canonicalPath: "/opt/homebrew/bin/brew", source: .searchPath),
                version: "4.4.2",
                facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/opt/homebrew")]
            ),
            findings: [DiagnosticFinding(id: "homebrew.multipleInstallations", severity: .warning, provider: .homebrew, title: "Two installs")],
            error: MacUpError(.commandFailed, "Something failed.", exitStatus: 1)
        )
        #expect(try roundTrip(status) == status)
        #expect(status.installation?.fact("prefix") == "/opt/homebrew")
    }

    @Test("Plans, results, verification, and history round-trip")
    func executionModels() throws {
        let id = try PackageID(parsing: "brew:git")
        let plan = ExecutionPlan(
            createdAt: date,
            item: id,
            currentVersion: "2.43.0",
            proposedVersion: "2.44.0",
            risk: RiskAssessment(level: .moderate, reasons: ["Minor version change"]),
            rationale: "Selected by the user.",
            steps: [ExecutionStep(
                summary: "Upgrade git",
                invocation: CommandInvocation(executable: "/opt/homebrew/bin/brew", arguments: ["upgrade", "git"]),
                effect: .modifying,
                expectsNetwork: true,
                mayRequirePrivilege: false,
                timeoutSeconds: 600
            )],
            expectsNetwork: true,
            mayRequirePrivilege: false,
            mayRequireRestart: false,
            mayChangeUserConfiguration: false,
            verification: [VerificationStep(summary: "Check the installed version", expectedVersion: "2.44.0")],
            rollback: .notImplemented
        )
        #expect(try roundTrip(plan) == plan)

        let result = ExecutionResult(
            planID: plan.id,
            item: id,
            outcome: .failed,
            startedAt: date,
            finishedAt: date.addingTimeInterval(3),
            steps: [.init(command: "/opt/homebrew/bin/brew upgrade git", exitStatus: 1, durationSeconds: 3, errorExcerpt: "Error")],
            error: MacUpError(.commandFailed, "Upgrade failed.")
        )
        #expect(try roundTrip(result) == result)

        let verification = VerificationResult(item: id, outcome: .targetNotReached, expectedVersion: "2.44.0", observedVersion: "2.43.0", message: "Still 2.43.0.")
        #expect(try roundTrip(verification) == verification)

        let entry = HistoryEntry(
            timestamp: date,
            origin: .cli,
            item: id,
            versionBefore: "2.43.0",
            versionTarget: "2.44.0",
            versionAfter: "2.43.0",
            command: "/opt/homebrew/bin/brew upgrade git",
            outcome: .failed,
            verification: .targetNotReached,
            errorSummary: "Upgrade failed.",
            durationSeconds: 3
        )
        #expect(try roundTrip(entry) == entry)
        #expect(try jsonObject(entry)["schemaVersion"] as? Int == 1)
    }

    @Test("Enumerations encode as their documented raw values")
    func rawValues() {
        #expect(UpdatePolicy.allCases.map(\.rawValue) == ["auto", "ask", "ignore", "pin", "inherit"])
        #expect(RiskLevel.allCases.map(\.rawValue) == ["low", "moderate", "high", "unknown"])
        #expect(MacUpError.Kind.allCases.count == 11)
        #expect(ProviderID.known.map(\.rawValue) == ["homebrew", "npm", "mise", "macos"])
    }
}
