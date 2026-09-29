import Foundation
import Testing

@testable import MacUpCore

@Suite("Running services and database data in the risk model")
struct ServiceAndDataRiskTests {
    @Test("A running service raises a small change to moderate; a database's data raises anything to high")
    func levels() {
        #expect(RiskAssessor.assess(change: .patch, signals: [.runsAsService]).level == .moderate)
        #expect(RiskAssessor.assess(change: .minor, signals: [.runsAsService]).level == .moderate)
        #expect(RiskAssessor.assess(change: .patch, signals: [.mayMigrateData]).level == .high)
        #expect(RiskAssessor.assess(change: .unknown, signals: [.mayMigrateData]).level == .high)
        #expect(RiskAssessor.assess(change: .unknown, signals: [.runsAsService]).level == .unknown, "unknown stays unknown")
        let reasons = RiskAssessor.assess(change: .major, signals: [.runsAsService, .mayMigrateData]).reasons
        #expect(reasons.contains(RiskSignal.runsAsService.explanation))
        #expect(reasons.contains(RiskSignal.mayMigrateData.explanation))
    }

    @Test("A database that may convert its data always waits for a person, whatever confirmMajorUpdates says")
    func databaseAlwaysAsks() throws {
        var configuration = MacUpConfiguration.defaults
        configuration.global.confirmMajorUpdates = false
        configuration.items["brew:mysql"] = .init(policy: .auto)
        let engine = PolicyEngine(configuration: configuration)
        let item = try PackageID(.brew, "mysql")
        let risk = RiskAssessor.assess(change: .major, signals: [.mayMigrateData])

        let interactive = engine.decide(item: item, risk: risk, signals: [.mayMigrateData], intent: .interactive)
        #expect(interactive.action == .confirm)
        #expect(interactive.escalated)
        #expect(interactive.reason.contains("may convert your data files for good"))
        #expect(engine.decide(item: item, risk: risk, signals: [.mayMigrateData], intent: .unattended).action == .deny)

        // A running service on its own is not a reason to stop an Auto Update.
        let moderate = RiskAssessor.assess(change: .patch, signals: [.runsAsService])
        #expect(engine.decide(item: item, risk: moderate, signals: [.runsAsService], intent: .unattended).action == .allow)
    }

    @Test("Databases are recognized by name, across taps and versioned formulae, and number their majors their own way")
    func catalog() {
        for name in ["mysql", "mysql@8.4", "mariadb", "percona-server", "postgresql@16", "mongodb/brew/mongodb-community", "redis", "valkey"] {
            #expect(RuntimeCatalog.isDatabase(name), "\(name)")
        }
        for name in ["mysql-client", "libpq", "sqlite", "git", "redis-cli"] {
            #expect(!RuntimeCatalog.isDatabase(name), "\(name)")
        }
        func change(_ name: String, _ from: String, _ to: String) -> VersionChange {
            VersionComparator.classify(from: from, to: to, scheme: RuntimeCatalog.versionScheme(for: name))
        }
        #expect(change("mysql", "8.0.40", "8.4.3") == .major)
        #expect(change("mysql", "8.4.2", "8.4.3") == .patch)
        #expect(change("redis", "7.2.4", "7.4.0") == .major)
        #expect(change("postgresql@16", "16.4", "16.6") == .minor)
        #expect(change("postgresql", "16.4", "17.0") == .major)
    }
}
