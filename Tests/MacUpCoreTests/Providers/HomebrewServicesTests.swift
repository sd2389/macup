import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Homebrew services parser")
struct HomebrewServicesParserTests {
    private func listed(_ fixture: String) throws -> (services: [String: HomebrewService], unreadable: Set<String>, findings: [DiagnosticFinding]) {
        guard case .listed(let services, let unreadable, let findings) = try HomebrewServicesParser.parse(Fixture.data(fixture)) else {
            Issue.record("expected a listing")
            return ([:], [], [])
        }
        return (services, unreadable, findings)
    }

    @Test("Real `brew services list --json` output (Homebrew 7.0.6)")
    func realCapture() throws {
        let listing = try listed("homebrew/services-list.json")
        #expect(listing.services.keys.sorted() == ["colima", "mysql", "postgresql@16", "postgresql@18", "redis"])
        #expect(listing.services["mysql"] == HomebrewService(status: "started", exitCode: nil, runsAsRoot: false))
        #expect(listing.services["colima"]?.status == "none")
        #expect(listing.unreadable.isEmpty)
        #expect(listing.findings.isEmpty)
    }

    @Test("Every status Homebrew uses, a root service, an exit code, and entries MacUp cannot read")
    func statuses() throws {
        let listing = try listed("homebrew/services-statuses.json")
        #expect(listing.services["certbot"]?.status == "scheduled")
        #expect(listing.services["unbound"] == HomebrewService(status: "started", exitCode: nil, runsAsRoot: true))
        #expect(listing.services["nginx"] == HomebrewService(status: "error", exitCode: 78, runsAsRoot: false))
        #expect(listing.services["dnsmasq"]?.status == "stopped")
        #expect(listing.services["memcached"]?.status == "other")
        // A status MacUp does not know is not guessed at in either direction.
        #expect(listing.services["rabbitmq"] == nil)
        #expect(listing.unreadable == ["rabbitmq"])
        #expect(listing.findings.map(\.id) == ["homebrew.unreadableEntry", "homebrew.unreadableEntry"])
    }

    @Test("No services at all is an empty list, not a failure")
    func none() throws {
        guard case .listed(let services, let unreadable, _) = try HomebrewServicesParser.parse(Data("[]\n".utf8)) else {
            Issue.record("expected a listing")
            return
        }
        #expect(services.isEmpty)
        #expect(unreadable.isEmpty)
    }

    @Test("Output that is not the expected JSON fails closed", arguments: ["homebrew/services-malformed.txt", "homebrew/services-wrong-shape.json"])
    func unreadable(fixture: String) throws {
        let error = #expect(throws: MacUpError.self) { try HomebrewServicesParser.parse(Fixture.data(fixture)) }
        #expect(error?.kind == .parseFailed)
    }

    @Test("Two different answers for one formula are treated as no answer")
    func contradictoryEntries() throws {
        let json = #"[{"name": "redis", "status": "started"}, {"name": "redis", "status": "stopped"}]"#
        guard case .listed(let services, let unreadable, _) = try HomebrewServicesParser.parse(Data(json.utf8)) else {
            Issue.record("expected a listing")
            return
        }
        #expect(services["redis"] == nil)
        #expect(unreadable == ["redis"])
    }
}

/// A Homebrew in a custom prefix that runs mysql, postgresql@16, and redis as
/// services, with an update waiting for each.
@Suite("Homebrew services during a check")
struct HomebrewServicesCheckTests {
    let provider = HomebrewProvider()
    static let prefix = "/Users/example/.homebrew"

    private func harness(services: FakeCommandRunner.Response? = .success(try! Fixture.text("homebrew/services-list.json")), builtIn: Bool = true) -> ProviderHarness {
        let harness = ProviderHarness(path: Self.prefix + "/bin:/usr/bin:/bin")
        harness.fileSystem.addExecutable(Self.prefix + "/bin/brew")
        if builtIn { harness.fileSystem.addFile(Self.prefix + "/Library/Homebrew/cmd/services.rb") }
        harness.runner.register("brew", ["--version"], .success("Homebrew 7.0.6\n"))
        harness.runner.register("brew", ["--prefix"], .success(Self.prefix + "\n"))
        harness.runner.register("brew", HomebrewProvider.installedInfoArguments, .success(try! Fixture.text("homebrew/info-services.json")))
        harness.runner.register("brew", ["outdated", "--json=v2"], .success(try! Fixture.text("homebrew/outdated-services.json")))
        if let services { harness.runner.register("brew", HomebrewProvider.servicesArguments, services) }
        return harness
    }

