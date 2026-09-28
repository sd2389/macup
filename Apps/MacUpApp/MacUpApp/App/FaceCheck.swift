#if DEBUG
import AppKit
import MacUpCore

/// Debug-only: `MacUp --face-check` opens the camera, takes a few pictures,
/// reports what arrived, and quits. It enrolls nothing and writes nothing.
///
/// It exists because the camera only streams to an application, so the
/// command-line tool cannot test this path, and clicking a button is not a
/// way to diagnose a fault repeatedly.
enum FaceCheck {
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("--face-check")
    }

    @MainActor
    static func run() async {
        // Launched through LaunchServices there is no terminal to write to,
        // and that is the launch path worth testing, so the report can go to
        // a file instead.
        let arguments = ProcessInfo.processInfo.arguments
        let output = arguments.firstIndex(of: "--face-check-out")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        var report = ""
        func say(_ line: String) {
            report += line + "\n"
            FileHandle.standardError.write(Data((line + "\n").utf8))
            if let output { try? report.write(toFile: output, atomically: true, encoding: .utf8) }
        }

        // The same finding the Features screen shows, in the same words, so a
        // diagnostic run and the app can never tell different stories.
        for line in CameraReadiness.current().diagnosticLines { say(line) }
        say("can stream: \(FaceCamera.canStreamCamera)")
        say("bundle id: \(Bundle.main.bundleIdentifier ?? "none")")

        let camera = FaceCamera()
        do {
            try await camera.begin()
            say("session: open")
            let frames = try await camera.capture(count: 3, spacing: .milliseconds(250))
            say("pictures: \(frames.count)")
            for (index, frame) in frames.enumerated() {
                say("  picture \(index + 1): \(frame.width)x\(frame.height)")
            }
            let vision = FaceVision()
            let signatures = frames.compactMap { try? vision.signature(from: $0) }.compactMap { $0 }
            say("faces found: \(signatures.count) of \(frames.count)")
            if let first = signatures.first {
                say("signature length: \(first.values.count)")
            }
            if signatures.count > 1 {
                let enrollment = FaceEnrollment(signatures: signatures)
                say("sample spread: \(enrollment.sampleSpread.map { String(format: "%.3f", $0) } ?? "n/a")")
            }
        } catch let error as MacUpError {
            say("FAILED: \(error.message)")
            if let suggestion = error.recoverySuggestion { say("         \(suggestion)") }
            // macOS granting access and then never making the connection live
            // is the signature, not a camera someone else is holding. Said
            // again here because the error above cannot tell the two apart,
            // and its advice does not apply to this one.
            if !BundleSignature.current.isAttributable {
                say("note: this build is signed ad-hoc, so macOS was never going to make")
                say("      that connection live, whatever it says about access. A signed")
                say("      build of MacUp is what changes it.")
            }
        } catch {
            say("FAILED: \(error)")
        }
        camera.end()
        say("done")
        NSApp.terminate(nil)
    }
}
#endif
