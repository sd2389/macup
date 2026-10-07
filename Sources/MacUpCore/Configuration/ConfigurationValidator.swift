import Foundation

/// A problem found in the configuration file.
public struct ConfigurationIssue: Sendable, Hashable, Codable {
    public enum Severity: String, Sendable, Hashable, Codable {
        /// Automatic modification is disabled until this is fixed.
        case error
        /// Worth knowing; does not disable anything.
        case warning
    }

    public var severity: Severity
    /// Location in the file, such as `providers.npm.policy`. Empty for the whole file.
    public var path: String
    public var message: String

    public init(_ severity: Severity, _ path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

/// Validates configuration strictly. Anything MacUp cannot interpret with
/// certainty is an error, because a misread policy could let an update run
/// that the user meant to block.
public enum ConfigurationValidator {
    static let topLevelKeys: Set<String> = ["schemaVersion", "global", "providers", "items", "schedule", "privacy", "security"]
    static let globalKeys: Set<String> = ["defaultPolicy", "confirmMajorUpdates"]
    static let providerKeys: Set<String> = ["enabled", "policy", "executablePath"]
    static let itemKeys: Set<String> = ["policy", "skipVersion", "note"]
    static let scheduleKeys: Set<String> = ["enabled", "frequency", "time", "weekday", "refresh", "installsAutoUpdates"]
    static let securityKeys: Set<String> = ["requireApproval", "allowPasswordFallback", "faceUnlock", "faceMatchThreshold"]
    static let privacyKeys: Set<String> = ["telemetry"]

    /// Executable file names that a configured `executablePath` must end in.
    static let executableNames: [ProviderID: String] = [.homebrew: "brew", .npm: "npm", .mise: "mise"]

    /// Reports keys MacUp does not recognize. Typos must not be ignored:
    /// `"enabeld": false` would otherwise leave a provider enabled.
    public static func unknownKeyIssues(in object: [String: Any]) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        func check(_ value: Any?, _ allowed: Set<String>, at path: String) {
            guard let dictionary = value as? [String: Any] else { return }
            for key in dictionary.keys.sorted() where !allowed.contains(key) {
                let location = path.isEmpty ? key : "\(path).\(key)"
                issues.append(ConfigurationIssue(
                    .error,
                    location,
                    "Unknown key '\(TerminalText.sanitize(key))'. Allowed keys: \(allowed.sorted().joined(separator: ", "))."
                ))
            }
        }

        check(object, topLevelKeys, at: "")
        check(object["global"], globalKeys, at: "global")
        check(object["schedule"], scheduleKeys, at: "schedule")
        check(object["security"], securityKeys, at: "security")
        check(object["privacy"], privacyKeys, at: "privacy")
        if let providers = object["providers"] as? [String: Any] {
            for (name, value) in providers { check(value, providerKeys, at: "providers.\(name)") }
        }
        if let items = object["items"] as? [String: Any] {
            for (name, value) in items { check(value, itemKeys, at: "items.\(name)") }
        }
        return issues
    }

    /// Checks values that decoded successfully but are not allowed.
    public static func semanticIssues(in configuration: MacUpConfiguration) -> [ConfigurationIssue] {
        var issues: [ConfigurationIssue] = []

        if configuration.schemaVersion != MacUpConfiguration.currentSchemaVersion {
            issues.append(ConfigurationIssue(
                .error,
                "schemaVersion",
                "Expected schema version \(MacUpConfiguration.currentSchemaVersion), found \(configuration.schemaVersion)."
            ))
        }

        let globalPolicies: Set<UpdatePolicy> = [.auto, .ask, .ignore]
        if !globalPolicies.contains(configuration.global.defaultPolicy) {
            issues.append(ConfigurationIssue(
                .error,
                "global.defaultPolicy",
                "The global default policy must be auto, ask, or ignore; '\(configuration.global.defaultPolicy.rawValue)' has nothing to apply to."
            ))
        }

        for (name, settings) in configuration.providers.sorted(by: { $0.key < $1.key }) {
            let path = "providers.\(name)"
            let provider = ProviderID(rawValue: name)
            guard provider.isKnown else {
                issues.append(ConfigurationIssue(
                    .error,
                    path,
                    "Unknown provider '\(TerminalText.sanitize(name))'. Known providers: \(ProviderID.known.map(\.rawValue).joined(separator: ", "))."
                ))
                continue
            }
            if settings.policy == .pin {
                issues.append(ConfigurationIssue(.error, "\(path).policy", "Pin applies to individual items, not to a whole provider."))
            }
            if provider == .macos && settings.policy == .auto {
                issues.append(ConfigurationIssue(
                    .warning,
                    "\(path).policy",
                    "macOS updates are always Ask First in this version of MacUp; 'auto' has no effect."
                ))
            }
            if let executablePath = settings.executablePath {
                issues += executablePathIssues(executablePath, provider: provider, path: "\(path).executablePath")
            }
        }

        for (name, settings) in configuration.items.sorted(by: { $0.key < $1.key }) {
            let path = "items.\(name)"
            let id: PackageID
            do {
                id = try PackageID(parsing: name)
            } catch {
                issues.append(ConfigurationIssue(.error, path, "Invalid package ID: \(error)"))
                continue
            }
            if id.provider == .macos && settings.policy == .auto {
                issues.append(ConfigurationIssue(
                    .warning,
                    "\(path).policy",
                    "macOS updates are always Ask First in this version of MacUp; 'auto' has no effect."
                ))
            }
            // Errors rather than warnings, like every other value MacUp cannot
            // take as written. A skipped version with a stray space would
            // never match, so it would quietly stop holding its version back.
            if let version = settings.skipVersion,
               let problem = MacUpConfiguration.ItemSettings.problem(withSkipVersion: version) {
                issues.append(ConfigurationIssue(.error, "\(path).skipVersion", problem))
            }
            if let note = settings.note, let problem = MacUpConfiguration.ItemSettings.problem(withNote: note) {
                issues.append(ConfigurationIssue(.error, "\(path).note", problem))
            }
        }

        if !isValidTime(configuration.schedule.time) {
            issues.append(ConfigurationIssue(
                .error,
                "schedule.time",
                "Use 24-hour HH:mm, for example 23:00; found '\(TerminalText.sanitize(configuration.schedule.time))'."
            ))
        }

        let threshold = configuration.security.faceMatchThreshold
        if !(threshold > 0 && threshold <= 5) {
            issues.append(ConfigurationIssue(
                .error,
                "security.faceMatchThreshold",
                "Use a distance greater than 0 and no more than 5; found \(threshold)."
            ))
        }
        if configuration.security.faceUnlock && !configuration.security.requireApproval {
            issues.append(ConfigurationIssue(
                .warning,
                "security.faceUnlock",
                "Face match is on but approval is not required, so MacUp never asks for it."
            ))
        }

        if configuration.privacy.telemetry {
            issues.append(ConfigurationIssue(
                .warning,
                "privacy.telemetry",
                "MacUp has no telemetry; this setting has no effect and nothing is sent."
            ))
        }
        return issues
    }

    private static func executablePathIssues(_ value: String, provider: ProviderID, path: String) -> [ConfigurationIssue] {
        guard let expectedName = executableNames[provider] else {
            return [ConfigurationIssue(.error, path, "\(provider.displayName) does not support a custom executable path.")]
        }
        guard value.hasPrefix("/"), !value.unicodeScalars.contains(where: TerminalText.isUnsafe) else {
            return [ConfigurationIssue(.error, path, "The executable path must be absolute.")]
        }
        guard (value as NSString).lastPathComponent == expectedName else {
            return [ConfigurationIssue(.error, path, "The executable path must point to a file named '\(expectedName)'.")]
        }
        return []
    }

    static func isValidTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let hour = Int(parts[0]), let minute = Int(parts[1])
        else { return false }
        return (0...23).contains(hour) && (0...59).contains(minute)
    }

