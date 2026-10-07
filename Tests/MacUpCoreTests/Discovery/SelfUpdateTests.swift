import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("How MacUp updates itself")
struct SelfUpdateTests {
    private func report(
        homebrew: ProviderStatus.Availability = .available,
        prefix: String? = "/opt/homebrew",
        updates: [UpdateCandidate] = [],
        error: MacUpError? = nil
    ) -> CheckReport {
        CheckReport(
            mode: .readOnly,
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_790_000_001),
            cancelled: false,
            configuration: ConfigurationSummary(LoadedConfiguration(
                configuration: .defaults,
                source: .defaults,
                path: "/Users/example/.config/macup/config.json"
            )),
            providers: [ProviderReport(
                provider: .homebrew,
                displayName: "Homebrew",
                availability: homebrew,
                capabilities: [.detect],
                facts: prefix.map { [ProviderFact(key: "prefix", label: "Prefix", value: $0)] } ?? [],
                errors: error.map { [ProviderOperationError(operation: .detect, error: $0)] } ?? []
            )],
            updates: updates,
            commands: []
        )
    }

    private func candidate(_ id: String, from: String, to: String) throws -> UpdateCandidate {
        UpdateCandidate(
            id: try PackageID(parsing: id),
            kind: id.hasPrefix("brew-cask:") ? .cask : .formula,
            displayName: "macup",
            installedVersion: InstalledVersion(from),
            availableVersion: AvailableVersion(to)
        )
    }

    @Test("A command Homebrew installed is Homebrew's to update, and the update is an ordinary one")
    func homebrewFormula() throws {
        let fileSystem = FakeFileSystem()
        fileSystem.addExecutable("/opt/homebrew/Cellar/macup/0.4.0/bin/macup")
        let update = try candidate("brew:sd2389/macup/macup", from: "0.4.0", to: "0.5.0")

        let status = SelfUpdate.status(
            check: report(updates: [update]),
            executablePath: "/opt/homebrew/Cellar/macup/0.4.0/bin/macup",
            appBundlePath: nil,
            fileSystem: fileSystem,
            runningVersion: "0.4.0"
        )

        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.homebrewFormula])
        #expect(status.isManagedByHomebrew)
        #expect(status.hasUpdate)
        #expect(status.updates.map(\UpdateCandidate.id.rawValue) == ["brew:sd2389/macup/macup"], "a tapped formula is still MacUp's own")
        #expect(status.headline == "MacUp 0.4.0 can be updated to 0.5.0.")
    }

    @Test("A copy that was downloaded is nobody's to update, and MacUp says where the releases are")
    func downloadedCopy() {
        let status = SelfUpdate.status(
            check: report(),
            executablePath: "/Users/example/.local/bin/macup",
            appBundlePath: nil,
            fileSystem: FakeFileSystem(),
            runningVersion: "0.4.0"
        )

        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.downloaded])
        #expect(!status.isManagedByHomebrew)
        #expect(!status.hasUpdate)
        #expect(status.releasesURL == "https://github.com/sd2389/macup/releases")
        #expect(status.headline.contains("not installed by a package manager"))
    }

    @Test("A cask is found by Homebrew's Caskroom, not by where the app happens to be")
    func homebrewCask() {
        let fileSystem = FakeFileSystem()
        fileSystem.addDirectory("/opt/homebrew/Caskroom/macup")

        let status = SelfUpdate.status(
            check: report(),
            executablePath: "/Applications/MacUp.app/Contents/Helpers/macup",
            appBundlePath: "/Applications/MacUp.app",
            fileSystem: fileSystem,
            runningVersion: "0.4.0"
        )

        #expect(status.installations.map(\MacUpInstallation.kind) == [MacUpInstallation.Kind.homebrewCask])
        #expect(status.installations.first?.path == "/Applications/MacUp.app")
        #expect(status.installations.first?.item?.rawValue == "brew-cask:macup")
        #expect(status.headline == "MacUp 0.4.0 is up to date, according to Homebrew.")
    }

    @Test("An update for something else is never mistaken for MacUp's own")
    func ignoresOtherPackages() throws {
        let fileSystem = FakeFileSystem()
        fileSystem.addExecutable("/opt/homebrew/Cellar/macup/0.4.0/bin/macup")
        let others = [
            try candidate("brew:macupload", from: "1.0", to: "1.1"),
            try candidate("npm:macup", from: "1.0", to: "1.1"),
            try candidate("brew-cask:macup", from: "0.4.0", to: "0.5.0"),
        ]

        let status = SelfUpdate.status(
            check: report(updates: others),
            executablePath: "/opt/homebrew/Cellar/macup/0.4.0/bin/macup",
            appBundlePath: nil,
            fileSystem: fileSystem
        )

        #expect(!status.hasUpdate, "only the formula is installed, so only a formula update counts")
    }

    @Test("When Homebrew could not be used, MacUp says it does not know instead of saying it is up to date")
    func unknownWhenHomebrewFailed() {
        let fileSystem = FakeFileSystem()
        fileSystem.addDirectory("/opt/homebrew/Caskroom/macup")

        for (availability, expected) in [
            (ProviderStatus.Availability.failed, "could not be used"),
            (.disabled, "turned off"),
            (.unavailable, "did not find Homebrew"),
        ] {
            let status = SelfUpdate.status(
                check: report(homebrew: availability, error: MacUpError(.commandFailed, "brew could not be used.")),
                executablePath: nil,
                appBundlePath: "/Applications/MacUp.app",
                fileSystem: fileSystem
            )
            #expect(status.unknownReason?.contains(expected) == true)
            #expect(status.headline.contains("unknown"))
        }
    }

    @Test("A downloaded copy says nothing about Homebrew, even when Homebrew is broken")
    func downloadedCopyIsNotUnknown() {
        let status = SelfUpdate.status(
            check: report(homebrew: .failed, prefix: nil),
            executablePath: "/Users/example/.local/bin/macup",
            appBundlePath: nil,
            fileSystem: FakeFileSystem()
        )
        #expect(status.unknownReason == nil)
    }
}
