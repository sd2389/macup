import Foundation
import Testing

@testable import MacUpCore

@Suite("VersionComparator")
struct VersionComparatorTests {
    @Test(
        "Classifies changes without assuming SemVer",
        arguments: [
            ("2.43.0", "2.44.0", VersionChange.minor),
            ("2.44.0", "2.44.1", .patch),
            ("1.9.9", "2.0.0", .major),
            ("v1.2.3", "v1.2.4", .patch),
            ("9.7.1", "26.7.0_2", .major),           // real Homebrew mysql output
            ("1.2.3", "1.2.3_1", .revision),
            ("1.2.3_1", "1.2.3_2", .revision),
            ("124.0.6367.60", "124.0.6367.61", .build),
            ("0.157.0", "0.158.0", .major),          // 0.x minor bumps may break
            ("0.2.3", "0.2.4", .patch),
            ("0.0.3", "0.0.4", .major),
            ("1.0.0-rc.1", "1.0.0", .prerelease),
            ("1.2.3", "1.3.0-beta.1", .prerelease),
            ("2.0.0", "1.9.0", .downgrade),
            ("1.2.3", "1.2.3", .none),
            ("1.2", "1.2.0", .none),
            ("1.0.0+build.1", "1.0.0+build.2", .none),
            ("24.19.0", "24.21.0", .minor),
            ("20250127.0", "20260817.0", .major),     // date-based; major is the conservative answer
            ("HEAD", "HEAD", .none),
            ("HEAD", "1.0", .unknown),
            ("latest", "1.0.0", .unknown),
            ("4.28.1,12345", "4.29.0,12400", .unknown), // cask version with build suffix
            ("1.0", "1.0.0.0.0.0.1", .unknown),       // too many components to trust
            ("", "1.0", .unknown),
        ]
    )
    func classifies(installed: String, available: String, expected: VersionChange) {
        #expect(VersionComparator.classify(from: installed, to: available) == expected)
    }

    @Test(
        "Python-style minor releases count as major",
        arguments: [
            ("3.12.13", "3.14.7", VersionChange.major),
            ("3.12.13", "3.12.14", .patch),
            ("3.3.0", "4.0.0", .major),
        ]
    )
    func minorReleasesAreMajor(installed: String, available: String, expected: VersionChange) {
        #expect(VersionComparator.classify(from: installed, to: available, scheme: .minorReleasesAreMajor) == expected)
    }

    @Test(
        "Pre-release precedence follows SemVer",
        arguments: [
            ("1.0.0-alpha", "1.0.0-alpha.1"),
            ("1.0.0-alpha.1", "1.0.0-alpha.beta"),
            ("1.0.0-beta.2", "1.0.0-beta.11"),
            ("1.0.0-rc.1", "1.0.0"),
            ("1.0.0", "1.0.0_1"),
        ]
    )
    func precedence(lower: String, higher: String) {
        #expect(VersionComparator.compare(lower, higher) == .orderedAscending)
        #expect(VersionComparator.compare(higher, lower) == .orderedDescending)
    }

    @Test("Opaque versions cannot be ordered")
    func opaque() {
        #expect(VersionComparator.compare("HEAD", "1.0") == nil)
        #expect(VersionComparator.compare("1.0", "1.0.0") == .orderedSame)
    }
}
