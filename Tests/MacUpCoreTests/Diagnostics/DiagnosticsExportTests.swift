import Darwin
import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

// Token-shaped dummies are assembled at runtime so secret scanners do not flag this file.
private let githubToken = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
private let awsKey = "AKIA" + "ABCDEFGHIJKLMNOP"
private let bearerToken = "abcdef" + "1234567890abcdef"

/// A Mac with something private in every place an exported file could pick
/// it up from: a user called alex, packages from an employer's npm scope and
/// Homebrew tap, secrets in a provider's error output and in history, a note
/// on a rule, and a name MacUp could not even read.
private enum Sample {
    static let home = "/Users/alex"
    static let paths = MacUpPaths.standard(homeDirectory: home)
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static func id(_ value: String) -> PackageID {
        try! PackageID(parsing: value)
    }

    static var configuration: LoadedConfiguration {
        var configuration = MacUpConfiguration.defaults
        configuration.items = [
            "brew:secret-tool": .init(policy: .ignore, skipVersion: "1.1", note: "held for the zebra launch"),
            "npm:@acme/private-cli": .init(policy: .ask),
            "not-an-id": .init(policy: .ask),
        ]
        return LoadedConfiguration(
            configuration: configuration,
            source: .file,
            path: paths.configFile,
            issues: [ConfigurationIssue(.error, "items.not-an-id", "Invalid package ID: 'not-an-id' is not a package ID.")]
        )
    }

    static var providers: [ProviderReport] {
        [
            .available(
                .homebrew,
                executable: home + "/.homebrew/bin/brew",
                version: "4.4.2",
                facts: [ProviderFact(key: "prefix", label: "Prefix", value: home + "/.homebrew")],
                items: [
                    ManagedItem(
                        id: id("brew:secret-tool"),
                        kind: .formula,
                        displayName: "secret-tool",
                        installedVersions: ["1.0"],
                        details: ["tap": "acme-corp/internal"]
                    ),
                    ManagedItem(id: id("brew:node"), kind: .formula, displayName: "node", installedVersions: ["24.1.0"]),
                    ManagedItem(id: id("brew:python@3.12"), kind: .formula, displayName: "python@3.12", installedVersions: ["3.12.1"]),
                    ManagedItem(
                        id: id("brew-cask:visual-studio-code"),
                        kind: .cask,
                        displayName: "Visual Studio Code",
                        installedVersions: ["1.90"]
                    ),
                ],
                errors: [ProviderOperationError(operation: .outdated, error: MacUpError(
                    .commandFailed,
                    "brew outdated failed for secret-tool.",
                    detail: """
                        Error: GITHUB_TOKEN=\(githubToken) rejected
                        Authorization: Bearer \(bearerToken)
                        key \(awsKey) in acme-corp/internal
                        see \(home)/Library/Logs/Homebrew/secret-tool
                        run: sudo chown -R alex /opt/homebrew
                        Visual Studio Code is running
                        """,
                    command: home + "/.homebrew/bin/brew outdated --json=v2"
                ))]
            ),
            .available(
                .npm,
                executable: "/opt/homebrew/bin/npm",
                items: [
                    ManagedItem(
                        id: id("npm:@acme/private-cli"),
                        kind: .globalPackage,
                        displayName: "@acme/private-cli",
                        installedVersions: ["2.0.0"]
                    ),
                    ManagedItem(id: id("npm:npm"), kind: .globalPackage, displayName: "npm", installedVersions: ["11.0.0"]),
                ]
            ),
        ]
    }

