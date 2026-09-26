import Darwin
import Foundation

/// A configuration as loaded from disk, with everything found wrong with it.
public struct LoadedConfiguration: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// No file exists; built-in defaults are in effect.
        case defaults
        /// Read from the configuration file.
        case file
    }

    /// The configuration in effect. When the file could not be decoded this
    /// is ``MacUpConfiguration/defaults``; read-only operations use it, and
    /// automatic modification stays disabled while ``hasErrors`` is true.
    public var configuration: MacUpConfiguration
    public var source: Source
    public var path: String
    public var issues: [ConfigurationIssue]
    /// The file's schema version when it was migrated in memory.
    public var migratedFromSchemaVersion: Int?

    public init(
        configuration: MacUpConfiguration,
        source: Source,
        path: String,
        issues: [ConfigurationIssue] = [],
        migratedFromSchemaVersion: Int? = nil
    ) {
        self.configuration = configuration
        self.source = source
        self.path = path
        self.issues = issues
        self.migratedFromSchemaVersion = migratedFromSchemaVersion
    }

    public var hasErrors: Bool { issues.contains { $0.severity == .error } }

    /// Fail closed: any configuration error disables automatic modification.
    public var allowsAutomaticModification: Bool { !hasErrors }
}

/// Upgrades configuration documents from older schema versions.
public struct ConfigurationMigrator: Sendable {
    /// Transforms a document at version N into version N + 1.
    public typealias Migration = @Sendable ([String: Any]) throws -> [String: Any]

    public var targetVersion: Int
    /// Keyed by the version each migration starts from.
    public var migrations: [Int: Migration]

    public init(targetVersion: Int, migrations: [Int: Migration]) {
        self.targetVersion = targetVersion
        self.migrations = migrations
    }

    /// Schema 1 is the first schema, so there is nothing to migrate yet.
    public static let standard = ConfigurationMigrator(
        targetVersion: MacUpConfiguration.currentSchemaVersion,
        migrations: [:]
    )

    public func migrate(_ document: [String: Any], from version: Int) throws -> [String: Any] {
        var document = document
        var current = version
        while current < targetVersion {
            guard let migration = migrations[current] else {
                throw MacUpError(.configurationInvalid, "MacUp cannot migrate configuration schema version \(current).")
            }
            document = try migration(document)
            guard ConfigurationStore.strictInteger(document["schemaVersion"]) == current + 1 else {
                throw MacUpError(.configurationInvalid, "Migrating configuration schema version \(current) failed.")
            }
            current += 1
        }
        return document
    }
}

/// Reads and writes the configuration file.
///
/// Reading never modifies anything. Writing is atomic (temporary file in the
/// same directory, `fsync`, `rename`), creates owner-only files, and refuses
/// to replace symlinks or to write into directories other users can modify.
public struct ConfigurationStore: Sendable {
    public var fileURL: URL
    public var migrator: ConfigurationMigrator

    /// Larger files are refused; a real configuration is a few kilobytes.
    public static let maximumFileSize = 1 << 20

    public init(fileURL: URL, migrator: ConfigurationMigrator = .standard) {
        self.fileURL = fileURL
        self.migrator = migrator
    }

    public init(paths: MacUpPaths, migrator: ConfigurationMigrator = .standard) {
        self.init(fileURL: URL(fileURLWithPath: paths.configFile), migrator: migrator)
    }

    // MARK: Loading

    public func load() -> LoadedConfiguration {
        let path = fileURL.path
        var issues: [ConfigurationIssue] = []

        func fallback(_ issue: ConfigurationIssue) -> LoadedConfiguration {
            LoadedConfiguration(configuration: .defaults, source: .file, path: path, issues: issues + [issue])
        }

        var linkInfo = stat()
        guard lstat(path, &linkInfo) == 0 else {
            if errno == ENOENT {
                return LoadedConfiguration(configuration: .defaults, source: .defaults, path: path)
            }
            return fallback(ConfigurationIssue(.error, "", "The configuration file could not be inspected: \(String(cString: strerror(errno)))."))
        }
        if (linkInfo.st_mode & S_IFMT) == S_IFLNK {
            issues.append(ConfigurationIssue(
                .warning,
                "",
                "The configuration file is a symlink. MacUp reads it but will not replace it when saving."
            ))
        }

        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return fallback(ConfigurationIssue(.error, "", "The configuration path is not a regular file."))
        }
        issues += Self.ownershipIssues(info, subject: "The configuration file", path: path)
        let directory = fileURL.deletingLastPathComponent().path
        var directoryInfo = stat()
        if stat(directory, &directoryInfo) == 0 {
            issues += Self.ownershipIssues(directoryInfo, subject: "The configuration directory", path: directory)
        }
        guard Int(info.st_size) <= Self.maximumFileSize else {
            return fallback(ConfigurationIssue(.error, "", "The configuration file is larger than 1 MiB."))
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return fallback(ConfigurationIssue(.error, "", "The configuration file could not be read: \(error.localizedDescription)"))
        }

