import Darwin
import Foundation

/// What kind of software TypeSafe judged a package to be. The raw values are
/// the option names MacUp offers, so an answer maps straight onto a case.
public enum SoftwareKind: String, Sendable, Hashable, Codable, CaseIterable {
    case database
    case runtime
    case service
    case cliTool = "cli_tool"
    case library
    case guiApp = "gui_app"
    case packageManager = "package_manager"
    case other

    public var displayName: String {
        switch self {
        case .database: "a database or data store"
        case .runtime: "a language runtime or toolchain"
        case .service: "a background service"
        case .cliTool: "a command-line tool"
        case .library: "a library"
        case .guiApp: "an app"
        case .packageManager: "a package manager"
        case .other: "something else"
        }
    }
}

/// TypeSafe's raw judgments about one update, kept so the same update is not
/// sent twice. What MacUp does with them is decided in code each time they
/// are read (``AICaution``), so a change to that code never needs a new
/// request.
public struct AIEstimate: Sendable, Hashable, Codable {
    public var item: PackageID
    public var installedVersion: String?
    public var availableVersion: String
    /// The versioned model that answered, such as `jev-1.13.0`.
    public var model: String
    public var askedAt: Date
    public var softwareKind: SoftwareKind
    public var softwareKindProbability: Double
    public var softwareKindConfidence: Double
    /// The probability that a major upgrade of it commonly migrates or
    /// rewrites the data it keeps.
    public var dataMigrationProbability: Double

    public init(
        item: PackageID,
        installedVersion: String?,
        availableVersion: String,
        model: String,
        askedAt: Date,
        softwareKind: SoftwareKind,
        softwareKindProbability: Double,
        softwareKindConfidence: Double,
        dataMigrationProbability: Double
    ) {
        self.item = item
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.model = model
        self.askedAt = askedAt
        self.softwareKind = softwareKind
        self.softwareKindProbability = softwareKindProbability
        self.softwareKindConfidence = softwareKindConfidence
        self.dataMigrationProbability = dataMigrationProbability
    }

    /// An estimate belongs to one version change of one item. A newer update
    /// is a different question, so it gets no answer until it is asked.
    public func matches(_ candidate: UpdateCandidate) -> Bool {
        item == candidate.id
            && installedVersion == candidate.installedVersion?.raw
            && availableVersion == candidate.availableVersion.raw
    }

    var isValid: Bool {
        [softwareKindProbability, softwareKindConfidence, dataMigrationProbability]
            .allSatisfy { $0.isFinite && (0...1).contains($0) }
            && !model.isEmpty && model.count <= 128
    }
}

/// Where estimates are kept. Behind a protocol so tests, and debug snapshots,
/// keep them in memory rather than in the state directory of the Mac running
/// them.
public protocol AIEstimateCaching: Sendable {
    func load() throws -> [AIEstimate]
    /// Adds an estimate, replacing any for the same version change.
    func save(_ estimate: AIEstimate) throws
    /// Deletes every estimate. Returns how many there were.
    @discardableResult
    func clear() throws -> Int
}

/// Estimates in `ai-estimates.json` in MacUp's state directory: owner-only,
/// replaced atomically, never written through a symlink.
public struct AIEstimateFile: AIEstimateCaching {
    public static let fileName = "ai-estimates.json"
    /// The newest this many are kept.
    static let maximumEntries = 500

    public var paths: MacUpPaths

    public init(paths: MacUpPaths) {
        self.paths = paths
    }

    public var path: String { paths.stateDirectory + "/" + Self.fileName }

    private struct Document: Codable {
        var schemaVersion: Int
        var estimates: [AIEstimate]
    }

    public func load() throws -> [AIEstimate] {
        guard let data = LocalFileSystem().contents(atPath: path, maximumBytes: 4 * 1024 * 1024) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(Document.self, from: data),
              document.schemaVersion == 1,
              document.estimates.allSatisfy(\.isValid)
        else {
            throw MacUpError(
                .parseFailed,
                "MacUp could not read its saved AI estimates, so it is not applying any of them.",
                recoverySuggestion: "Delete them with `macup ai forget`, or Clear Estimates in the app, and ask again."
            )
        }
        return document.estimates
    }

    public func save(_ estimate: AIEstimate) throws {
        var estimates = (try? load()) ?? []
        estimates.removeAll {
            $0.item == estimate.item && $0.installedVersion == estimate.installedVersion
                && $0.availableVersion == estimate.availableVersion
        }
        estimates.append(estimate)
        estimates = Array(estimates.sorted { $0.askedAt < $1.askedAt }.suffix(Self.maximumEntries))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try replace(with: try encoder.encode(Document(schemaVersion: 1, estimates: estimates)))
    }

    @discardableResult
    public func clear() throws -> Int {
        let count = (try? load().count) ?? 0
        guard LocalFileSystem().fileExists(atPath: path) else { return 0 }
        try PrivateDirectory(paths.stateDirectory).remove(named: Self.fileName)
        return count
    }

    /// Writes a temporary file beside the real one, then renames it over, so
    /// a reader sees the old estimates or the new ones and never half of
    /// either.
    private func replace(with data: Data) throws {
        let directory = try PrivateDirectory(paths.stateDirectory)
        let temporary = ".\(Self.fileName).tmp-\(UUID().uuidString)"
        try directory.write(data, named: temporary)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            _ = try? directory.remove(named: temporary)
            throw MacUpError(.configurationInvalid, "\(directory.path) is no longer a directory MacUp can use.")
        }
        defer { close(descriptor) }
        guard renameat(descriptor, temporary, descriptor, Self.fileName) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = try? directory.remove(named: temporary)
            throw MacUpError(.configurationInvalid, "The AI estimates could not be saved: \(reason).")
        }
        fsync(descriptor)
    }
}

/// Estimates held in memory only.
public final class InMemoryAIEstimateCache: AIEstimateCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var estimates: [AIEstimate]

    public init(_ estimates: [AIEstimate] = []) {
        self.estimates = estimates
    }

    public func load() throws -> [AIEstimate] {
        lock.withLock { estimates }
    }

    public func save(_ estimate: AIEstimate) throws {
        lock.withLock {
            estimates.removeAll {
                $0.item == estimate.item && $0.installedVersion == estimate.installedVersion
                    && $0.availableVersion == estimate.availableVersion
            }
            estimates.append(estimate)
        }
    }

    @discardableResult
    public func clear() throws -> Int {
        lock.withLock {
            defer { estimates = [] }
            return estimates.count
        }
    }
}
