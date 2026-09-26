/// Identifies an update provider (`homebrew`, `npm`, `mise`, `macos`).
public struct ProviderID: RawRepresentable, Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let homebrew = ProviderID(rawValue: "homebrew")
    public static let npm = ProviderID(rawValue: "npm")
    public static let mise = ProviderID(rawValue: "mise")
    public static let macos = ProviderID(rawValue: "macos")

    /// Providers supported by this version of MacUp, in display order.
    public static let known: [ProviderID] = [.homebrew, .npm, .mise, .macos]

    public var isKnown: Bool { Self.known.contains(self) }

    public var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .mise: "mise"
        case .macos: "macOS"
        default: rawValue
        }
    }

    public var description: String { rawValue }

    public static func < (lhs: ProviderID, rhs: ProviderID) -> Bool {
        let order = known
        switch (order.firstIndex(of: lhs), order.firstIndex(of: rhs)) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs.rawValue < rhs.rawValue
        }
    }
}
