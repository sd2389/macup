import AppKit
import Foundation
import Security

/// An app that is open right now.
public struct RunningApplication: Sendable, Hashable, Codable {
    public var name: String
    public var processIdentifier: Int32

    public init(name: String, processIdentifier: Int32) {
        self.name = name
        self.processIdentifier = processIdentifier
    }
}

/// Which apps are open. Behind a protocol so no test depends on what happens
/// to be running on the machine it runs on.
public protocol RunningApplicationChecking: Sendable {
    /// Open apps with this bundle identifier, or launched from this bundle.
    func running(bundleIdentifier: String?, bundlePath: String) async -> [RunningApplication]
}

/// The apps macOS reports as running, through `NSRunningApplication`.
///
/// An app is matched by bundle identifier and by where it was launched from,
/// so a second copy of an app elsewhere on disk still counts, and so does an
/// app whose Info.plist MacUp could not read.
public struct SystemRunningApplications: RunningApplicationChecking {
    public init() {}

    public func running(bundleIdentifier: String?, bundlePath: String) async -> [RunningApplication] {
        let canonical = FileTree.canonicalPath(bundlePath) ?? bundlePath
        let own = ProcessInfo.processInfo.processIdentifier
        return await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> RunningApplication? in
                guard app.processIdentifier != own, !app.isTerminated else { return nil }
                let path = app.bundleURL.flatMap { FileTree.canonicalPath($0.path) ?? $0.path }
                let sameBundle = bundleIdentifier != nil && app.bundleIdentifier == bundleIdentifier
                guard sameBundle || path == canonical else { return nil }
                return RunningApplication(
                    name: app.localizedName ?? (bundlePath as NSString).lastPathComponent,
                    processIdentifier: app.processIdentifier
                )
            }
        }
    }
}

/// Reads who signed an app, which is how a developer's shared group
/// container is tied to it. Behind a protocol so tests can describe a signed
/// app without one.
public protocol CodeSignatureReading: Sendable {
    /// The Apple team identifier in the bundle's signature, or `nil` when it
    /// names none (unsigned, ad-hoc, or unreadable).
    func teamIdentifier(ofBundleAt path: String) -> String?

    /// Who signed the bundle, **after checking that the signature is valid**
    /// — `nil` when it is unsigned, ad-hoc, broken, or unreadable. Used where
    /// MacUp tells somebody about a program it found and will not run, so the
    /// name it prints is one Apple's check stands behind rather than a claim
    /// copied out of a bundle.
    func verifiedSigner(ofBundleAt path: String) -> String?
}

public extension CodeSignatureReading {
    /// Nothing, unless a reader implements it: a signer MacUp has not
    /// verified is never reported as one.
    func verifiedSigner(ofBundleAt path: String) -> String? { nil }
}

/// The signature on disk, read with the Security framework. Reading checks
/// nothing and launches nothing: it only asks what the signature says.
public struct SystemCodeSignatures: CodeSignatureReading {
    public init() {}

    public func teamIdentifier(ofBundleAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              Self.isTeamIdentifier(team)
        else { return nil }
        return team
    }

    /// Who signed it, once Apple's own check has passed. The order matters:
    /// `SecStaticCodeCheckValidity` first, and only then the leaf
    /// certificate's name, so an edited bundle whose signature no longer
    /// verifies reports nobody.
    public func verifiedSigner(ofBundleAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return nil }
        let name = TerminalText.sanitize(summary)
        return name.isEmpty ? nil : name
    }

    /// Ten upper-case letters and digits, which is every team identifier
    /// Apple issues. Anything else is not used to match a folder name.
    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
