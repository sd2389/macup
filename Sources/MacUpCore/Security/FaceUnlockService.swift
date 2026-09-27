@preconcurrency import AVFoundation
import VideoToolbox
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

/// Runs the camera for as long as a capture needs it, and no longer.
///
/// The session is held rather than rebuilt per frame so the UI can show a
/// preview of the same session: someone being asked to look at a camera
/// should be able to see what it sees.
public final class FaceCamera: @unchecked Sendable {
    private let lock = NSLock()
    private var session: FaceCameraSession?

    public init() {}

    public static var accessGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static var hasCamera: Bool {
        preferredDevice() != nil
    }

    /// Whether this process can actually stream the camera.
    ///
    /// macOS activates a capture connection only for a signed application
    /// bundle. A bare command-line binary is told the camera is authorized,
    /// the session starts, and then no frame ever arrives. Established by
    /// testing, not assumed: see docs/TRUST_AND_SECURITY.md.
    public static var canStreamCamera: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// The camera MacUp will use, named as macOS names it.
    public static var cameraName: String? {
        preferredDevice()?.localizedName
    }

    /// Which camera to open.
    ///
    /// `AVCaptureDevice.default(for:)` can return an iPhone acting as a
    /// Continuity Camera. macOS offers that device even when the phone is not
    /// nearby or not awake, and the session then starts and sends nothing at
    /// all. So a camera attached to this Mac is preferred, and Continuity is
    /// used only when there is no other.
    public static func preferredDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        let devices = discovery.devices
        return devices.first { !$0.isContinuityCamera }
            ?? devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    /// The running session, for a preview layer. `nil` before ``begin()``.
    public var captureSession: AVCaptureSession? {
        lock.withLock { session?.session }
    }

    public func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Opens the camera and waits until it is actually running. Throws rather
    /// than leaving a caller to time out on a session that never started.
    public func begin() async throws {
        guard Self.canStreamCamera else {
            throw MacUpError(
                .unsupported,
                "macOS streams the camera only to an application, not to a command.",
                recoverySuggestion: "Use the MacUp app: Features, then Face match, then Enroll Face."
            )
        }
        guard Self.preferredDevice() != nil else {
            throw MacUpError(
                .providerUnavailable,
                "This Mac has no camera MacUp can use.",
                recoverySuggestion: "A Mac with no built-in camera needs one connected before a face can be enrolled."
            )
        }
        guard await requestAccess() else {
            throw MacUpError(
                .authorizationRequired,
                "MacUp does not have permission to use the camera.",
                recoverySuggestion: "Allow it in System Settings → Privacy & Security → Camera."
            )
        }
        let session = try FaceCameraSession()
        lock.withLock { self.session = session }
        try await session.start()
    }

    public func end() {
        let session = lock.withLock {
            let current = self.session
            self.session = nil
            return current
        }
        session?.stop()
    }

    /// Captures `count` frames, spaced out so they are not the same instant.
    /// ``begin()`` must have been called.
    public func capture(count: Int, spacing: Duration = .milliseconds(300)) async throws -> [CGImage] {
        guard let session = lock.withLock({ self.session }) else {
            throw MacUpError(.verificationFailed, "The camera was not open.")
        }
        var frames: [CGImage] = []
        // Generous, because the first frame after a cold start can take a
        // moment, and a camera that is going to work usually works at once.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while frames.count < count {
            if ContinuousClock.now > deadline {
                // Say which half failed. "No pictures" covers two very
                // different faults: a camera that sends nothing, and a camera
                // whose pictures MacUp could not read.
                let counts = session.counts()
                let detail: String
                let suggestion: String
                if counts.received == 0 {
                    detail = session.connectionIsActive
                        ? "The camera is open and connected but sent MacUp no pictures."
                        : "The camera is open but macOS never made its video connection active, so no pictures arrived."
                    suggestion = session.connectionIsActive
                        ? "Another app may be holding the camera. Close it and try again."
                        : "Enroll from the MacUp app rather than the command line: macOS only streams the camera to a signed app bundle."
                } else if counts.converted == 0 {
                    detail = "The camera sent \(counts.received) pictures and MacUp could not read any of them."
                    suggestion = "Please report this with the camera model shown above."
                } else {
                    detail = "The camera sent only \(frames.count) of \(count) usable pictures in time."
                    suggestion = "Try again in better light."
                }
                throw MacUpError(.timeout, detail, recoverySuggestion: suggestion)
            }
            try await Task.sleep(for: spacing)
            if let frame = session.latestFrame() { frames.append(frame) }
        }
        return frames
    }
}

/// The AVFoundation plumbing, kept apart from the policy above.
final class FaceCameraSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.macup.face-camera")
    private let lock = NSLock()
    private var frame: CGImage?
    /// Counted separately so a failure can say whether the camera sent
    /// nothing or sent pictures MacUp could not read.
    private var received = 0
    private var converted = 0
    private static let context = CIContext()

    override init() {
        super.init()
    }

    convenience init(device: AVCaptureDevice? = FaceCamera.preferredDevice()) throws {
        self.init()
        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw MacUpError(.providerUnavailable, "MacUp could not open the camera.")
        }
        // Order matters: configure the graph, commit it, and only then set
        // the output's format and delegate. Doing either before the output
        // belongs to a session leaves it attached to nothing.
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MacUpError(.providerUnavailable, "MacUp could not read pictures from the camera.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)

        guard let connection = output.connection(with: .video) else {
            throw MacUpError(
                .providerUnavailable,
                "MacUp opened \(device.localizedName) but macOS gave it no video connection."
            )
        }
        if !connection.isEnabled { connection.isEnabled = true }
        guard connection.isActive || connection.isEnabled else {
            throw MacUpError(
                .providerUnavailable,
                "The video connection to \(device.localizedName) is not active."
            )
        }
    }

    /// Whether macOS considers the video connection live, for diagnostics.
    var connectionIsActive: Bool {
        output.connection(with: .video)?.isActive ?? false
    }

    /// Starts the session and returns once it is running, so a caller never
    /// waits for frames from a session that failed to start.
    func start() async throws {
        let session = session
        await withCheckedContinuation { continuation in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
        guard session.isRunning else {
            throw MacUpError(
                .providerUnavailable,
                "The camera did not start.",
                recoverySuggestion: "Another app may be using it. Close it and try again."
            )
        }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        let session = session
        queue.async { session.stopRunning() }
    }

    func latestFrame() -> CGImage? {
        lock.withLock {
            let frame = self.frame
            self.frame = nil
            return frame
        }
    }

    func counts() -> (received: Int, converted: Int) {
        lock.withLock { (received, converted) }
    }

    /// VideoToolbox converts a pixel buffer without a render pass, which is
    /// both cheaper and less likely to fail on a background queue than going
    /// through Core Image. Core Image remains the fallback.
    static func makeImage(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        if VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image {
            return image
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        lock.withLock { received += 1 }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let cgImage = Self.makeImage(from: buffer) else { return }
        lock.withLock {
            converted += 1
            frame = cgImage
        }
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
    public func enroll(samples: Int = 5, cameraIsOpen: Bool = false) async throws -> FaceEnrollment {
        if !cameraIsOpen {
            try await camera.begin()
        }
        defer { if !cameraIsOpen { camera.end() } }
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
            try await camera.begin()
            defer { camera.end() }
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
