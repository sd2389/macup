import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("softwareupdate parser")
struct SoftwareUpdateParserTests {
    private func parse(_ stdout: String, _ stderr: String = "") throws -> (entries: [SoftwareUpdateEntry], findings: [DiagnosticFinding]) {
        try SoftwareUpdateParser.parse(standardOutput: stdout, standardError: stderr)
    }

    @Test("Real output from macOS 27, with and without a fresh scan", arguments: [
        "macos/list-one-update.txt", "macos/list-scan-one-update.txt",
    ])
    func realOutput(fixture: String) throws {
        let result = try parse(try Fixture.text(fixture))
        #expect(result.findings.isEmpty)
        let entry = try #require(result.entries.first)
        #expect(result.entries.count == 1)
        #expect(entry.label == "macOS 27.2 Beta-26B5091g")
        #expect(entry.title == "macOS 27.2 Beta")
        #expect(entry.version == "27.2")
        #expect(entry.sizeKiB == 5_935_245)
        #expect(entry.recommended == true)
        #expect(entry.action == "restart")
        #expect(entry.requiresRestart)
        #expect(entry.isOperatingSystemUpdate)
        #expect(entry.isBeta)
    }

    @Test("No updates (the message arrives on stderr)")
    func noUpdates() throws {
        let result = try parse(try Fixture.text("macos/list-no-updates.stdout.txt"), try Fixture.text("macos/list-no-updates.stderr.txt"))
        #expect(result.entries.isEmpty)
        #expect(result.findings.isEmpty)
    }

    @Test("Several updates: OS, Safari, Command Line Tools, and a title containing a comma")
    func multiple() throws {
        let result = try parse(try Fixture.text("macos/list-multiple.txt"))
        #expect(result.findings.isEmpty)
        #expect(result.entries.map(\.title) == [
            "macOS Sequoia 15.4.1", "Safari", "Command Line Tools for Xcode", "Printer Driver Update, Canon",
        ])
        #expect(result.entries.map(\.isOperatingSystemUpdate) == [true, false, false, false])
        #expect(result.entries.map(\.requiresRestart) == [true, false, false, false])
        #expect(result.entries[3].recommended == false)
        #expect(result.entries[3].otherFields == ["Deferred": "YES"])
    }

    @Test("Unrecognized or legacy output is an error, never fabricated state", arguments: [
        "macos/list-unrecognized.txt", "macos/list-legacy-format.txt",
    ])
    func unrecognized(fixture: String) throws {
        let error = #expect(throws: MacUpError.self) { try parse(try Fixture.text(fixture)) }
        #expect(error?.kind == .parseFailed)
    }

    @Test("An entry without details becomes a finding; the rest still parse")
    func missingDetails() throws {
        let result = try parse(try Fixture.text("macos/list-missing-details.txt"))
        #expect(result.entries.map(\.label) == ["macOS 27.2-26C100"])
        #expect(result.findings.map(\.id) == ["macos.unreadableUpdate"])
    }

    @Test("Detail lines need a title and a version")
    func detailLines() {
        #expect(SoftwareUpdateParser.entry(label: "x", details: "Title: Thing, Version: 1.0,") != nil)
        #expect(SoftwareUpdateParser.entry(label: "x", details: "Title: Thing, Size: 10KiB,") == nil)
        #expect(SoftwareUpdateParser.entry(label: "x", details: "Version: 1.0, Title: Thing,") == nil)
        #expect(SoftwareUpdateParser.entry(label: "x", details: "garbage") == nil)
        let odd = SoftwareUpdateParser.entry(label: "x", details: "Title: Thing, Version: 2, Size: lots, Recommended: no")
        #expect(odd?.sizeKiB == nil)
        #expect(odd?.recommended == false)
    }
}

@Suite("macOS provider")
struct MacOSProviderTests {
    let provider = MacOSProvider(softwareUpdatePath: "/usr/sbin/softwareupdate")

    private func harness() -> ProviderHarness {
        let harness = ProviderHarness()
        harness.fileSystem.addExecutable("/usr/sbin/softwareupdate")
        return harness
    }

    @Test("Detection uses the fixed system path and reports the OS version without running anything")
    func detection() async {
        let harness = harness()
        let status = await provider.detect(context: harness.context())
        #expect(status.availability == .available)
        #expect(status.installation?.version == "27.0")
        #expect(status.installation?.fact("build") == "26A428")
        #expect(harness.requests.isEmpty)

        let missing = await provider.detect(context: ProviderHarness().context())
        #expect(missing.availability == .unavailable)
    }

    @Test("A normal check reads the last scan; only --refresh scans")
    func scanOnlyOnRefresh() async throws {
        let harness = harness()
        let output = try Fixture.text("macos/list-one-update.txt")
        harness.runner.register("softwareupdate", ["--list", "--no-scan"], .success(output))
        harness.runner.register("softwareupdate", ["--list"], .success(output))

        _ = try await provider.outdated(context: harness.detectedContext(provider))
        harness.refreshMetadata = true
        _ = try await provider.outdated(context: harness.detectedContext(provider))
        #expect(harness.arguments(for: "softwareupdate") == [["--list", "--no-scan"], ["--list"]])
        #expect(harness.requests.allSatisfy { $0.workingDirectory?.path == "/" && $0.effect == .readOnly })
    }

    @Test("OS updates are high risk, need a restart, and are review-only")
    func candidates() async throws {
        let harness = harness()
        harness.runner.register("softwareupdate", ["--list", "--no-scan"], .success(try Fixture.text("macos/list-multiple.txt")))
        let listing = try await provider.outdated(context: harness.detectedContext(provider))
        #expect(listing.elements.count == 4)

        let os = listing.elements[0]
        #expect(os.id.rawValue == "macos:macOS Sequoia 15.4.1-24E263")
        #expect(os.installedVersion == "27.0")
        #expect(Set(os.signals) == [.operatingSystemUpdate, .restartRequired])
        #expect(os.risk.level == .high)
        #expect(os.notes.first?.contains("System Settings") == true)

        let safari = listing.elements[1]
        #expect(safari.installedVersion == nil)
        #expect(safari.risk.level == .unknown)
        #expect(listing.elements[3].notes.contains("Apple does not mark this update as recommended."))
    }

    @Test("A failing softwareupdate is an error")
    func failure() async throws {
        let harness = harness()
        harness.runner.register("softwareupdate", ["--list", "--no-scan"], .exit(1, standardError: "Error: cannot contact server\n"))
        let context = try await harness.detectedContext(provider)
        let error = await #expect(throws: MacUpError.self) { try await provider.outdated(context: context) }
        #expect(error?.kind == .commandFailed)
    }

    @Test("macOS reports no inventory and never runs an install")
    func noInventory() async throws {
        let harness = harness()
        #expect(try await provider.inventory(context: harness.context()).elements.isEmpty)
        #expect(!provider.capabilities.contains(.inventory))
        #expect(!provider.capabilities.contains(.updateSelectedItems))
        #expect(harness.requests.isEmpty)
    }
}