    static var updates: [UpdateCandidate] {
        [
            UpdateCandidate(id: id("brew:secret-tool"), kind: .formula, displayName: "secret-tool", installedVersion: "1.0", availableVersion: "1.1"),
            UpdateCandidate(
                id: id("npm:@acme/private-cli"),
                kind: .globalPackage,
                displayName: "@acme/private-cli",
                installedVersion: "2.0.0",
                availableVersion: "2.1.0",
                ownership: OwnershipChain([
                    OwnershipLink(label: "npm"),
                    OwnershipLink(label: "Node 24.1.0", path: home + "/.local/share/mise/installs/node/24.1.0/bin/node"),
                    OwnershipLink(label: "mise"),
                ])
            ),
            UpdateCandidate(id: id("brew:node"), kind: .formula, displayName: "node", installedVersion: "24.1.0", availableVersion: "24.2.0"),
            UpdateCandidate(id: id("brew:python@3.12"), kind: .formula, displayName: "python@3.12", installedVersion: "3.12.1", availableVersion: "3.12.2"),
        ]
    }

    static var check: CheckReport {
        CheckReport(
            mode: .readOnly,
            startedAt: now,
            finishedAt: now.addingTimeInterval(3),
            cancelled: false,
            configuration: ConfigurationSummary(configuration),
            providers: providers,
            updates: updates,
            commands: [CommandRecord(
                command: home + "/.homebrew/bin/brew outdated --json=v2",
                effect: .readOnly,
                outcome: .exited,
                exitStatus: 1,
                startedAt: now,
                durationSeconds: 1.23456
            )]
        )
    }

    static var doctor: DoctorReport {
        DoctorReport(
            startedAt: now,
            finishedAt: now.addingTimeInterval(4),
            findings: [
                DiagnosticFinding(
                    id: "homebrew.unreadableEntry",
                    severity: .warning,
                    provider: .homebrew,
                    title: "Skipped an entry MacUp could not read",
                    detail: "zebra-internal-thing: The entry has no token."
                ),
                DiagnosticFinding(
                    id: "configuration.staleItemPolicy",
                    severity: .info,
                    provider: nil,
                    title: "A rule names secret-tool, which is not installed",
                    detail: "items.brew:secret-tool.policy",
                    fix: DiagnosticFix(
                        action: .clearItemRules(["brew:secret-tool", "npm:@acme/private-cli", "not-an-id"]),
                        summary: "Drop the rule for brew:secret-tool",
                        detail: "Removes items.brew:secret-tool from " + paths.configFile
                    )
                ),
                DiagnosticFinding(
                    id: "schedule.agentMissing",
                    severity: .warning,
                    provider: nil,
                    title: "The scheduled check is switched on, but no agent is installed",
                    detail: "Would write " + paths.launchAgentsDirectory + "/com.macup.check.plist",
                    fix: DiagnosticFix(
                        action: .installScheduleAgent,
                        summary: "Install the scheduled run",
                        detail: "Writes \(paths.launchAgentsDirectory)/com.macup.check.plist and runs \(home)/.local/bin/macup check --save-state"
                    )
                ),
                DiagnosticFinding(
                    id: "runtime.multipleInstallationsOnPath",
                    severity: .info,
                    provider: nil,
                    title: "Several node installations are on your PATH",
                    detail: home + "/.local/share/mise/installs/node/24/bin/node \u{202E}reversed"
                ),
            ],
            providers: providers,
            configuration: ConfigurationSummary(configuration),
            checksRun: 11
        )
    }

    static var history: HistoryReading {
        HistoryReading(entries: [HistoryEntry(
            timestamp: now,
            origin: .gui,
            item: id("brew:secret-tool"),
            versionBefore: "1.0",
            versionTarget: "1.1",
            versionAfter: nil,
            command: home + "/.homebrew/bin/brew upgrade --formula --yes secret-tool",
            outcome: .failed,
            verification: nil,
            errorSummary: "password: hunter2 was refused for secret-tool",
            durationSeconds: 2.5
        )])
    }

    static func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            createdAt: now,
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
            homeDirectory: home,
            check: check,
            doctor: doctor,
            configuration: configuration,
            history: history
        )
    }

    static func data(includingNames: Bool = false) throws -> Data {
        try DiagnosticsDocument(snapshot(), includePackageNames: includingNames).encoded()
    }

    static func text(includingNames: Bool = false) throws -> String {
        String(decoding: try data(includingNames: includingNames), as: UTF8.self)
    }

    static func document(includingNames: Bool = false) throws -> DiagnosticsDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticsDocument.self, from: data(includingNames: includingNames))
    }
}

