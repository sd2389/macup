import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Configuration loading, validation, and storage")
struct ConfigurationStoreTests {
    private func store(_ json: String?, in directory: TemporaryDirectory, migrator: ConfigurationMigrator = .standard) throws -> ConfigurationStore {
        let file = directory.appending("config.json")
        if let json {
            try json.write(to: file, atomically: true, encoding: .utf8)
        }
        return ConfigurationStore(fileURL: file, migrator: migrator)
    }

    private func errorPaths(_ loaded: LoadedConfiguration) -> [String] {
        loaded.issues.filter { $0.severity == .error }.map(\.path)
    }

    static let specExample = """
        {
          "schemaVersion": 1,
          "global": { "defaultPolicy": "ask", "confirmMajorUpdates": true },
          "providers": {
            "homebrew": { "enabled": true, "policy": "ask" },
            "npm": { "enabled": true, "policy": "ask" },
            "mise": { "enabled": true, "policy": "ask" },
            "macos": { "enabled": true, "policy": "ask" }
          },
          "items": {
            "npm:@anthropic-ai/claude-code": { "policy": "ask" },
            "brew:postgresql": { "policy": "ignore" }
          },
          "schedule": { "enabled": false, "frequency": "daily", "time": "23:00" },
          "privacy": { "telemetry": false }
        }
        """

    // MARK: Loading

