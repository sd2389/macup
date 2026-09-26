import Testing

@testable import MacUpCore

@Suite("RiskAssessor")
struct RiskAssessorTests {
    @Test(
        "Version changes map to coarse levels",
        arguments: [
            (VersionChange.patch, RiskLevel.low),
            (.build, .low),
            (.revision, .low),
            (.minor, .moderate),
            (.major, .high),
            (.prerelease, .high),
            (.downgrade, .high),
            (.none, .unknown),
            (.unknown, .unknown),
        ]
    )
    func versionChangeLevels(change: VersionChange, expected: RiskLevel) {
        #expect(RiskAssessor.assess(change: change, signals: []).level == expected)
    }

    @Test("Signals raise risk to their minimum level")
    func signalsRaiseRisk() {
        #expect(RiskAssessor.assess(change: .patch, signals: [.runtimeOrToolchain]).level == .moderate)
        #expect(RiskAssessor.assess(change: .patch, signals: [.restartRequired]).level == .high)
        #expect(RiskAssessor.assess(change: .minor, signals: [.packageManagerSelfUpdate]).level == .moderate)
        #expect(RiskAssessor.assess(change: .patch, signals: [.pinnedByProvider]).level == .high)
    }

    @Test("Unknown stays unknown unless a signal makes it high risk regardless")
    func unknownHandling() {
        #expect(RiskAssessor.assess(change: .unknown, signals: [.runtimeOrToolchain]).level == .unknown)
        #expect(RiskAssessor.assess(change: .unknown, signals: [.operatingSystemUpdate]).level == .high)
    }

    @Test("Reasons explain the level")
    func reasons() {
        let assessment = RiskAssessor.assess(change: .minor, signals: [.restartRequired, .operatingSystemUpdate])
        #expect(assessment.reasons == ["Minor version change", "Updates the operating system", "Requires a restart"])
    }

    @Test("Candidates compute their change and risk, and re-assess when signals are added")
    func candidateAssessment() throws {
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "brew:git"),
            kind: .formula,
            displayName: "git",
            installedVersion: "2.43.0",
            availableVersion: "2.43.1"
        )
        #expect(candidate.versionChange == .patch)
        #expect(candidate.risk.level == .low)
        let pinned = candidate.adding(signals: [.pinnedByProvider], notes: ["Pinned in Homebrew."])
        #expect(pinned.risk.level == .high)
        #expect(pinned.signals == [.pinnedByProvider])
        #expect(pinned.notes == ["Pinned in Homebrew."])
    }

    @Test("A missing installed version is an unclassified change")
    func missingInstalledVersion() throws {
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "macos:Safari18.1-18.1"),
            kind: .systemUpdate,
            displayName: "Safari",
            installedVersion: nil,
            availableVersion: "18.1"
        )
        #expect(candidate.versionChange == .unknown)
        #expect(candidate.risk.level == .unknown)
    }
}