@Suite("An exported diagnostics file")
struct DiagnosticsDocumentTests {
    @Test("It is a versioned diagnostics document that decodes back")
    func versionedDocument() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Sample.data()) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == DiagnosticsDocument.schemaVersion)
        #expect(object["kind"] as? String == "diagnostics")
        #expect(object["macupVersion"] as? String == MacUp.version)
        #expect(object["packageNames"] as? String == "placeholders")

        let document = try Sample.document()
        #expect(document.system.productVersion == "27.0")
        #expect(document.providers.map(\.provider) == [.homebrew, .npm])
        #expect(document.check?.updates.count == 4)
        #expect(document.doctor?.findings.count == 4)
        #expect(document.history.entries.count == 1)
        #expect(document.configuration.valid == false)
        #expect(document.leftOut == DiagnosticsDocument.leftOut(packageNames: .placeholders))
    }

    @Test("Secrets are redacted wherever they appear", arguments: [githubToken, awsKey, bearerToken, "hunter2"])
    func secretsAreRedacted(secret: String) throws {
        for includingNames in [false, true] {
            #expect(!(try Sample.text(includingNames: includingNames)).contains(secret))
        }
        #expect(try Sample.text().contains("<redacted>"))
    }

    @Test("A finding's fix is scrubbed too: its keys are placeholders and its prose carries no home path")
    func findingFixesAreScrubbed() throws {
        let document = try Sample.document()
        let stale = try #require(document.doctor?.findings.first { $0.id == "configuration.staleItemPolicy" })
        let fix = try #require(stale.fix)
        guard case .clearItemRules(let keys) = fix.action else {
            Issue.record("the stale-rule fix should still name the keys it would drop")
            return
        }
        #expect(keys.count == 3)
        #expect(keys.allSatisfy { !$0.contains("secret-tool") && !$0.contains("private-cli") })
        #expect(keys.contains { $0.hasPrefix("brew:package-") })
        #expect(keys.contains { $0.hasPrefix("npm:package-") })
        // A key that is not a package ID goes through the same text path as
        // any other string, so the mask catches it too.
        #expect(keys.allSatisfy { !$0.contains("not-an-id") })
        #expect(!fix.summary.contains("secret-tool"))
        #expect(fix.summary.contains("package-1"))
        #expect(!fix.detail.contains("/Users/"))

        let schedule = try #require(document.doctor?.findings.first { $0.id == "schedule.agentMissing" })
        #expect(try #require(schedule.fix).detail.hasPrefix("Writes ~/Library/LaunchAgents/"))
        #expect(try #require(schedule.fix).detail.contains("~/.local/bin/macup check --save-state"))

        // And with names kept, the same field says the real thing.
        let withNames = try Sample.document(includingNames: true)
        let keptKeys = try #require(withNames.doctor?.findings.first { $0.id == "configuration.staleItemPolicy" }?.fix)
        guard case .clearItemRules(let real) = keptKeys.action else { return }
        #expect(real.contains("brew:secret-tool"))
    }

    @Test("The home folder is written as ~, and the user name on its own as <user>")
    func homeAndUserName() throws {
        for includingNames in [false, true] {
            let text = try Sample.text(includingNames: includingNames)
            #expect(!text.contains("/Users/"))
            #expect(!text.contains("alex"))
            #expect(text.contains("~/.homebrew/bin/brew"))
            #expect(text.contains("chown -R <user> /opt/homebrew"))
        }
    }

    @Test("By default package names are placeholders, the same one wherever a package appears")
    func namesArePlaceholders() throws {
        let text = try Sample.text()
        // Names from updates, inventory, history, rules, a cask's display
        // name, an npm scope, a tap, a key MacUp could not read, and an
        // entry it could not read at all.
        for name in ["secret-tool", "private-cli", "@acme", "acme-corp", "Visual Studio Code", "visual-studio-code", "not-an-id", "zebra"] {
            #expect(!text.contains(name), "\(name) reached the file")
        }

        let document = try Sample.document()
        let secretTool = try #require(document.check?.updates.first?.item)
        #expect(secretTool == "brew:package-1")
        #expect(document.history.entries.first?.item == secretTool)
        #expect(document.history.entries.first?.command == "~/.homebrew/bin/brew upgrade --formula --yes package-1")
        #expect(document.policies.items.contains { $0.item == secretTool && $0.policy == .ignore })
        #expect(document.check?.updates[1].item.hasPrefix("npm:package-") == true)
        #expect(document.doctor?.findings.contains { $0.detail == "(name left out): The entry has no token." } == true)
        #expect(document.configuration.issues.first?.path.hasPrefix("items.package-") == true)
    }

    @Test("The name and bundle identifier of an app MacUp uninstalled are masked in free text too")
    func uninstalledAppNamesAreMasked() throws {
        var entry = HistoryEntry(
            timestamp: Sample.now,
            origin: .gui,
            item: nil,
            versionBefore: "1.2",
            versionTarget: nil,
            versionAfter: nil,
            command: nil,
            outcome: .failed,
            verification: nil,
            errorSummary: "Quit Moonlighter first; com.acme.moonlighter is still open.",
            skipReason: "Moonlighter is open."
        )
        entry.uninstall = UninstallRecord(target: "app:com.acme.moonlighter", name: "Moonlighter", kind: .app, mode: .trash)
        var snapshot = Sample.snapshot()
        snapshot.history = HistoryReading(entries: [entry])

        let masked = String(decoding: try DiagnosticsDocument(snapshot, includePackageNames: false).encoded(), as: UTF8.self)
        #expect(!masked.contains("Moonlighter"))
        #expect(!masked.contains("com.acme.moonlighter"))
        #expect(masked.contains("\"item\" : \"app\""))

        let named = String(decoding: try DiagnosticsDocument(snapshot, includePackageNames: true).encoded(), as: UTF8.self)
        #expect(named.contains("Moonlighter is open."))
    }

    @Test("Runtimes and package managers MacUp knows by name keep their names")
    func vocabularyIsKept() throws {
        let document = try Sample.document()
        let items = document.check?.updates.map(\.item) ?? []
        #expect(items.contains("brew:node"))
        #expect(items.contains("brew:python@3.12"))
        #expect(document.doctor?.findings.contains { $0.title == "Several node installations are on your PATH" } == true)
        #expect(document.check?.updates[1].ownership == "npm → Node 24.1.0 → mise")
    }

    @Test("Package names are written as they are only when asked for")
    func namesWhenAskedFor() throws {
        let text = try Sample.text(includingNames: true)
        #expect(text.contains("\"brew:secret-tool\""))
        #expect(text.contains("npm:@acme/private-cli"))
        #expect(try Sample.document(includingNames: true).packageNames == .included)
        #expect(!text.contains("package-1"))
    }

    @Test("A skipped version is kept, and a note is left out whatever the choice")
    func skippedVersionAndNote() throws {
        for includingNames in [false, true] {
            let document = try Sample.document(includingNames: includingNames)
            let rule = try #require(document.policies.items.first { $0.skipVersion != nil })
            #expect(rule.skipVersion == "1.1")
            #expect(rule.hasNote)
            #expect(!(try Sample.text(includingNames: includingNames)).contains("zebra launch"))
        }
    }

    @Test("The same look at the Mac always renders the same bytes")
    func deterministic() throws {
        #expect(try Sample.data() == Sample.data())
        #expect(try Sample.data(includingNames: true) == Sample.data(includingNames: true))
    }

    @Test("Nothing a terminal would act on reaches the file")
    func terminalSafe() throws {
        let text = try Sample.text()
        #expect(!text.unicodeScalars.contains { $0.value >= 0x20 && TerminalText.isUnsafe($0) })
        #expect(text.contains("\\u{202E}reversed"))
    }

    @Test("Durations are to the millisecond")
    func durations() throws {
        #expect(try Sample.document().check?.commands.first?.durationSeconds == 1.235)
    }

    @Test("Only the 50 most recent history entries go in")
    func historyIsCapped() throws {
        var snapshot = Sample.snapshot()
        let entry = try #require(Sample.history.entries.first)
        snapshot.history = HistoryReading(entries: Array(repeating: entry, count: 80))
        let document = DiagnosticsDocument(snapshot, includePackageNames: false)
        #expect(document.history.entries.count == DiagnosticsDocument.historyLimit)
    }
}

