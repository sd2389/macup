import AVFoundation
import MacUpCore
import SwiftUI

/// The camera's own view, so nobody is asked to look at a lens with no idea
/// what it can see.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}

/// Shown while MacUp is enrolling a face. It exists to make the camera being
/// on visible and obvious, and to say what is happening at each step.
struct FaceEnrollmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scanning = false

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
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .frame(width: 320, height: 240)
                        .overlay(ProgressView())
                }

                // A ring that breathes while pictures are being taken. It
                // conveys "the camera is on now", so it is off when reduced
                // motion is on and the wording carries it instead.
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 2)
                    .frame(width: 320, height: 240)
                    .opacity(scanning && !reduceMotion ? 0.9 : 0.25)
                    .scaleEffect(scanning && !reduceMotion ? 1.015 : 1)
            }
            .animation(.easeInOut(duration: 0.35), value: model.faceCaptureSession != nil)

            if let camera = FaceCamera.cameraName {
                Text("Using \(camera)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("MacUp keeps numbers taken from these pictures, not the pictures. Nothing leaves this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
        .frame(minWidth: 380)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                scanning = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Enrolling your face. \(model.faceStage ?? "Working").")
    }
}
