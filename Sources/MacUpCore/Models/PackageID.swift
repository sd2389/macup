/// The first part of a package identity, such as `brew` or `npm`.
public struct PackageNamespace: RawRepresentable, Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Homebrew formulae.
    public static let brew = PackageNamespace(rawValue: "brew")
    /// Homebrew casks.
    public static let brewCask = PackageNamespace(rawValue: "brew-cask")
    /// npm global packages.
    public static let npm = PackageNamespace(rawValue: "npm")
    /// mise-managed runtimes and tools.
    public static let mise = PackageNamespace(rawValue: "mise")
    /// macOS software updates.
    public static let macos = PackageNamespace(rawValue: "macos")

    public static let known: [PackageNamespace] = [.brew, .brewCask, .npm, .mise, .macos]

    public var provider: ProviderID? {
        switch self {
        case .brew, .brewCask: .homebrew
        case .npm: .npm
        case .mise: .mise
        case .macos: .macos
        default: nil
        }
    }

    public var description: String { rawValue }
}

/// A provider-qualified package identity: `brew:git`, `brew-cask:firefox`,
/// `npm:@anthropic-ai/claude-code`, `mise:node`, `macos:<update label>`.
///
/// Names are not assumed to be globally unique; the namespace is always part
/// of the identity. The name is everything after the first `:`, so names may
/// themselves contain colons (mise backends such as `mise:npm:prettier`).
public struct PackageID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let namespace: PackageNamespace
    public let name: String

    public enum ValidationError: Error, Sendable, Hashable, CustomStringConvertible {
        case missingNamespace(String)
        case unknownNamespace(String)
        case emptyName
        case surroundingWhitespace
        case unsafeCharacter
        case leadingDash
        case tooLong

        public var description: String {
            switch self {
            case .missingNamespace(let value):
                "'\(TerminalText.sanitize(value))' is not a package ID. Use <namespace>:<name>, for example brew:git."
            case .unknownNamespace(let namespace):
                "Unknown package namespace '\(TerminalText.sanitize(namespace))'. Known namespaces: "
                    + PackageNamespace.known.map(\.rawValue).joined(separator: ", ") + "."
            case .emptyName:
                "The package name is empty."
            case .surroundingWhitespace:
                "The package name has leading or trailing whitespace."
            case .unsafeCharacter:
                "The package name contains control or bidirectional-override characters."
            case .leadingDash:
                "The package name starts with '-', which a command could mistake for an option."
            case .tooLong:
                "The package name is longer than \(PackageID.maximumNameLength) characters."
            }
        }
    }

    public static let maximumNameLength = 256

    public init(_ namespace: PackageNamespace, _ name: String) throws {
        guard namespace.provider != nil else { throw ValidationError.unknownNamespace(namespace.rawValue) }
        if let problem = Self.validateName(name) { throw problem }
        self.namespace = namespace
        self.name = name
    }

    /// Parses `namespace:name`.
    public init(parsing value: String) throws {
        guard let separator = value.firstIndex(of: ":") else { throw ValidationError.missingNamespace(value) }
        try self.init(
            PackageNamespace(rawValue: String(value[..<separator])),
            String(value[value.index(after: separator)...])
        )
    }

    /// Why `name` cannot be part of a package ID, or `nil` if it can.
    ///
    /// Rejected names are never guessed at: a provider that reports one skips
    /// the item and records a finding instead.
    public static func validateName(_ name: String) -> ValidationError? {
        if name.isEmpty { return .emptyName }
        if name.count > maximumNameLength { return .tooLong }
        if name.unicodeScalars.contains(where: TerminalText.isUnsafe) { return .unsafeCharacter }
        if name.first?.isWhitespace == true || name.last?.isWhitespace == true { return .surroundingWhitespace }
        if name.hasPrefix("-") { return .leadingDash }
        return nil
    }

    public var provider: ProviderID {
        // Guaranteed by the initializers.
        namespace.provider ?? ProviderID(rawValue: namespace.rawValue)
    }

    public var rawValue: String { "\(namespace.rawValue):\(name)" }
    public var description: String { rawValue }

    public static func < (lhs: PackageID, rhs: PackageID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(parsing: value)
        } catch let error as ValidationError {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: error.description)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
