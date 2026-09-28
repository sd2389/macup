import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("What differs between two versions")
struct VersionDifferenceTests {
    @Test("Every part is listed, and the summary names only the ones that change")
    func partsAndSummary() throws {
        let difference = try #require(VersionDifference(from: "9.7.1", to: "26.7.0_2"))
        #expect(difference.parts.map(\.name) == ["Major", "Minor", "Patch", "Packaging revision"])
        #expect(difference.changedParts.map(\.name) == ["Major", "Patch", "Packaging revision"])
        #expect(difference.summary == "Major 9 → 26, patch 1 → 0, packaging revision none → 2.")
    }

    @Test("Versions of different lengths are compared part by part, with the missing part as 0")
    func differentLengths() throws {
        let difference = try #require(VersionDifference(from: "1.2", to: "1.2.1"))
        #expect(difference.summary == "Patch 0 → 1.")
    }

    @Test("A pre-release and a build part get their own names")
    func prereleaseAndBuild() throws {
        let prerelease = try #require(VersionDifference(from: "2.0.0-rc.1", to: "2.0.0"))
        #expect(prerelease.summary == "Pre-release rc.1 → none.")
        let build = try #require(VersionDifference(from: "124.0.6367.60", to: "124.0.6367.61"))
        #expect(build.summary == "Build 60 → 61.")
    }

    @Test("A version MacUp cannot parse has no breakdown rather than a guessed one")
    func opaqueVersions() {
        #expect(VersionDifference(from: "latest", to: "1.0") == nil)
        #expect(VersionDifference(from: "1.0,20240101", to: "1.1,20240301") == nil)
    }

    @Test("Candidates without an installed version have no breakdown")
    func noInstalledVersion() throws {
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "brew:git"), kind: .formula, displayName: "git",
            installedVersion: nil, availableVersion: "2.44.0"
        )
        #expect(candidate.versionDifference == nil)
    }
}

@Suite("Where to read about a release")
struct ReleaseInfoLinkTests {
    private func candidate(_ id: String, _ version: AvailableVersion, details: [String: String] = [:]) throws -> UpdateCandidate {
        UpdateCandidate(
            id: try PackageID(parsing: id), kind: .formula, displayName: id,
            installedVersion: "1.0.0", availableVersion: version, details: details
        )
    }

    @Test("npm gets the registry page for exactly the new version, scoped names included")
    func npmPages() throws {
        let plain = try #require(try candidate("npm:npm", "12.1.0").releaseInfoLink)
        #expect(plain.url.absoluteString == "https://www.npmjs.com/package/npm/v/12.1.0")
        #expect(plain.title == "npm page for 12.1.0")
        let scoped = try #require(try candidate("npm:@anthropic-ai/claude-code", "2.1.284").releaseInfoLink)
        #expect(scoped.url.absoluteString == "https://www.npmjs.com/package/@anthropic-ai/claude-code/v/2.1.284")
    }

    @Test("A version with characters npm does not use gets no link")
    func npmOddVersion() throws {
        #expect(try candidate("npm:npm", "1.0.0/../../evil").releaseInfoLink == nil)
        #expect(try candidate("npm:npm", "1.0.0?x=1").releaseInfoLink == nil)
    }

    @Test("Homebrew links to its homepage only when it is a plain https address")
    func homebrewHomepage() throws {
        let good = try #require(try candidate("brew:git", "2.44.0", details: ["homepage": "https://git-scm.com"]).releaseInfoLink)
        #expect(good.url.absoluteString == "https://git-scm.com")
        for unsafe in ["javascript:alert(1)", "http://example.com", "file:///etc/passwd", "https://user:pw@example.com", "https://"] {
            #expect(try candidate("brew:git", "2.44.0", details: ["homepage": unsafe]).releaseInfoLink == nil, "\(unsafe)")
        }
        #expect(try candidate("brew:git", "2.44.0").releaseInfoLink == nil)
    }

    @Test("mise and macOS have nothing MacUp can link to")
    func noLink() throws {
        #expect(try candidate("mise:node", "24.20.0").releaseInfoLink == nil)
    }
}
