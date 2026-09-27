import ArgumentParser
import Foundation
import MacUpCore

struct SecurityFaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "face",
        abstract: "MacUp's own camera face match (a convenience, not a lock).",
        discussion: """
            No Mac has a Face ID sensor, and macOS exposes no face-recognition API: \
            Vision can find a face in a picture, not tell you whose it is. What MacUp \
            does is crop to the face and compare Vision's image feature prints, which \
            measures how alike two pictures look.

            That means a photograph of the enrolled person passes. Treat this as a \
            shortcut, not as security. It can only ever approve a change early: when \
            it does not match, MacUp falls back to the macOS prompt, so a bad match \
            never locks you out.

            Nothing leaves this Mac. What is stored is a list of numbers derived from \
            the pictures, owner-only, in MacUp's state directory. No image is kept.
            """,
        subcommands: [FaceStatusCommand.self, FaceEnrollCommand.self, FaceForgetCommand.self],
        defaultSubcommand: FaceStatusCommand.self
    )
}

struct FaceStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether a face is enrolled, and how well it can match (read-only)."
    )

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1).")
    var json = false

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let settings = ConfigurationStore(paths: paths).load().configuration.security
        let store = FaceEnrollmentStore(paths: paths)

        var enrollment: FaceEnrollment?
        var problem: String?
        do {
            enrollment = try store.load()
        } catch let error as MacUpError {
            problem = error.message
        }
        let document = FaceDocument(
            settings: settings,
            enrollment: enrollment,
            problem: problem,
            cameraPresent: FaceCamera.hasCamera,
            cameraAllowed: FaceCamera.accessGranted,
            path: store.path
        )

        if json {
            context.print(try JSONOutput.encode(document))
        } else {
            let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
            var lines = [style.bold("Face match") + " · " + document.state]
            lines.append("  Camera: " + (document.cameraPresent ? (document.cameraAllowed ? "allowed" : "found, but MacUp has no permission yet") : "none found"))
            if let enrollment {
                lines.append("  Enrolled: \(enrollment.signatures.count) samples on \(enrollment.createdAt.formatted(date: .abbreviated, time: .shortened))")
                lines.append("  Stored: " + style.path(store.path))
                if let spread = enrollment.sampleSpread {
                    lines.append(String(format: "  Your own samples differ by up to %.2f; the threshold is %.2f.", spread, settings.faceMatchThreshold))
                    if Double(spread) >= settings.faceMatchThreshold {
                        lines.append("  " + style.text("Your own face varies more than the threshold allows, so matching will usually fail. Enroll again in even light, or raise security.faceMatchThreshold."))
                    }
                }
            }
            if let problem { lines.append("  " + style.text(problem)) }
            lines.append("")
            lines.append("A photograph of you passes this check. It is a shortcut, not a lock:")
            lines.append("when it does not match, MacUp still asks macOS, so it cannot lock you out.")
            context.print(lines.joined(separator: "\n"))
        }
    }
}

