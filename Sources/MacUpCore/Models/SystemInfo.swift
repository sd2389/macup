import Darwin
import Foundation

/// Facts about the running Mac, gathered without launching processes.
public struct SystemInfo: Sendable, Hashable, Codable {
    /// For example `27.0` or `15.4.1`.
    public var productVersion: String
    /// For example `26A428`.
    public var buildVersion: String?
    /// For example `arm64`.
    public var architecture: String

    public init(productVersion: String, buildVersion: String?, architecture: String) {
        self.productVersion = productVersion
        self.buildVersion = buildVersion
        self.architecture = architecture
    }

    public static func current() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let fallback = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return SystemInfo(
            // kern.osproductversion reports the real version even to binaries
            // built with an older SDK, which ProcessInfo may not.
            productVersion: sysctlString("kern.osproductversion") ?? fallback,
            buildVersion: sysctlString("kern.osversion"),
            architecture: machine.isEmpty ? "unknown" : machine
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return value.isEmpty ? nil : value
    }
}
