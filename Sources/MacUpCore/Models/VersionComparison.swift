import Foundation

/// How an available version differs from the installed one.
public enum VersionChange: String, Sendable, Hashable, Codable, CaseIterable {
    case major
    case minor
    case patch
    /// A fourth-or-later numeric component changed (for example 124.0.6367.60 → .61).
    case build
    /// Same upstream version, new packaging revision (Homebrew `1.2.3` → `1.2.3_1`).
    case revision
    /// A pre-release version is involved.
    case prerelease
    /// The versions compare equal.
    case none
    /// The "available" version is older than the installed one.
    case downgrade
    /// The versions could not be compared meaningfully.
    case unknown

    public var displayName: String {
        switch self {
        case .major: "major"
        case .minor: "minor"
        case .patch: "patch"
        case .build: "build"
        case .revision: "revision"
        case .prerelease: "pre-release"
        case .none: "same version"
        case .downgrade: "downgrade"
        case .unknown: "unclassified"
        }
    }
}

/// How a project numbers releases, which decides what counts as "major".
public enum VersionScheme: String, Sendable, Hashable, Codable {
    /// MAJOR.MINOR.PATCH. Under 1.0, a minor change counts as major
    /// (matching npm's caret semantics).
    case standard
    /// Projects whose second component carries breaking changes, such as
    /// Python (3.12 → 3.13) and Ruby (3.3 → 3.4).
    case minorReleasesAreMajor
}

/// Compares version strings without pretending they are all SemVer.
///
/// A version is parsed only when it is clearly numeric-dotted
/// (`1`, `1.2`, `1.2.3.4`), optionally with a leading `v`, a SemVer
/// pre-release (`-rc.1`), build metadata (`+abc`), or a Homebrew revision
/// (`_2`). Anything else — dates with letters, `HEAD`, comma-separated cask
/// versions — is opaque, and opaque comparisons are `.unknown`.
public enum VersionComparator {
    public static func classify(
        from installed: String,
        to available: String,
        scheme: VersionScheme = .standard
    ) -> VersionChange {
        guard let old = ParsedVersion(installed), let new = ParsedVersion(available) else {
            return installed == available ? .none : .unknown
        }
        if old == new { return .none }
        if new < old { return .downgrade }
        if !new.prerelease.isEmpty { return .prerelease }

        let width = max(old.components.count, new.components.count)
        let oldCore = old.padded(to: width)
        let newCore = new.padded(to: width)
        guard let index = oldCore.indices.first(where: { oldCore[$0] != newCore[$0] }) else {
            return old.prerelease != new.prerelease ? .prerelease : .revision
        }

        switch scheme {
        case .minorReleasesAreMajor:
            switch index {
            case 0, 1: return .major
            case 2: return .patch
            default: return .build
            }
        case .standard:
            let leadingMajor = oldCore[0]
            let leadingMinor = width > 1 ? oldCore[1] : 0
            switch index {
            case 0:
                return .major
            case 1:
                return leadingMajor == 0 ? .major : .minor
            case 2:
                return leadingMajor == 0 && leadingMinor == 0 ? .major : .patch
            default:
                return .build
            }
        }
    }

    /// Orders two versions when both parse; `nil` when either is opaque.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = ParsedVersion(lhs), let right = ParsedVersion(rhs) else { return nil }
        if left < right { return .orderedAscending }
        if right < left { return .orderedDescending }
        return .orderedSame
    }
}

/// A strictly parsed numeric version. Internal: callers use ``VersionComparator``.
struct ParsedVersion: Comparable {
    let components: [Int]
    let prerelease: [String]
    let revision: Int

    init?(_ raw: String) {
        var text = Substring(raw.trimmingCharacters(in: .whitespaces))
        if let first = text.first, first == "v" || first == "V",
           let second = text.dropFirst().first, second.isASCII, second.isNumber {
            text = text.dropFirst()
        }
        if let plus = text.firstIndex(of: "+") {
            // Build metadata: dot-separated identifiers, ignored for precedence (SemVer §10).
            let metadata = text[text.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false)
            guard metadata.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isIdentifierCharacter) }) else { return nil }
            text = text[..<plus]
        }

        var revision = 0
        if let underscore = text.lastIndex(of: "_") {
            let digits = text[text.index(after: underscore)...]
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else {
                return nil
            }
            revision = value
            text = text[..<underscore]
        }

        var prerelease: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let identifiers = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isIdentifierCharacter) })
            else { return nil }
            prerelease = identifiers.map(String.init)
            text = text[..<dash]
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...6).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 18, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part)
            else { return nil }
            components.append(value)
        }

        self.components = components
        self.prerelease = prerelease
        self.revision = revision
    }

    func padded(to width: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, width - components.count))
    }

    private static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-")
    }

    static func == (lhs: ParsedVersion, rhs: ParsedVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: width) == rhs.padded(to: width)
            && lhs.prerelease == rhs.prerelease
            && lhs.revision == rhs.revision
    }

    static func < (lhs: ParsedVersion, rhs: ParsedVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        let left = lhs.padded(to: width)
        let right = rhs.padded(to: width)
        if left != right { return left.lexicographicallyPrecedes(right) }
        // A pre-release sorts before the release it precedes.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (false, true): return true
        case (true, false): return false
        case (false, false):
            if lhs.prerelease != rhs.prerelease { return precedes(lhs.prerelease, rhs.prerelease) }
        case (true, true):
            break
        }
        return lhs.revision < rhs.revision
    }

    /// SemVer §11 pre-release precedence.
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }
}
