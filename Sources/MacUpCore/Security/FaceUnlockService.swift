@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Vision

/// Turns pictures from the camera into face signatures, and compares them.
///
/// What this is, precisely: Vision detects where a face is, MacUp crops to it,
/// and Vision produces an image feature print of the crop. Two feature prints
/// close together mean the two pictures look alike. A photograph of the
/// enrolled person looks alike. This is a convenience, and MacUp says so
/// everywhere it appears (docs/TRUST_AND_SECURITY.md).
public struct FaceVision: Sendable {
    public init() {}

    /// The signature of the largest face in the picture, or `nil` when there
    /// is no face in it.
    public func signature(from image: CGImage) throws -> FaceSignature? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faces])
        } catch {
            throw MacUpError(.verificationFailed, "MacUp could not examine the picture from the camera.")
        }
        guard let face = (faces.results ?? []).max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }
        guard let crop = Self.crop(image, to: face.boundingBox) else { return nil }

        let print = VNGenerateImageFeaturePrintRequest()
        print.imageCropAndScaleOption = .scaleFill
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([print])
        } catch {
            throw MacUpError(.verificationFailed, "MacUp could not summarise the face in the picture.")
        }
        guard let observation = print.results?.first else { return nil }
        return Self.signature(from: observation)
    }

    /// Vision reports a normalized box with its origin at the bottom left.
    /// A margin is added so the crop is the face rather than a tight rectangle
    /// of skin, which makes the feature print less sensitive to framing.
    static func crop(_ image: CGImage, to boundingBox: CGRect, margin: CGFloat = 0.25) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(
            x: boundingBox.origin.x * width,
            y: (1 - boundingBox.origin.y - boundingBox.height) * height,
            width: boundingBox.width * width,
            height: boundingBox.height * height
        )
        rect = rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        guard rect.width > 32, rect.height > 32 else { return nil }
        return image.cropping(to: rect)
    }

    static func signature(from observation: VNFeaturePrintObservation) -> FaceSignature? {
        let data = observation.data
        switch observation.elementType {
        case .float:
            let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return values.isEmpty ? nil : FaceSignature(values: values)
        case .double:
            let values = data.withUnsafeBytes { $0.bindMemory(to: Double.self).map(Float.init) }
            return values.isEmpty ? nil : FaceSignature(values: values)
        default:
            // An element type this build does not know about. Refused rather
            // than reinterpreted as something else.
            return nil
        }
    }
}

extension CGRect {
    var area: CGFloat { width * height }
}

/// Takes a few still pictures from the camera and stops.
///
/// The camera is opened for the moment it takes to capture, then closed. The
/// recording light is on while it is open, which is the honest signal that
/// MacUp is looking.
public actor FaceCamera {
    public enum Failure: Sendable {
        case noCamera
        case accessDenied
        case timedOut
    }

    public init() {}

    /// Asks macOS for camera access if it has not been decided yet.
    public func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    public static var accessGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static var hasCamera: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    /// Captures `count` frames, spaced out so they are not the same instant.
    public func capture(count: Int, spacing: Duration = .milliseconds(350)) async throws -> [CGImage] {
        guard AVCaptureDevice.default(for: .video) != nil else {
            throw MacUpError(.providerUnavailable, "This Mac has no camera MacUp can use.")
        }
        guard await requestAccess() else {
            throw MacUpError(
                .authorizationRequired,
                "MacUp does not have permission to use the camera.",
                recoverySuggestion: "Allow it in System Settings → Privacy & Security → Camera."
            )
        }
        let session = try FaceCameraSession()
        defer { session.stop() }
        session.start()

        var frames: [CGImage] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while frames.count < count {
            if ContinuousClock.now > deadline {
                throw MacUpError(.timeout, "The camera did not produce a usable picture in time.")
            }
            try await Task.sleep(for: spacing)
            if let frame = session.latestFrame() { frames.append(frame) }
        }
        return frames
    }
}

