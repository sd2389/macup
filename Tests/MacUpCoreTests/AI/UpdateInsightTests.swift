import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("AI caution for updates")
struct UpdateInsightTests {
    static let key = "ts_test_not_a_real_key_0123456789"
    static let mysql = try! PackageID(parsing: "brew:mysql")

    static func candidate(_ installed: String = "8.4.3", _ available: String = "9.1.0", id: PackageID = mysql) -> UpdateCandidate {
        UpdateCandidate(id: id, kind: .formula, displayName: id.name, installedVersion: InstalledVersion(installed), availableVersion: AvailableVersion(available))
    }

    static func estimate(
        for candidate: UpdateCandidate,
        kind: SoftwareKind = .database,
        kindProbability: Double = 0.93,
        migrates: Double = 0.91
    ) -> AIEstimate {
        AIEstimate(
            item: candidate.id,
            installedVersion: candidate.installedVersion?.raw,
            availableVersion: candidate.availableVersion.raw,
            model: "jev-1.13.0",
            askedAt: Date(timeIntervalSince1970: 1_790_000_000),
            softwareKind: kind,
            softwareKindProbability: kindProbability,
            softwareKindConfidence: 0.9,
            dataMigrationProbability: migrates
        )
    }

    static let onConfiguration: LoadedConfiguration = {
        var configuration = MacUpConfiguration.defaults
        configuration.ai = MacUpConfiguration.AISettings(enabled: true)
        return LoadedConfiguration(configuration: configuration, source: .file, path: "/nowhere")
    }()

    // MARK: What is sent