        guard var document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fallback(ConfigurationIssue(.error, "", "The configuration file is not a valid JSON object."))
        }

        guard let version = Self.strictInteger(document["schemaVersion"]) else {
            return fallback(ConfigurationIssue(.error, "schemaVersion", "Missing or invalid schemaVersion (expected a whole number)."))
        }
        var migratedFrom: Int?
        if version > MacUpConfiguration.currentSchemaVersion {
            return fallback(ConfigurationIssue(
                .error,
                "schemaVersion",
                "This configuration uses schema version \(version), written by a newer MacUp. It was not modified."
            ))
        } else if version < migrator.targetVersion {
            do {
                document = try migrator.migrate(document, from: version)
                migratedFrom = version
                issues.append(ConfigurationIssue(
                    .warning,
                    "schemaVersion",
                    "Schema version \(version) was upgraded in memory; the file is updated, with a backup, the next time MacUp saves it."
                ))
            } catch let error as MacUpError {
                return fallback(ConfigurationIssue(.error, "schemaVersion", error.message))
            } catch {
                return fallback(ConfigurationIssue(.error, "schemaVersion", "Configuration migration failed."))
            }
        }

        issues += ConfigurationValidator.unknownKeyIssues(in: document)

        let configuration: MacUpConfiguration
        do {
            let normalized = try JSONSerialization.data(withJSONObject: document)
            configuration = try JSONDecoder().decode(MacUpConfiguration.self, from: normalized)
        } catch let error as DecodingError {
            return fallback(ConfigurationValidator.describe(error))
        } catch {
            return fallback(ConfigurationIssue(.error, "", "The configuration could not be decoded."))
        }

        issues += ConfigurationValidator.semanticIssues(in: configuration)
        return LoadedConfiguration(
            configuration: configuration,
            source: .file,
            path: path,
            issues: issues,
            migratedFromSchemaVersion: migratedFrom
        )
    }

    // MARK: Saving

    /// Writes `configuration` atomically with owner-only permissions.
    public func save(_ configuration: MacUpConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(configuration)
        data.append(0x0A)
        try writeAtomically(data)
    }

    /// Persists an in-memory migration after backing up the original file.
    /// Returns the backup's location.
    @discardableResult
    public func persistMigration(of loaded: LoadedConfiguration, now: Date = Date()) throws -> URL {
        guard let oldVersion = loaded.migratedFromSchemaVersion else {
            throw MacUpError(.configurationInvalid, "The configuration does not need migration.")
        }
        guard !loaded.hasErrors else {
            throw MacUpError(.configurationInvalid, "An invalid configuration is never migrated; fix the reported errors first.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).backup-v\(oldVersion)-\(formatter.string(from: now))")
        let original = try Data(contentsOf: fileURL)
        try Self.createExclusively(backup.path, contents: original)
        try save(loaded.configuration)
        return backup
    }

    private func writeAtomically(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var directoryInfo = stat()
        guard stat(directory.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw MacUpError(.configurationInvalid, "The configuration directory is not a directory.")
        }
        if let problem = Self.ownershipIssues(directoryInfo, subject: "The configuration directory", path: directory.path).first {
            throw MacUpError(.configurationInvalid, problem.message)
        }

        var existing = stat()
        if lstat(fileURL.path, &existing) == 0 {
            switch existing.st_mode & S_IFMT {
            case S_IFLNK:
                throw MacUpError(
                    .configurationInvalid,
                    "The configuration file is a symlink; MacUp will not replace it.",
                    recoverySuggestion: "Replace the symlink with a regular file, or edit the target yourself."
                )
            case S_IFREG:
                break
            default:
                throw MacUpError(.configurationInvalid, "The configuration path exists and is not a regular file.")
            }
        }

        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try Self.createExclusively(temporary.path, contents: data)
        guard rename(temporary.path, fileURL.path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary.path)
            throw MacUpError(.configurationInvalid, "The configuration could not be saved: \(reason).")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }

    /// Creates a new owner-only file. Fails if anything (including a symlink)
    /// already exists at `path`.
    private static func createExclusively(_ path: String, contents: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw MacUpError(.configurationInvalid, "Could not create \(path): \(String(cString: strerror(errno))).")
        }
        var failure: Int32 = 0
        contents.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0 && fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure != 0 {
            unlink(path)
            throw MacUpError(.configurationInvalid, "Could not write \(path): \(String(cString: strerror(failure))).")
        }
    }

    /// Files that decide what MacUp may change must belong to the user and
    /// must not be writable by anyone else.
    static func ownershipIssues(_ info: stat, subject: String, path: String) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []
        if info.st_uid != getuid() {
            issues.append(ConfigurationIssue(.error, "", "\(subject) is owned by another user."))
        }
        if info.st_mode & (S_IWGRP | S_IWOTH) != 0 {
            issues.append(ConfigurationIssue(
                .error,
                "",
                "\(subject) is writable by other users. Fix with: chmod go-w \(CommandInvocation.quoted(path))"
            ))
        }
        return issues
    }

    /// An integer that was written as an integer (not a boolean or fraction).
    static func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        return NSNumber(value: integer) == number ? integer : nil
    }
}
