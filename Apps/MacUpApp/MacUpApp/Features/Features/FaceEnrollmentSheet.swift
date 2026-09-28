import AVFoundation
import MacUpCore
import SwiftUI

/// The camera's own view, so nobody is asked to look at a lens with no idea
/// what it can see.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.backgroundColor = NSColor.black.cgColor
        // A layer-hosting view takes its layer before wantsLayer is set.
        // The other order throws the layer away and shows nothing.
        view.layer = preview
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let preview = nsView.layer as? AVCaptureVideoPreviewLayer else { return }
        if preview.session !== session { preview.session = session }
        preview.frame = nsView.bounds
    }
}

/// Shown while MacUp is enrolling a face. It exists to make the camera being
/// on visible and obvious, and to say what is happening at each step.
struct FaceEnrollmentSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Enrolling your face").font(.headline)
                Text(model.faceStage ?? "Working")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: model.faceStage)
            }

            ZStack {
                if let session = model.faceCaptureSession {
                    CameraPreview(session: session)
                        .frame(width: 320, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .frame(width: 320, height: 240)
                        .overlay(ProgressView())
                }

                // A still outline. It marks the frame without moving: a
                // pulsing border next to a live camera feed is noise, and it
                // competes with the thing the reader is meant to look at.
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 2)
                    .frame(width: 320, height: 240)
                    .opacity(0.5)
            }

            if let camera = model.cameraReadiness.cameraName {
                Text("Using \(camera)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("MacUp keeps numbers taken from these pictures, not the pictures. Nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            // A modal with no way out is a trap, and this one waits on
            // hardware that can refuse to answer.
            Button("Cancel", role: .cancel) { model.cancelFaceEnrollment() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 380)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Enrolling your face. \(model.faceStage ?? "Working").")
    }
}