    private func check(_ harness: ProviderHarness) async throws -> (items: ProviderListing<ManagedItem>, updates: [String: UpdateCandidate]) {
        let context = try await harness.detectedContext(provider)
        let inventory = try await provider.inventory(context: context)
        let candidates = provider.refine(try await provider.outdated(context: context).elements, using: inventory.elements)
        return (inventory, Dictionary(uniqueKeysWithValues: candidates.map { ($0.id.rawValue, $0) }))
    }

    @Test("The inventory records each formula's service state, through the allowlisted command")
    func inventoryRecordsServiceState() async throws {
        let harness = harness()
        let (inventory, _) = try await check(harness)
        let status = Dictionary(uniqueKeysWithValues: inventory.elements.map { ($0.id.rawValue, $0.details["serviceStatus"]) })
        #expect(status["brew:mysql"] == "started")
        #expect(status["brew:colima"] == "none")
        #expect(status["brew:jq"] == .some(nil), "jq defines no service")
        #expect(inventory.findings.isEmpty)
        let request = try #require(harness.requests.first { $0.arguments == HomebrewProvider.servicesArguments })
        #expect(request.effect == .readOnly)
        #expect(request.environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test("A running database getting a new major version is high risk, says what happens, and says to back up")
    func runningDatabaseMajor() async throws {
        let mysql = try #require(try await check(harness()).updates["brew:mysql"])
        #expect(mysql.versionChange == .major, "MySQL counts 8.0 → 8.4 as a new release series")
        #expect(mysql.signals.contains(.runsAsService))
        #expect(mysql.signals.contains(.mayMigrateData))
        #expect(mysql.risk.level == .high)
        #expect(mysql.details["serviceStatus"] == "started")
        #expect(mysql.notes.contains { $0.contains("running now as a Homebrew service") && $0.contains("keeps running the old version until it restarts") })
        #expect(mysql.notes.contains { $0.contains("MacUp never restarts services") && $0.contains("`brew services restart mysql`") })
        #expect(mysql.notes.contains { $0.contains("mysql is a database") && $0.contains("cannot be undone") && $0.contains("Back up your data before you upgrade") })
    }

    @Test("A running service on a minor or patch update is moderate risk, and a database there is not warned about its data")
    func runningServicesWithoutMajorChange() async throws {
        let updates = try await check(harness()).updates
        let postgres = try #require(updates["brew:postgresql@16"])
        #expect(postgres.versionChange == .minor, "PostgreSQL's major version is its first number")
        #expect(postgres.signals.contains(.runsAsService))
        #expect(!postgres.signals.contains(.mayMigrateData))
        #expect(postgres.risk.level == .moderate)

        let redis = try #require(updates["brew:redis"])
        #expect(redis.versionChange == .patch)
        #expect(redis.risk.level == .moderate, "a patch would be low risk, but the service is running")
        #expect(!redis.notes.contains { $0.contains("is a database") })

        let colima = try #require(updates["brew:colima"])
        #expect(colima.signals.isEmpty, "a service that is not registered is not running")
        #expect(colima.risk.level == .low)
        #expect(colima.details["serviceStatus"] == nil)
        #expect(try #require(updates["brew:jq"]).notes.isEmpty)
    }

    @Test("Without a built-in `brew services`, MacUp does not run it and says it cannot tell")
    func noBuiltInServices() async throws {
        let harness = harness(services: nil, builtIn: false)
        let (inventory, updates) = try await check(harness)
        #expect(!harness.requests.contains { $0.arguments.first == "services" }, "running it could add a tap")
        let finding = try #require(inventory.findings.first { $0.id == "homebrew.servicesUnreadable" })
        #expect(finding.severity == .info)
        #expect(finding.detail?.contains("homebrew/services tap") == true)
        let mysql = try #require(updates["brew:mysql"])
        #expect(!mysql.signals.contains(.runsAsService))
        #expect(mysql.notes.contains { $0.contains("could not read from Homebrew whether mysql runs as a service") })
        #expect(try #require(updates["brew:jq"]).notes.isEmpty, "jq defines no service, so there is nothing unknown about it")
    }

    @Test("A tapped homebrew/services is used where Homebrew has none built in")
    func tappedServices() async throws {
        let harness = harness(builtIn: false)
        harness.fileSystem.addFile(Self.prefix + "/Library/Taps/homebrew/homebrew-services/cmd/services.rb")
        let mysql = try #require(try await check(harness).updates["brew:mysql"])
        #expect(mysql.signals.contains(.runsAsService))
    }

    @Test(
        "A failing or unreadable services list is a warning and makes the state unknown, never \"not running\"",
        arguments: [
            FakeCommandRunner.Response.exit(1, standardError: "Error: `brew services` cannot run under tmux!\n"),
            FakeCommandRunner.Response.success("Name Status User File\n"),
        ]
    )
    func servicesFailure(response: FakeCommandRunner.Response) async throws {
        let (inventory, updates) = try await check(harness(services: response))
        #expect(inventory.elements.count == 5, "the rest of the inventory is still read")
        let finding = try #require(inventory.findings.first { $0.id == "homebrew.servicesUnreadable" })
        #expect(finding.severity == .warning)
        for id in ["brew:mysql", "brew:postgresql@16", "brew:redis"] {
            let update = try #require(updates[id])
            #expect(!update.signals.contains(.runsAsService))
            #expect(update.notes.contains { $0.contains("cannot say whether this upgrade would change one that is running") })
        }
    }

    @Test("A formula that defines a service but is missing from the list is unknown")
    func missingFromList() async throws {
        let (inventory, _) = try await check(harness(services: .success(#"[{"name": "colima", "status": "none"}]"#)))
        let mysql = try #require(inventory.elements.first { $0.id.rawValue == "brew:mysql" })
        #expect(mysql.details["serviceStatus"] == nil)
        #expect(mysql.details["serviceStatusUnknown"] == "true")
    }
}

@Suite("Homebrew service and data notes")
struct HomebrewServiceImpactTests {
    private func item(_ name: String, _ details: [String: String]) -> ManagedItem {
        ManagedItem(id: try! PackageID(.brew, name), kind: .formula, displayName: name, installedVersions: ["1.0"], activeVersion: "1.0", details: details)
    }

    @Test("A service registered for the whole Mac is restarted with sudo")
    func rootService() {
        let impact = HomebrewProvider.serviceImpact(of: item("unbound", ["serviceStatus": "started", "serviceRunsAsRoot": "true"]))
        #expect(impact.signals == [.runsAsService])
        #expect(impact.notes.first?.contains("`sudo brew services restart unbound`") == true)
        #expect(impact.notes.first?.contains("when you restart your Mac") == true)
    }

    @Test("Scheduled, failed, and stopped services are described, without the running-service signal")
    func otherStatuses() {
        let scheduled = HomebrewProvider.serviceImpact(of: item("certbot", ["serviceStatus": "scheduled"]))
        #expect(scheduled.signals.isEmpty)
        #expect(scheduled.notes.first?.contains("next run after the upgrade uses the new version") == true)
        let failed = HomebrewProvider.serviceImpact(of: item("nginx", ["serviceStatus": "error", "serviceExitCode": "78"]))
        #expect(failed.signals.isEmpty)
        #expect(failed.notes.first?.contains("ended with an error (exit code 78)") == true)
        let stopped = HomebrewProvider.serviceImpact(of: item("dnsmasq", ["serviceStatus": "stopped"]))
        #expect(stopped.notes.first?.contains("Homebrew reports it as stopped") == true)
        #expect(HomebrewProvider.serviceImpact(of: item("colima", ["serviceStatus": "none"])).notes.isEmpty)
    }

    @Test("A name a shell would read differently is never put in a command to copy")
    func unusualName() {
        let impact = HomebrewProvider.serviceImpact(of: item("tool$(touch x)", ["serviceStatus": "started"]))
        #expect(impact.notes.first?.contains("brew services restart tool") == false)
        #expect(impact.notes.first?.contains("with `brew services restart`.") == true)
    }

    @Test("A database whose version change MacUp cannot classify is treated as a possible major change")
    func unclassifiableDatabaseChange() {
        let candidate = UpdateCandidate(
            id: try! PackageID(.brew, "mongodb/brew/mongodb-community"), kind: .formula,
            displayName: "mongodb/brew/mongodb-community", installedVersion: "7.0-rc", availableVersion: "latest"
        )
        let refined = HomebrewProvider.addingDataImpact(candidate)
        #expect(refined.versionChange == .unknown)
        #expect(refined.signals.contains(.mayMigrateData))
        #expect(refined.risk.level == .high)
        #expect(refined.notes.first?.contains("cannot tell whether this is a new major version") == true)
    }

    @Test("Only databases, and only across a major version, get the data note")
    func onlyDatabases() {
        func candidate(_ name: String, _ from: String, _ to: String) -> UpdateCandidate {
            UpdateCandidate(
                id: try! PackageID(.brew, name), kind: .formula, displayName: name,
                installedVersion: InstalledVersion(from), availableVersion: AvailableVersion(to),
                versionScheme: RuntimeCatalog.versionScheme(for: name)
            )
        }
        #expect(HomebrewProvider.addingDataImpact(candidate("redis", "7.2.4", "7.4.0")).signals == [.mayMigrateData])
        #expect(HomebrewProvider.addingDataImpact(candidate("redis", "7.2.4", "7.2.5")).signals.isEmpty)
        #expect(HomebrewProvider.addingDataImpact(candidate("postgresql@16", "16.4", "16.6")).signals.isEmpty)
        #expect(HomebrewProvider.addingDataImpact(candidate("git", "2.44.0", "3.0.0")).signals.isEmpty)
    }
}
