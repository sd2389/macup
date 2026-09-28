import Foundation

/// What differs between an installed and an available version, part by part.
///
/// Built only from the two version strings: it says which numbers change, not
/// what the release contains. It never counts releases in between, because a
/// jump from 9 to 26 may skip every number on the way (CLAUDE.md §21, no fake
/// precision).
public struct VersionDifference: Sendable, Hashable, Codable {
    public struct Part: Sendable, Hashable, Codable {
        /// "Major", "Minor", "Patch", "Build", "Part 5", "Pre-release", "Packaging revision".
        public var name: String
        public var from: String
        public var to: String

        public var changed: Bool { from != to }

        public init(name: String, from: String, to: String) {
            self.name = name
            self.from = from
            self.to = to
        }
    }

    /// Every part either version has, in order, changed or not.
    public var parts: [Part]

    public var changedParts: [Part] { parts.filter(\.changed) }

    /// One line naming what changes, such as "Major 9 → 26, packaging revision none → 2."
    public var summary: String {
        let changed = changedParts
        guard !changed.isEmpty else { return "The two versions are the same." }
        let described = changed.enumerated().map { index, part in
            let name = index == 0 ? part.name : part.name.lowercased()
            return "\(name) \(part.from) → \(part.to)"
        }
        return described.joined(separator: ", ") + "."
    }

    /// Nil when either version is not clearly numeric: MacUp does not guess
    /// at the structure of a version it cannot parse.
    public init?(from installed: String, to available: String) {
        guard let old = ParsedVersion(installed), let new = ParsedVersion(available) else { return nil }
        let names = ["Major", "Minor", "Patch", "Build"]
        let width = max(old.components.count, new.components.count)
        let oldCore = old.padded(to: width)
        let newCore = new.padded(to: width)
        var parts = (0..<width).map { index in
            Part(
                name: index < names.count ? names[index] : "Part \(index + 1)",
                from: String(oldCore[index]),
                to: String(newCore[index])
            )
        }
        if !old.prerelease.isEmpty || !new.prerelease.isEmpty {
            parts.append(Part(
                name: "Pre-release",
                from: old.prerelease.isEmpty ? "none" : old.prerelease.joined(separator: "."),
                to: new.prerelease.isEmpty ? "none" : new.prerelease.joined(separator: ".")
            ))
        }
        if old.revision != 0 || new.revision != 0 {
            parts.append(Part(
                name: "Packaging revision",
                from: old.revision == 0 ? "none" : String(old.revision),
                to: new.revision == 0 ? "none" : String(new.revision)
            ))
        }
        self.parts = parts
    }
}

/// A page where the user can read what a release contains.
///
/// MacUp only builds the address; it never fetches it. Opening it is the
/// user's own action in their browser, so MacUp still makes no network
/// request of its own (CLAUDE.md §18).
public struct ReleaseInfoLink: Sendable, Hashable, Codable {
    /// "npm page for 12.1.0", "Project home page".
    public var title: String
    public var url: URL

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    /// An `https` address with a host and no credentials, or nil. Provider
    /// output is untrusted, so anything else — `file:`, `javascript:`, a URL
    /// carrying a password — is refused rather than shown as a link.
    public static func safeURL(_ raw: String) -> URL? {
        guard raw.count <= 2048,
              let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url
        else { return nil }
        return url
    }
}

extension UpdateCandidate {
    /// What differs between the installed and the available version.
    public var versionDifference: VersionDifference? {
        installedVersion.flatMap { VersionDifference(from: $0.raw, to: availableVersion.raw) }
    }

    /// Where to read about the available version, when the provider says.
    public var releaseInfoLink: ReleaseInfoLink? {
        switch provider {
        case .npm:
            // The registry's page for exactly this version. Names and
            // versions are restricted to npm's own characters, so nothing
            // odd can reach the address.
            let version = availableVersion.raw
            guard Self.isNpmSafe(id.name), Self.isNpmSafe(version), !version.contains("/") else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "www.npmjs.com"
            components.path = "/package/\(id.name)/v/\(version)"
            return components.url.map { ReleaseInfoLink(title: "npm page for \(version)", url: $0) }
        case .homebrew:
            guard let homepage = details["homepage"], let url = ReleaseInfoLink.safeURL(homepage) else { return nil }
            return ReleaseInfoLink(title: "Project home page", url: url)
        default:
            return nil
        }
    }

    private static func isNpmSafe(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 214 && text.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "@/._-~+".contains($0))
        }
    }
}
