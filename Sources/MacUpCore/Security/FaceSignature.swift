import Foundation

/// A numeric summary of one picture of a face.
///
/// macOS has no public face-recognition API: `libfaceCore` is private, and
/// Vision offers face *detection* only. What MacUp can do is ask Vision for an
/// image feature print of the cropped face and compare feature prints by
/// distance. That is image similarity, not identity, and this type is named
/// for what it is.
public struct FaceSignature: Sendable, Hashable, Codable {
    public var values: [Float]

    public init(values: [Float]) {
        self.values = values
    }

    /// Euclidean distance, the same measure Vision's own `computeDistance`
    /// uses. Computed here so the decision is testable without a camera.
    /// `nil` when the two were produced by different Vision revisions and
    /// cannot be compared — which is a refusal, never a match.
    public func distance(to other: FaceSignature) -> Float? {
        guard values.count == other.values.count, !values.isEmpty else { return nil }
        var sum: Float = 0
        for index in values.indices {
            let difference = values[index] - other.values[index]
            sum += difference * difference
        }
        return sum.squareRoot()
    }
}

/// The samples MacUp keeps for the person who enrolled.
public struct FaceEnrollment: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1
    /// Never smaller than this: one sample cannot show how much a face varies.
    public static let minimumSamples = 3

    public var schemaVersion: Int
    public var createdAt: Date
    public var signatures: [FaceSignature]

    public init(schemaVersion: Int = FaceEnrollment.currentSchemaVersion, createdAt: Date = Date(), signatures: [FaceSignature]) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.signatures = signatures
    }

    /// The largest distance between two samples of the same face.
    ///
    /// This is the honest measure of how well matching can work: a threshold
    /// below it will reject the enrolled person, and a threshold far above it
    /// will accept other people. `nil` when the samples cannot be compared.
    public var sampleSpread: Float? {
        guard signatures.count > 1 else { return nil }
        var largest: Float = 0
        for (index, signature) in signatures.enumerated() {
            for other in signatures[(index + 1)...] {
                guard let distance = signature.distance(to: other) else { return nil }
                largest = max(largest, distance)
            }
        }
        return largest
    }
}

/// The result of comparing a live picture with what was enrolled.
public struct FaceMatch: Sendable, Hashable {
    /// Distance to the closest enrolled sample.
    public var distance: Float
    public var threshold: Float
    public var isMatch: Bool { distance <= threshold }

    public init(distance: Float, threshold: Float) {
        self.distance = distance
        self.threshold = threshold
    }
}

/// Compares a live signature with an enrollment. Pure: no camera, no Vision,
/// so every decision here is covered by tests.
public struct FaceComparator: Sendable {
    /// Distance at or below which MacUp treats two pictures as the same face.
    ///
    /// There is no principled value: Vision's feature prints were built for
    /// image similarity, not identity. The default is deliberately tight, and
    /// `macup security face status` reports the spread of the enrolled samples
    /// so the number can be judged rather than trusted.
    public static let defaultThreshold = Float(MacUpConfiguration.SecuritySettings.defaultFaceMatchThreshold)

    public var threshold: Float

    public init(threshold: Float = FaceComparator.defaultThreshold) {
        self.threshold = threshold
    }

    /// `nil` when nothing could be compared, which the caller treats as a
    /// refusal (CLAUDE.md §2: ambiguity means skip and explain).
    public func match(_ live: FaceSignature, against enrollment: FaceEnrollment) -> FaceMatch? {
        var closest: Float?
        for signature in enrollment.signatures {
            guard let distance = live.distance(to: signature) else { continue }
            closest = min(closest ?? distance, distance)
        }
        guard let closest else { return nil }
        return FaceMatch(distance: closest, threshold: threshold)
    }
}

/// Where the enrollment lives: MacUp's own state directory, owner-only, never
/// leaving the Mac. It holds numbers derived from a picture, not a picture.
public struct FaceEnrollmentStore: Sendable {
    public static let fileName = "face-enrollment.json"

    public var paths: MacUpPaths
    public var fileSystem: any FileSystem

    public init(paths: MacUpPaths, fileSystem: any FileSystem = LocalFileSystem()) {
        self.paths = paths
        self.fileSystem = fileSystem
    }

    public var path: String { paths.stateDirectory + "/" + Self.fileName }

    /// `nil` when nobody has enrolled. Throws when a file exists but cannot be
    /// read as an enrollment, rather than silently behaving as if none exists.
    public func load() throws -> FaceEnrollment? {
        guard let data = fileSystem.contents(atPath: path, maximumBytes: 4 * 1024 * 1024) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let enrollment = try decoder.decode(FaceEnrollment.self, from: data)
            guard enrollment.schemaVersion == FaceEnrollment.currentSchemaVersion else {
                throw MacUpError(
                    .configurationInvalid,
                    "The stored face enrollment was written by a different version of MacUp.",
                    recoverySuggestion: "Enroll again, or remove it with `macup security face forget`."
                )
            }
            return enrollment
        } catch let error as MacUpError {
            throw error
        } catch {
            throw MacUpError(
                .parseFailed,
                "The stored face enrollment could not be read.",
                recoverySuggestion: "Remove it with `macup security face forget` and enroll again."
            )
        }
    }

    public func save(_ enrollment: FaceEnrollment) throws {
        guard enrollment.signatures.count >= FaceEnrollment.minimumSamples else {
            throw MacUpError(
                .verificationFailed,
                "MacUp needs at least \(FaceEnrollment.minimumSamples) samples to enroll a face."
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try PrivateDirectory(paths.stateDirectory).write(try encoder.encode(enrollment), named: Self.fileName)
    }

    @discardableResult
    public func remove() throws -> Bool {
        guard fileSystem.fileExists(atPath: path) else { return false }
        return try PrivateDirectory(paths.stateDirectory).remove(named: Self.fileName)
    }
}
