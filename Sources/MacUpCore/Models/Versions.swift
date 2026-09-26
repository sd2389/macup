/// A version string as the provider reported it for installed software.
///
/// Stored verbatim. MacUp never assumes a version is SemVer; see
/// ``VersionComparator`` for how versions are compared.
public struct InstalledVersion: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { raw }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// A version string the provider reports as available.
public struct AvailableVersion: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { raw }

    public init(from decoder: any Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}