@Suite("Package name placeholders")
struct PackageNameMaskTests {
    @Test("MacUp's own vocabulary is kept; a scope, a backend, or an unknown name is not")
    func vocabulary() {
        for name in ["node", "npm", "mise", "python", "python@3.12", "go", "corepack"] {
            #expect(PackageNameMask.isMacUpVocabulary(name), "\(name)")
        }
        for name in ["@acme/node", "npm:prettier", "nodejs/node", "secret-tool", "git"] {
            #expect(!PackageNameMask.isMacUpVocabulary(name), "\(name)")
        }
    }

    @Test("A name is masked as a whole word, in paths and sentences, whatever its case")
    func wholeWords() {
        let mask = PackageNameMask(names: [("git", [])])
        #expect(mask.masking("/opt/homebrew/bin/git") == "/opt/homebrew/bin/package-1")
        #expect(mask.masking("Upgrading Git.") == "Upgrading package-1.")
        #expect(mask.masking("digit and GitHub") == "digit and GitHub")
    }

    @Test("The longest name wins, and another name for a package shares its number")
    func longestFirst() {
        let mask = PackageNameMask(names: [("code", []), ("visual-studio-code", ["Visual Studio Code"])])
        #expect(mask.masking("visual-studio-code, then code") == "package-1, then package-2")
        #expect(mask.masking("Visual Studio Code") == "package-1")
    }