struct FaceEnrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enroll",
        abstract: "Take a few pictures and remember what they look like.",
        discussion: """
            MacUp opens the camera for a moment, takes a handful of pictures, keeps \
            numbers derived from them, and closes the camera. The recording light is \
            on the whole time. No image is stored.
            """
    )

    @Option(help: "How many pictures to take.")
    var samples: Int = 5

    func validate() throws {
        guard samples >= FaceEnrollment.minimumSamples, samples <= 20 else {
            throw ValidationError("Use between \(FaceEnrollment.minimumSamples) and 20 samples.")
        }
    }

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()
        if loaded.hasErrors {
            context.printError("error: MacUp will not change a configuration it cannot read.")
            throw MacUpExitCode.configurationInvalid.exitCode
        }

        // Enrolling replaces whoever is enrolled now, so it goes through the
        // gate like any other change.
        let approval = await context.approval("enroll a face on this Mac", loaded.configuration, paths: paths)
        guard approval.allowsChange else {
            context.printError("error: \(TerminalText.sanitize(approval.explanation ?? "MacUp did not get your approval."))")
            context.printError("Nothing was changed.")
            throw MacUpExitCode.notApproved.exitCode
        }

        context.printError("Look at the camera. MacUp is taking \(samples) pictures.")
        let service = FaceUnlockService(
            store: FaceEnrollmentStore(paths: paths),
            comparator: FaceComparator(threshold: Float(loaded.configuration.security.faceMatchThreshold))
        )
        let enrollment: FaceEnrollment
        do {
            enrollment = try await service.enroll(samples: samples)
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            if let suggestion = error.recoverySuggestion {
                context.printError(TerminalText.sanitize(suggestion))
            }
            throw MacUpExitCode.failure.exitCode
        }

        var configuration = loaded.configuration
        configuration.security.faceUnlock = true
        do {
            try store.save(configuration)
        } catch {
            context.printError("error: the enrollment was saved but the setting was not; turn it on with `macup security face enroll` again.")
            throw MacUpExitCode.failure.exitCode
        }

        var lines = ["Enrolled \(enrollment.signatures.count) samples."]
        if let spread = enrollment.sampleSpread {
            lines.append(String(
                format: "Your own samples differ by up to %.2f; the threshold is %.2f.",
                spread,
                configuration.security.faceMatchThreshold
            ))
            if Double(spread) >= configuration.security.faceMatchThreshold {
                lines.append("That is wider than the threshold, so this will usually fail to recognise you. Enroll again in even light, or raise security.faceMatchThreshold.")
            }
        }
        if !configuration.security.requireApproval {
            lines.append("Approval is not required yet, so MacUp will not ask for anything. Turn it on with `macup security require on`.")
        }
        lines.append("Remember what this is: a photograph of you passes it. MacUp still asks macOS whenever the face does not match.")
        context.print(lines.joined(separator: "\n"))
    }
}

struct FaceForgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Delete the enrolled face and turn the camera check off."
    )

    func run() async throws {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let store = ConfigurationStore(paths: paths)
        let loaded = store.load()

        let removed: Bool
        do {
            removed = try FaceEnrollmentStore(paths: paths).remove()
        } catch let error as MacUpError {
            context.printError("error: \(TerminalText.sanitize(error.message))")
            throw MacUpExitCode.failure.exitCode
        }

        if !loaded.hasErrors && loaded.configuration.security.faceUnlock {
            var configuration = loaded.configuration
            configuration.security.faceUnlock = false
            try? store.save(configuration)
        }
        context.print(removed ? "The enrolled face was deleted." : "No face was enrolled. Nothing to delete.")
    }
}

/// The machine-readable form of `macup security face status`.
struct FaceDocument: Encodable {
    let schemaVersion = 1
    let kind = "securityFace"
    let enabled: Bool
    let enrolled: Bool
    let sampleCount: Int?
    let enrolledAt: Date?
    let sampleSpread: Double?
    let threshold: Double
    let cameraPresent: Bool
    let cameraAllowed: Bool
    let storedAt: String
    let problem: String?

    init(
        settings: MacUpConfiguration.SecuritySettings,
        enrollment: FaceEnrollment?,
        problem: String?,
        cameraPresent: Bool,
        cameraAllowed: Bool,
        path: String
    ) {
        enabled = settings.faceUnlock
        enrolled = enrollment != nil
        sampleCount = enrollment?.signatures.count
        enrolledAt = enrollment?.createdAt
        sampleSpread = enrollment?.sampleSpread.map(Double.init)
        threshold = settings.faceMatchThreshold
        self.cameraPresent = cameraPresent
        self.cameraAllowed = cameraAllowed
        storedAt = path
        self.problem = problem
    }

    var state: String {
        if !enrolled { return "no face enrolled" }
        return enabled ? "on" : "enrolled, but turned off"
    }
}
