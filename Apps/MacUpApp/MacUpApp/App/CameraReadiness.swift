import AVFoundation
import Foundation
import MacUpCore
import Security

/// This copy of MacUp's own code signature, as macOS reads it.
///
/// Reading it launches nothing, needs no entitlement, and changes nothing:
/// `SecCodeCopySelf` describes the code that is already running.
struct BundleSignature: Sendable, Hashable {
    /// The Apple team the signature names, when it names one. An ad-hoc
    /// signature names none.
    var teamIdentifier: String?
    /// Whether macOS reports the signature as ad-hoc, which is what
    /// `codesign --sign -` produces.
    var isAdHoc: Bool

    /// Whether macOS can attribute this copy of MacUp to a developer.
    ///
    /// This is the condition that decides whether privacy prompts can happen
    /// at all, so it is named for what it means rather than for how it is
    /// measured.
    var isAttributable: Bool { !isAdHoc && teamIdentifier != nil }

    /// Read once. The signature of running code cannot change underneath it,
    /// and the Security calls are not free.
    static let current = read()

    static func read() -> BundleSignature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return BundleSignature(teamIdentifier: nil, isAdHoc: true)
        }
        // Signing information is only available from the static (on-disk)
        // representation of the running code.
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return BundleSignature(teamIdentifier: nil, isAdHoc: true)
        }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else {
            return BundleSignature(teamIdentifier: nil, isAdHoc: true)
        }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let signatureFlags = dictionary[kSecCodeInfoFlags as String] as? UInt32
        // No flags reported and no team means nothing MacUp can treat as an
        // identity, which is the same situation as an explicit ad-hoc flag.
        let adHoc = signatureFlags.map { $0 & SecCodeSignatureFlags.adhoc.rawValue != 0 } ?? true
        return BundleSignature(teamIdentifier: team, isAdHoc: adHoc)
    }
}

/// What this build of MacUp can expect from the camera, and why.
///
/// macOS grants camera access per application identity and remembers the
/// answer against the code signature. A bundle signed ad-hoc has no team
/// identifier, so there is no developer for macOS to attribute it to: it never
/// presents the prompt, `AVCaptureDevice.authorizationStatus` stays
/// `notDetermined`, and the capture connection never goes live. The face match
/// therefore cannot work in a locally built MacUp. That is a property of how
/// the bundle is signed, not a fault in this code, and no amount of clicking in
/// System Settings changes it.
///
/// A bundle macOS will ask about needs a Developer ID certificate, which
/// `scripts/build-app.sh` neither has nor can create; even the ad-hoc
/// signature's hash changes on every build, so macOS could not remember a
/// decision if one were ever made. Face enrolment will start working when the
/// signing and notarization in docs/RELEASE.md is in place, and not before, so
/// MacUp says so where someone meets it rather than showing them a spinner.
struct CameraReadiness: Sendable, Hashable {
    var hasCamera: Bool
    /// The camera MacUp would open, named as macOS names it.
    var cameraName: String?
    var signature: BundleSignature
    var access: AVAuthorizationStatus

    static func current() -> CameraReadiness {
        CameraReadiness(
            hasCamera: FaceCamera.hasCamera,
            cameraName: FaceCamera.cameraName,
            signature: .current,
            access: AVCaptureDevice.authorizationStatus(for: .video)
        )
    }

    /// Why the camera cannot be used, in the words a reader should see, or
    /// `nil` when nothing known stands in the way.
    var problem: String? {
        if !hasCamera {
            return "This Mac has no camera MacUp can use."
        }
        // The signature decides this on its own, whatever `access` says. macOS
        // has been seen to report access as granted to an ad-hoc build and
        // still never make the capture connection live, so "authorized" is no
        // evidence the camera will work. Established by running
        // `MacUp --face-check`, not assumed.
        if !signature.isAttributable {
            return """
                This copy of MacUp is signed ad-hoc, so macOS has no developer \
                identity to attach a camera decision to. It never asks, and the \
                camera never starts. A signed build of MacUp is what changes \
                that; there is nothing to turn on in System Settings.
                """
        }
        switch access {
        case .denied:
            return """
                macOS is not letting MacUp use the camera. You can change that \
                in System Settings → Privacy & Security → Camera.
                """
        case .restricted:
            return "Camera access is not allowed on this Mac."
        default:
            return nil
        }
    }

    /// Whether a face could be enrolled right now.
    var canUse: Bool { problem == nil }

    /// The same finding as ``problem``, in the short lines `MacUp --face-check`
    /// prints. The two must agree: a diagnostic that disagrees with the screen
    /// is worse than none.
    var diagnosticLines: [String] {
        [
            "camera: \(cameraName ?? "none found")",
            "camera access: \(FaceCamera.accessDescription)",
            "signature: \(signature.isAdHoc ? "ad-hoc" : "identified")"
                + ", team \(signature.teamIdentifier ?? "none")",
            "usable: \(canUse ? "yes" : "no")",
        ] + (problem.map { ["reason: \($0)"] } ?? [])
    }
}