    @Test("Numbers go by first use, so they say nothing about names the file never shows")
    func numberedByFirstUse() throws {
        let mask = PackageNameMask(names: [("aardvark", []), ("zebra", [])])
        #expect(mask.placeholder(for: try PackageID(parsing: "brew:zebra")) == "brew:package-1")
        #expect(mask.placeholder(for: try PackageID(parsing: "npm:zebra")) == "npm:package-1")
        #expect(mask.masking("aardvark") == "package-2")
    }

    @Test("Hostile names are masked, and never break the pattern")
    func hostileNames() {
        let names = HostileInput.names.filter { PackageID.validateName($0) == nil }
        let mask = PackageNameMask(names: names.map { ($0, []) })
        for name in names {
            #expect(!mask.masking("before \(name) after").contains(name), "\(name)")
        }
    }
}

@Suite("Writing an exported file")
struct DiagnosticsFileTests {
    private let data = Data("{\"kind\" : \"diagnostics\"}\n".utf8)

    @Test("The file is created with exactly the bytes given, readable only by its owner")
    func writesOwnerOnly() throws {
        let directory = try TemporaryDirectory(prefix: "macup-export")
        let path = directory.appending("out.json").path
        try DiagnosticsFile.write(data, toPath: path)

        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == data)
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == getuid())
    }

    @Test("An existing file is never replaced")
    func refusesToOverwrite() throws {
        let directory = try TemporaryDirectory(prefix: "macup-export")
        let path = directory.appending("out.json").path
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: DiagnosticsFileError(.alreadyExists, path: path)) {
            try DiagnosticsFile.write(data, toPath: path)
        }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "keep me")
    }

    @Test("A symbolic link is refused, whether or not it points anywhere")
    func refusesSymbolicLinks() throws {
        let directory = try TemporaryDirectory(prefix: "macup-export")
        let target = directory.appending("target.json").path
        try Data("target".utf8).write(to: URL(fileURLWithPath: target))
        let link = directory.appending("link.json").path
        #expect(symlink(target, link) == 0)
        #expect(throws: DiagnosticsFileError(.symbolicLink, path: link)) {
            try DiagnosticsFile.write(data, toPath: link)
        }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "target")

        let nowhere = directory.appending("nowhere.json").path
        let dangling = directory.appending("dangling.json").path
        #expect(symlink(nowhere, dangling) == 0)
        #expect(throws: DiagnosticsFileError(.symbolicLink, path: dangling)) {
            try DiagnosticsFile.write(data, toPath: dangling)
        }
        #expect(!FileManager.default.fileExists(atPath: nowhere))
    }

    @Test("A folder that is not there is reported, and nothing is created")
    func missingFolder() throws {
        let directory = try TemporaryDirectory(prefix: "macup-export")
        let path = directory.appending("missing/out.json").path
        #expect(throws: DiagnosticsFileError(.noSuchFolder, path: path)) {
            try DiagnosticsFile.write(data, toPath: path)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending("missing").path))
    }

    @Test("Each refusal can be predicted without writing anything")
    func predictsRefusals() throws {
        let directory = try TemporaryDirectory(prefix: "macup-export")
        let existing = directory.appending("existing.json").path
        try data.write(to: URL(fileURLWithPath: existing))
        let link = directory.appending("link.json").path
        #expect(symlink(existing, link) == 0)

        #expect(DiagnosticsFile.problem(writingTo: existing)?.reason == .alreadyExists)
        #expect(DiagnosticsFile.problem(writingTo: link)?.reason == .symbolicLink)
        #expect(DiagnosticsFile.problem(writingTo: directory.appending("missing/x.json").path)?.reason == .noSuchFolder)
        #expect(DiagnosticsFile.problem(writingTo: directory.appending("new.json").path) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appending("new.json").path))
    }

    @Test("The default name says when the file was made")
    func defaultName() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(DiagnosticsFile.defaultName(for: Sample.now, timeZone: utc) == "macup-diagnostics-2026-09-21-141320.json")
    }

    @Test("A refusal is one sentence with the home folder as ~")
    func messages() {
        let error = DiagnosticsFileError(.alreadyExists, path: "/Users/alex/Desktop/x.json")
        #expect(error.message(homeDirectory: "/Users/alex")
            == "~/Desktop/x.json already exists. MacUp never replaces a file, so nothing was written.")
    }
}