    @Test("An estimate sends the package's ID, name, manager, kind, and versions, and nothing else")
    func whatIsSent() async throws {
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(choose: { id, _ in id == "software_kind" ? ("database", 0.93) : nil }, noul: { _ in 0.91 }))
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key), estimates: { _ in InMemoryAIEstimateCache() })
        _ = try await service.estimate(Self.candidate(), configuration: Self.onConfiguration, environment: [:], paths: .standard(homeDirectory: "/Users/example"))

        let body = try #require(transport.bodies.first)
        let package = try #require((body["state"] as? [String: Any])?["package"] as? [String: String])
        #expect(package == [
            "id": "brew:mysql",
            "name": "mysql",
            "packageManager": "Homebrew",
            "kind": "Homebrew formula",
            "installedVersion": "8.4.3",
            "availableVersion": "9.1.0",
        ])
        #expect(Set(((body["questions"] as? [String: Any]) ?? [:]).keys) == ["software_kind", "migrates_data"])
    }

    // MARK: Composing the caution

    @Test("A database meeting a major upgrade gets a labelled caution, with the probability behind it")
    func databaseMajor() throws {
        let candidate = Self.candidate()
        let caution = try #require(UpdateInsight.caution(for: candidate, estimate: Self.estimate(for: candidate)))
        #expect(caution.note == "AI estimate from TypeSafe, 91%: mysql looks like a database; a major upgrade may migrate its data on first start — back up first.")
        #expect(caution.probability == 0.91)
    }

    @Test("Only a confident judgment about a major, or unclassifiable, change produces anything")
    func onlyWhenItMatters() throws {
        let minor = Self.candidate("8.4.3", "8.5.0")
        #expect(UpdateInsight.caution(for: minor, estimate: Self.estimate(for: minor)) == nil)
        let major = Self.candidate()
        #expect(UpdateInsight.caution(for: major, estimate: Self.estimate(for: major, kind: .cliTool, kindProbability: 0.9, migrates: 0.3)) == nil)
        #expect(UpdateInsight.caution(for: major, estimate: Self.estimate(for: major, kindProbability: 0.6, migrates: 0.5)) == nil)

        let migratesOnly = try #require(UpdateInsight.caution(for: major, estimate: Self.estimate(for: major, kind: .service, kindProbability: 0.9, migrates: 0.88)))
        #expect(migratesOnly.note == "AI estimate from TypeSafe, 88%: a major upgrade of mysql may migrate or rewrite the data it keeps — back up first.")

        let unknown = Self.candidate("2024.1", "nightly")
        #expect(unknown.versionChange == .unknown)
        let unknownCaution = try #require(UpdateInsight.caution(for: unknown, estimate: Self.estimate(for: unknown)))
        #expect(unknownCaution.note.contains("if this is a major upgrade, it may migrate its data"))

        // An estimate for another version change says nothing about this one.
        let newer = Self.candidate("8.4.3", "10.0.0")
        #expect(UpdateInsight.caution(for: newer, estimate: Self.estimate(for: major)) == nil)
    }

    @Test("An estimate only ever adds caution: risk never goes down, and nothing already there is lost")
    func neverLowersRisk() throws {
        let rank: [RiskLevel: Int] = [.low: 0, .moderate: 1, .high: 2]
        let versions = [("1.0.0", "1.0.1"), ("1.0.0", "1.1.0"), ("1.0.0", "2.0.0"), ("2024.1", "nightly"), ("2.0.0", "1.0.0"), ("1.0.0", "1.1.0-beta.1")]
        let signalSets: [Set<RiskSignal>] = [[], [.runtimeOrToolchain], [.pinnedByProvider], [.restartRequired]]
        for (installed, available) in versions {
            for signals in signalSets {
                for kind in SoftwareKind.allCases {
                    for migrates in [0.0, 0.5, 0.95] {
                        let original = Self.candidate(installed, available).adding(signals: signals)
                        let applied = UpdateInsight.applying(Self.estimate(for: original, kind: kind, kindProbability: 0.95, migrates: migrates), to: original)
                        #expect(Set(applied.signals).isSuperset(of: Set(original.signals)))
                        #expect(Set(applied.notes).isSuperset(of: Set(original.notes)))
                        if original.risk.level == .unknown {
                            #expect(applied.risk.level == .unknown, "an unclassifiable change stays unknown, which always asks")
                        } else {
                            #expect(rank[applied.risk.level, default: 3] >= rank[original.risk.level, default: 3])
                        }
                        // What policy allows can only shrink.
                        for policy in [UpdatePolicy.auto, .ask, .ignore, .pin] {
                            var configuration = MacUpConfiguration.defaults
                            configuration.items[Self.mysql.rawValue] = MacUpConfiguration.ItemSettings(policy: policy)
                            configuration.global.confirmMajorUpdates = false
                            for intent in PolicyIntent.allCases {
                                let engine = PolicyEngine(configuration: configuration)
                                let before = engine.decide(original, intent: intent).action
                                let after = engine.decide(applied, intent: intent).action
                                let strictness: [PolicyDecision.Action: Int] = [.allow: 0, .confirm: 1, .deny: 2]
                                #expect(strictness[after]! >= strictness[before]!, "\(policy) \(intent) \(installed)→\(available)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("An Auto Update item with a caution waits for a person; unattended, it is left alone")
    func autoBecomesAskFirst() throws {
        var configuration = MacUpConfiguration.defaults
        configuration.items[Self.mysql.rawValue] = MacUpConfiguration.ItemSettings(policy: .auto)
        // Even with major updates allowed through, the caution holds.
        configuration.global.confirmMajorUpdates = false
        let engine = PolicyEngine(configuration: configuration)
        let original = Self.candidate()
        #expect(engine.decide(original, intent: .interactive).action == .allow)

        let cautioned = UpdateInsight.applying(Self.estimate(for: original), to: original)
        let interactive = engine.decide(cautioned, intent: .interactive)
        #expect(interactive.action == .confirm)
        #expect(interactive.escalated)
        #expect(interactive.reason == "An AI estimate from TypeSafe says updating mysql needs extra care, so it asks first.")
        #expect(engine.decide(cautioned, intent: .unattended).action == .deny)
        #expect(cautioned.notes.last?.hasPrefix("AI estimate from TypeSafe") == true)
    }

    // MARK: Keeping estimates

    @Test("An estimate is asked once per version change, kept on this Mac, and forgotten on request")
    func caching() async throws {
        let home = try TemporaryDirectory(prefix: "macup-ai-cache")
        let paths = MacUpPaths.standard(homeDirectory: home.canonicalPath)
        let transport = FakeTypeSafeTransport()
        transport.answerEveryRequest(TypeSafeReply.answering(choose: { id, _ in id == "software_kind" ? ("database", 0.93) : nil }, noul: { _ in 0.91 }))
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key), now: { clock })

        let first = try await service.estimate(Self.candidate(), configuration: Self.onConfiguration, environment: [:], paths: paths)
        #expect(!first.fromCache)
        #expect(first.caution != nil)
        #expect(first.estimate.model == "jev-1.13.0")
        #expect(transport.requests.count == 1)

        let file = paths.stateDirectory + "/" + AIEstimateFile.fileName
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let second = try await service.estimate(Self.candidate(), configuration: Self.onConfiguration, environment: [:], paths: paths)
        #expect(second.fromCache)
        #expect(second.estimate == first.estimate)
        #expect(transport.requests.count == 1, "the same version change is not sent twice")

        _ = try await service.estimate(Self.candidate("8.4.3", "9.2.0"), configuration: Self.onConfiguration, environment: [:], paths: paths)
        _ = try await service.estimate(Self.candidate(), configuration: Self.onConfiguration, environment: [:], paths: paths, refresh: true)
        #expect(transport.requests.count == 3)
        #expect(try AIEstimateFile(paths: paths).load().count == 2, "asking again replaces, it does not duplicate")

        // Saved cautions shape a report only while AI help is on.
        let report = CheckReport(
            mode: .readOnly, startedAt: clock, finishedAt: clock, cancelled: false,
            configuration: ConfigurationSummary(Self.onConfiguration), providers: [],
            updates: [Self.candidate()], commands: []
        )
        let (on, problem) = service.cautioned(report, configuration: Self.onConfiguration, paths: paths)
        #expect(problem == nil)
        #expect(on.updates.first?.signals.contains(.aiCaution) == true)
        let off = LoadedConfiguration(configuration: .defaults, source: .file, path: "/nowhere")
        #expect(service.cautioned(report, configuration: off, paths: paths).report == report)

        #expect(try service.forgetEstimates(paths: paths) == 2)
        #expect(!FileManager.default.fileExists(atPath: file))
        #expect(service.cautioned(report, configuration: Self.onConfiguration, paths: paths).report == report)
    }

    @Test("With AI help off, even a saved estimate is not used and nothing is sent")
    func offUsesNothing() async throws {
        let transport = FakeTypeSafeTransport()
        let cache = InMemoryAIEstimateCache([Self.estimate(for: Self.candidate())])
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key), estimates: { _ in cache })
        let off = LoadedConfiguration(configuration: .defaults, source: .defaults, path: "/nowhere")
        let error = await #expect(throws: AIError.self) {
            _ = try await service.estimate(Self.candidate(), configuration: off, environment: [:], paths: .standard(homeDirectory: "/Users/example"))
        }
        #expect(error?.kind == .disabled)
        #expect(transport.requests.isEmpty)
    }

    @Test("macOS updates are never sent: they always wait for you anyway")
    func macOSIsNotAsked() async throws {
        let transport = FakeTypeSafeTransport()
        let service = AIService(transport: transport, keyStore: FakeAPIKeyStore(key: Self.key), estimates: { _ in InMemoryAIEstimateCache() })
        let update = UpdateCandidate(
            id: try PackageID(parsing: "macos:macOS 27.2-26B5091g"), kind: .systemUpdate, displayName: "macOS 27.2",
            installedVersion: "27.0", availableVersion: "27.2"
        )
        await #expect(throws: AIError.self) {
            _ = try await service.estimate(update, configuration: Self.onConfiguration, environment: [:], paths: .standard(homeDirectory: "/Users/example"))
        }
        #expect(transport.requests.isEmpty)
    }
}