    /// A human-readable explanation of a decoding failure.
    static func describe(_ error: DecodingError) -> ConfigurationIssue {
        func path(_ codingPath: [any CodingKey]) -> String {
            codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .typeMismatch(let type, let context):
            return ConfigurationIssue(.error, path(context.codingPath), "Expected \(describe(type)).")
        case .valueNotFound(let type, let context):
            return ConfigurationIssue(.error, path(context.codingPath), "Expected \(describe(type)), found null.")
        case .keyNotFound(let key, let context):
            return ConfigurationIssue(.error, path(context.codingPath + [key]), "Missing required key '\(key.stringValue)'.")
        case .dataCorrupted(let context):
            let location = path(context.codingPath)
            if location.hasSuffix("policy") || location.hasSuffix("defaultPolicy") {
                return ConfigurationIssue(.error, location, "Policy must be one of: \(UpdatePolicy.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return ConfigurationIssue(.error, location, TerminalText.sanitize(context.debugDescription))
        @unknown default:
            return ConfigurationIssue(.error, "", "The configuration could not be read.")
        }
    }

    private static func describe(_ type: Any.Type) -> String {
        switch type {
        case is Bool.Type: "true or false"
        case is Int.Type: "a whole number"
        case is String.Type: "a string"
        case is UpdatePolicy.Type: "a policy name"
        default: "a \(type)"
        }
    }
}