@Suite("Gathering diagnostics")
struct DiagnosticsCollectorTests {
    private static let outdated = #"""
        {"formulae": [{"name": "secret-tool", "installed_versions": ["1.0"], "current_version": "1.1", "pinned": false, "pinned_version": null}], "casks": []}
        """#

    /// Homebrew answering from fixtures, and nothing else installed.
    private static func homebrewMac() -> (FakeCommandRunner, FakeFileSystem) {
        let runner = FakeCommandRunner()
        runner.register("brew", ["--version"], .success("Homebrew 4.4.2\n"))
        runner.register("brew", ["--prefix"], .success("/opt/homebrew\n"))
        runner.register("brew", ["outdated", "--json=v2"], .success(outdated))
        runner.register("brew", ["info", "--json=v2", "--installed"], .success(#"{"formulae": [], "casks": []}"#))
        return (runner, FakeFileSystem().addExecutable("/opt/homebrew/bin/brew"))
    }

    private static func paths(_ state: TemporaryDirectory) -> MacUpPaths {
        MacUpPaths(
            configDirectory: state.path + "/config",
            stateDirectory: state.path,
            launchAgentsDirectory: state.path + "/agents"
        )
    }

    private static func environment(
        _ runner: FakeCommandRunner,
        _ fileSystem: FakeFileSystem,
        _ processEnvironment: [String: String] = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
    ) -> CheckEnvironment {
        CheckEnvironment(
            runner: runner,
            fileSystem: fileSystem,
            processEnvironment: processEnvironment,
            homeDirectory: Sample.home,
            system: SystemInfo(productVersion: "27.0", buildVersion: "26A428", architecture: "arm64"),
            now: { Sample.now }
        )
    }

    @Test("It checks the Mac once, runs only read-only commands, and reads the latest history")
    func checksOnceAndOnlyReads() async throws {
        let (runner, fileSystem) = Self.homebrewMac()
        let state = try TemporaryDirectory(prefix: "macup-diagnostics-state")
        let paths = Self.paths(state)
        let store = HistoryStore(paths: paths)
        for index in 0..<60 {
            try store.append(HistoryEntry(
                timestamp: Sample.now.addingTimeInterval(Double(index)),
                origin: .cli,
                item: Sample.id("brew:secret-tool"),
                versionBefore: "1.0",
                versionTarget: "1.1",
                versionAfter: "1.1",
                command: nil,
                outcome: .succeeded,
                verification: .verified,
                durationSeconds: Double(index)
            ))
        }

        let snapshot = await DiagnosticsCollector(
            doctorEngine: DoctorEngine(providers: [HomebrewProvider()], checks: [])
        ).collect(
            configuration: LoadedConfiguration(configuration: .defaults, source: .defaults, path: paths.configFile),
            environment: Self.environment(runner, fileSystem),
            paths: paths
        )

        #expect(runner.recordedRequests.filter { $0.invocation.arguments == ["outdated", "--json=v2"] }.count == 1)
        #expect(runner.recordedRequests.allSatisfy { $0.effect == .readOnly })
        #expect(snapshot.check?.updates.map(\.id.rawValue) == ["brew:secret-tool"])
        #expect(snapshot.doctor?.providers == snapshot.check?.providers)
        #expect(snapshot.history?.entries.count == DiagnosticsDocument.historyLimit)
        #expect(snapshot.history?.entries.first?.durationSeconds == 59)
        #expect(!snapshot.cancelled)
    }

    @Test("No environment variable reaches the file, even when Doctor compares the shell's")
    func noEnvironmentVariables() async throws {
        let (runner, fileSystem) = Self.homebrewMac()
        let secrets = [
            "GITHUB_TOKEN": githubToken,
            "AWS_SECRET_ACCESS_KEY": "wJalrXUtnFEMI" + "dummyvalue",
            "NODE_OPTIONS": "--require /tmp/okapi-hook.js",
            "OKAPI_PROJECT": "launch-codename-okapi",
        ]
        let processEnvironment = secrets.merging(["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "HOME": Sample.home]) { $1 }
        // The login shell has the same variables and one more folder on PATH,
        // so Doctor has something to say about it.
        let shellEnvironment = processEnvironment.merging(["PATH": "/opt/homebrew/bin:/usr/bin:/bin:/Users/alex/.cargo/bin"]) { $1 }
        let standard = DoctorEngine.standard()
        let doctor = DoctorEngine(
            providers: [HomebrewProvider()],
            checks: standard.checks.map { check in
                check is ShellEnvironmentCheck ? ShellEnvironmentCheck(read: { _ in ("/bin/zsh", shellEnvironment) }) : check
            }
        )
        let state = try TemporaryDirectory(prefix: "macup-diagnostics-state")
        let snapshot = await DiagnosticsCollector(doctorEngine: doctor).collect(
            configuration: LoadedConfiguration(configuration: .defaults, source: .defaults, path: Self.paths(state).configFile),
            environment: Self.environment(runner, fileSystem, processEnvironment),
            paths: Self.paths(state)
        )

        for includingNames in [false, true] {
            let text = String(
                decoding: try DiagnosticsDocument(snapshot, includePackageNames: includingNames).encoded(),
                as: UTF8.self
            )
            for value in secrets.values {
                #expect(!text.contains(value), "\(value) reached the file")
            }
            #expect(!text.contains("OKAPI_PROJECT"))
            // What Doctor noticed is there, as a folder, with the home folder as ~.
            #expect(text.contains("~/.cargo/bin"))
        }
    }
}