    @Test("A missing file means conservative defaults, not an error")
    func missingFile() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(nil, in: directory).load()
        #expect(loaded.source == .defaults)
        #expect(loaded.issues.isEmpty)
        #expect(loaded.allowsAutomaticModification)
        #expect(loaded.configuration == .defaults)
        #expect(loaded.configuration.global.defaultPolicy == .ask)
        #expect(loaded.configuration.schedule.enabled == false)
        #expect(loaded.configuration.privacy.telemetry == false)
        #expect(!FileManager.default.fileExists(atPath: directory.appending("config.json").path), "Loading must not create files")
    }

    @Test("The example from the spec is valid")
    func specExampleIsValid() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(Self.specExample, in: directory).load()
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        #expect(loaded.source == .file)
        #expect(loaded.configuration.items["brew:postgresql"]?.policy == .ignore)
        #expect(loaded.configuration.items["npm:@anthropic-ai/claude-code"]?.policy == .ask)
        #expect(loaded.configuration.settings(for: .mise).policy == .ask)
    }

    @Test("Omitted sections take conservative defaults")
    func minimalFile() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(#"{"schemaVersion": 1}"#, in: directory).load()
        #expect(loaded.issues.isEmpty)
        #expect(loaded.configuration.settings(for: .npm) == .init(enabled: true, policy: .inherit))
        #expect(loaded.configuration.global.defaultPolicy == .ask)
    }

    @Test(
        "Anything MacUp cannot interpret with certainty is an error that disables automatic modification",
        arguments: [
            (#"{"schemaVersion":1,"providers":{"homebrew":{"enabeld":false}}}"#, "providers.homebrew.enabeld"),
            (#"{"schemaVersion":1,"providers":{"homebew":{"enabled":false}}}"#, "providers.homebew"),
            (#"{"schemaVersion":1,"global":{"defaultPolicy":"always"}}"#, "global.defaultPolicy"),
            (#"{"schemaVersion":1,"global":{"defaultPolicy":"pin"}}"#, "global.defaultPolicy"),
            (#"{"schemaVersion":1,"providers":{"npm":{"enabled":"no"}}}"#, "providers.npm.enabled"),
            (#"{"schemaVersion":1,"providers":{"mise":{"policy":"pin"}}}"#, "providers.mise.policy"),
            (#"{"schemaVersion":1,"providers":{"homebrew":{"executablePath":"brew"}}}"#, "providers.homebrew.executablePath"),
            (#"{"schemaVersion":1,"providers":{"homebrew":{"executablePath":"/usr/bin/true"}}}"#, "providers.homebrew.executablePath"),
            (#"{"schemaVersion":1,"providers":{"macos":{"executablePath":"/usr/sbin/softwareupdate"}}}"#, "providers.macos.executablePath"),
            (#"{"schemaVersion":1,"items":{"brew postgresql":{"policy":"ignore"}}}"#, "items.brew postgresql"),
            (#"{"schemaVersion":1,"items":{"pip:requests":{"policy":"ignore"}}}"#, "items.pip:requests"),
            (#"{"schemaVersion":1,"items":{"brew:git":{}}}"#, "items.brew:git.policy"),
            (#"{"schemaVersion":1,"items":{"brew:git":{"policy":"ignore","reason":"x"}}}"#, "items.brew:git.reason"),
            (#"{"schemaVersion":1,"schedule":{"time":"25:00"}}"#, "schedule.time"),
            (#"{"schemaVersion":1,"schedule":{"time":"9:00"}}"#, "schedule.time"),
            (#"{"schemaVersion":1,"schedule":{"frequency":"hourly"}}"#, "schedule.frequency"),
            (#"{"schemaVersion":1,"telemetry":true}"#, "telemetry"),
            (#"{"schemaVersion":2}"#, "schemaVersion"),
            (#"{"schemaVersion":0}"#, "schemaVersion"),
            (#"{"schemaVersion":true}"#, "schemaVersion"),
            (#"{"schemaVersion":"1"}"#, "schemaVersion"),
            (#"{"global":{}}"#, "schemaVersion"),
            (#"{"schemaVersion":1,"#, ""),
            ("[1, 2, 3]", ""),
            ("", ""),
        ]
    )
    func strictValidation(json: String, expectedPath: String) throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(json, in: directory).load()
        #expect(loaded.hasErrors)
        #expect(!loaded.allowsAutomaticModification)
        #expect(errorPaths(loaded).contains(expectedPath), "errors: \(loaded.issues)")
    }

    @Test("A structurally valid file with errors keeps its settings for read-only use")
    func keepsDecodedSettingsWhenInvalid() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(
            #"{"schemaVersion":1,"providers":{"mise":{"enabled":false}},"schedule":{"time":"99:99"}}"#,
            in: directory
        ).load()
        #expect(!loaded.allowsAutomaticModification)
        #expect(loaded.configuration.settings(for: .mise).enabled == false)
    }

    @Test("Undecodable files fall back to defaults")
    func undecodableFallsBack() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(#"{"schemaVersion":1,"providers":{"mise":{"enabled":"nope"}}}"#, in: directory).load()
        #expect(loaded.configuration == .defaults)
        #expect(loaded.issues.first?.message == "Expected true or false.")
    }

    @Test("Invalid policy values list the allowed policies")
    func policyMessage() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(#"{"schemaVersion":1,"items":{"brew:git":{"policy":"never"}}}"#, in: directory).load()
        #expect(loaded.issues.first?.message == "Policy must be one of: auto, ask, ignore, pin, inherit.")
    }

    @Test("A newer schema is reported, never guessed at, and never modified")
    func newerSchemaUntouched() throws {
        let directory = try TemporaryDirectory()
        let json = #"{"schemaVersion": 7, "future": true}"#
        let store = try store(json, in: directory)
        let loaded = store.load()
        #expect(loaded.configuration == .defaults)
        #expect(loaded.issues.first?.message.contains("newer MacUp") == true)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == json)
    }

    @Test("Warnings inform without disabling anything")
    func warnings() throws {
        let directory = try TemporaryDirectory()
        let loaded = try store(
            #"{"schemaVersion":1,"providers":{"macos":{"policy":"auto"}},"items":{"macos:Some Update-1.0":{"policy":"auto"}},"privacy":{"telemetry":true}}"#,
            in: directory
        ).load()
        #expect(!loaded.hasErrors, "\(loaded.issues)")
        #expect(loaded.allowsAutomaticModification)
        #expect(loaded.issues.map(\.path).sorted() == ["items.macos:Some Update-1.0.policy", "privacy.telemetry", "providers.macos.policy"])
    }

    @Test("A file other users can modify is an error")
    func worldWritableFile() throws {
        let directory = try TemporaryDirectory()
        let store = try store(Self.specExample, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: store.fileURL.path)
        let loaded = store.load()
        #expect(!loaded.allowsAutomaticModification)
        #expect(loaded.issues.contains { $0.message.contains("writable by other users") })
    }

    @Test("A directory other users can modify is an error")
    func groupWritableDirectory() throws {
        let directory = try TemporaryDirectory()
        let store = try store(Self.specExample, in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: directory.path)
        let loaded = store.load()
        #expect(!loaded.allowsAutomaticModification)
        #expect(loaded.issues.contains { $0.message.hasPrefix("The configuration directory is writable") })
    }

    @Test(
        "A file other users could change is ignored entirely, so it cannot choose executables",
        arguments: [(fileMode: 0o666, directoryMode: 0o700), (fileMode: 0o600, directoryMode: 0o775)]
    )
    func untrustedFileIsIgnored(fileMode: Int, directoryMode: Int) throws {
        let directory = try TemporaryDirectory()
        let store = try store(
            #"{"schemaVersion":1,"providers":{"homebrew":{"executablePath":"/elsewhere/bin/brew"},"macos":{"enabled":false}}}"#,
            in: directory
        )
        try FileManager.default.setAttributes([.posixPermissions: fileMode], ofItemAtPath: store.fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: directoryMode], ofItemAtPath: directory.path)
        let loaded = store.load()
        #expect(loaded.hasErrors)
        #expect(loaded.configuration == .defaults)
        #expect(loaded.configuration.settings(for: .homebrew).executablePath == nil)
        #expect(loaded.configuration.settings(for: .macos).enabled)
        #expect(loaded.issues.contains { $0.message.hasPrefix("MacUp ignored this file") })
    }

    @Test("A symlinked file is checked against the directory holding its target")
    func symlinkTargetDirectoryIsChecked() throws {
        let directory = try TemporaryDirectory()
        let privateDirectory = directory.appending("private")
        let shared = directory.appending("shared")
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let target = shared.appendingPathComponent("real.json")
        try #"{"schemaVersion":1,"providers":{"mise":{"enabled":false}}}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let link = privateDirectory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shared.path)
        let trusted = ConfigurationStore(fileURL: link).load()
        #expect(!trusted.hasErrors, "\(trusted.issues)")
        #expect(trusted.configuration.settings(for: .mise).enabled == false)

        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        let untrusted = ConfigurationStore(fileURL: link).load()
        #expect(untrusted.hasErrors)
        #expect(untrusted.configuration == .defaults)
        #expect(untrusted.issues.contains {
            $0.message.hasPrefix("The directory holding the configuration file's target is writable") && $0.message.contains(shared.path)
        })
    }

    @Test("Special files and dangling symlinks are errors, never read")
    func specialFilesAreRefused() throws {
        let directory = try TemporaryDirectory()
        let fifo = directory.appending("config.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ConfigurationStore(fileURL: fifo).load().issues.first?.message == "The configuration path is not a regular file.")

        let dangling = directory.appending("dangling.json")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: directory.appending("missing.json"))
        let loaded = ConfigurationStore(fileURL: dangling).load()
        #expect(loaded.source == .file)
        #expect(loaded.issues.contains { $0.message == "The configuration path is not a regular file." })
    }

    @Test("Oversized files are refused")
    func oversizedFile() throws {
        let directory = try TemporaryDirectory()
        let padding = String(repeating: " ", count: ConfigurationStore.maximumFileSize)
        let loaded = try store(#"{"schemaVersion":1}"# + padding, in: directory).load()
        #expect(loaded.issues.first?.message == "The configuration file is larger than 1 MiB.")
    }

    // MARK: Saving

    @Test("Saving is atomic, owner-only, and round-trips")
    func saveRoundTrips() throws {
        let directory = try TemporaryDirectory()
        let nested = directory.appending("nested/macup")
        let store = ConfigurationStore(fileURL: nested.appendingPathComponent("config.json"))
        var configuration = MacUpConfiguration.defaults
        configuration.items["brew:postgresql"] = .init(policy: .ignore)
        configuration.providers["mise"] = .init(enabled: false, policy: .ask)
        try store.save(configuration)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path) == ["config.json"], "no temporary files left")

        let loaded = store.load()
        #expect(loaded.issues.isEmpty)
        #expect(loaded.configuration == configuration)
    }

    @Test("Saving refuses to replace a symlink")
    func saveRefusesSymlink() throws {
        let directory = try TemporaryDirectory()
        let target = directory.appending("elsewhere.json")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appending("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let error = #expect(throws: MacUpError.self) {
            try ConfigurationStore(fileURL: link).save(.defaults)
        }
        #expect(error?.kind == .configurationInvalid)
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        #expect(ConfigurationStore(fileURL: link).load().issues.contains { $0.message.contains("symlink") })
    }

    @Test("Saving refuses a directory other users can modify")
    func saveRefusesSharedDirectory() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        #expect(throws: MacUpError.self) {
            try ConfigurationStore(fileURL: directory.appending("config.json")).save(.defaults)
        }
    }

    // MARK: Migration

    private static let legacyMigrator = ConfigurationMigrator(targetVersion: 1, migrations: [
        0: { document in
            var document = document
            document["schemaVersion"] = 1
            if let policy = document.removeValue(forKey: "policy") {
                document["global"] = ["defaultPolicy": policy]
            }
            return document
        },
    ])

    @Test("Older schemas migrate in memory; saving backs up the original first")
    func migrationWithBackup() throws {
        let directory = try TemporaryDirectory()
        let legacy = #"{"schemaVersion": 0, "policy": "ignore"}"#
        let store = try store(legacy, in: directory, migrator: Self.legacyMigrator)
        let loaded = store.load()
        #expect(loaded.migratedFromSchemaVersion == 0)
        #expect(loaded.allowsAutomaticModification)
        #expect(loaded.configuration.global.defaultPolicy == .ignore)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == legacy, "loading never rewrites")

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let backup = try store.persistMigration(of: loaded, now: now)
        #expect(backup.lastPathComponent == "config.json.backup-v0-20260921T141320Z")
        #expect(try String(contentsOf: backup, encoding: .utf8) == legacy)
        let reloaded = store.load()
        #expect(reloaded.migratedFromSchemaVersion == nil)
        #expect(reloaded.configuration.schemaVersion == 1)
        #expect(reloaded.configuration.global.defaultPolicy == .ignore)
    }

    @Test("Migration failures are configuration errors")
    func migrationFailures() throws {
        let broken = ConfigurationMigrator(targetVersion: 1, migrations: [0: { $0 }])
        #expect(throws: MacUpError.self) { try broken.migrate(["schemaVersion": 0], from: 0) }
        #expect(throws: MacUpError.self) { try ConfigurationMigrator.standard.migrate(["schemaVersion": 0], from: 0) }
    }

    @Test("An invalid configuration is never migrated")
    func invalidNeverMigrated() throws {
        let directory = try TemporaryDirectory()
        let store = try store(#"{"schemaVersion": 0, "policy": "ignore", "typo": 1}"#, in: directory, migrator: Self.legacyMigrator)
        let loaded = store.load()
        #expect(loaded.hasErrors)
        #expect(throws: MacUpError.self) { try store.persistMigration(of: loaded) }
    }

    @Test("Integers must be written as integers")
    func strictIntegers() {
        #expect(ConfigurationStore.strictInteger(NSNumber(value: 1)) == 1)
        #expect(ConfigurationStore.strictInteger(NSNumber(value: true)) == nil)
        #expect(ConfigurationStore.strictInteger(NSNumber(value: 1.5)) == nil)
        #expect(ConfigurationStore.strictInteger("1") == nil)
        #expect(ConfigurationStore.strictInteger(nil) == nil)
    }
}