/// The AVFoundation plumbing, kept apart from the policy above.
final class FaceCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.macup.face-camera")
    private let lock = NSLock()
    private var frame: CGImage?
    private let context = CIContext()

    override init() {
        super.init()
    }

    convenience init(device: AVCaptureDevice? = AVCaptureDevice.default(for: .video)) throws {
        self.init()
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw MacUpError(.providerUnavailable, "MacUp could not open the camera.")
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MacUpError(.providerUnavailable, "MacUp could not read pictures from the camera.")
        }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        let session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)
    }

    func latestFrame() -> CGImage? {
        lock.withLock {
            let frame = self.frame
            self.frame = nil
            return frame
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        lock.withLock { frame = cgImage }
    }
}

/// Enrolling and checking a face, on top of the camera and Vision.
///
/// Read this before relying on it: a face here is an image feature print, so a
/// photograph of the enrolled person matches. MacUp therefore treats a face
/// match as a convenience that can approve a change *in addition to* Touch ID,
/// never as the thing that makes a change safe.
public struct FaceUnlockService: Sendable {
    public var store: FaceEnrollmentStore
    public var comparator: FaceComparator
    public var camera: FaceCamera
    public var vision: FaceVision

    public init(
        store: FaceEnrollmentStore,
        comparator: FaceComparator = FaceComparator(),
        camera: FaceCamera = FaceCamera(),
        vision: FaceVision = FaceVision()
    ) {
        self.store = store
        self.comparator = comparator
        self.camera = camera
        self.vision = vision
    }

    public var isEnrolled: Bool { (try? store.load()) ?? nil != nil }

    /// Takes several pictures and saves their signatures.
    ///
    /// Returns the enrollment, whose `sampleSpread` says how much the same
    /// face varied between samples. A spread at or above the threshold means
    /// matching will not work reliably, and the caller is expected to say so.
    @discardableResult
    public func enroll(samples: Int = 5) async throws -> FaceEnrollment {
        let frames = try await camera.capture(count: max(samples, FaceEnrollment.minimumSamples))
        var signatures: [FaceSignature] = []
        for frame in frames {
            if let signature = try vision.signature(from: frame) { signatures.append(signature) }
        }
        guard signatures.count >= FaceEnrollment.minimumSamples else {
            throw MacUpError(
                .verificationFailed,
                "MacUp saw a face in only \(signatures.count) of \(frames.count) pictures.",
                recoverySuggestion: "Face the camera in even light and try again."
            )
        }
        let enrollment = FaceEnrollment(signatures: signatures)
        try store.save(enrollment)
        return enrollment
    }

    /// Takes one picture and compares it with the enrollment. Anything MacUp
    /// could not establish is a refusal.
    public func verify() async -> ApprovalOutcome {
        let enrollment: FaceEnrollment?
        do {
            enrollment = try store.load()
        } catch let error as MacUpError {
            return .unavailable(error.message)
        } catch {
            return .unavailable("The stored face enrollment could not be read.")
        }
        guard let enrollment else {
            return .unavailable("No face is enrolled on this Mac.")
        }

        let frames: [CGImage]
        do {
            frames = try await camera.capture(count: 2, spacing: .milliseconds(250))
        } catch let error as MacUpError {
            return .unavailable(error.message)
        } catch {
            return .unavailable("MacUp could not use the camera.")
        }

        var best: FaceMatch?
        for frame in frames {
            guard let signature = try? vision.signature(from: frame) else { continue }
            guard let match = comparator.match(signature, against: enrollment) else { continue }
            if best == nil || match.distance < best!.distance { best = match }
        }
        guard let best else {
            return .declined("MacUp did not see a face it could compare, so nothing was changed.")
        }
        return best.isMatch
            ? .approved(.none)
            : .declined("That did not look like the enrolled face, so nothing was changed.")
    }
}
