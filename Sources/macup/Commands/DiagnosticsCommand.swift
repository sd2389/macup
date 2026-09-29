import ArgumentParser
import Foundation
import MacUpCore

struct DiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Make a redacted file to attach to a bug report.",
        discussion: """
            `macup diagnostics preview` prints exactly what `macup diagnostics export` \
            would write, and writes nothing. `export` writes it to a new file, readable \
            only by you.

            To gather it MacUp runs a read-only check and Doctor, and reads its \
            configuration and the last 50 history entries. Secrets are redacted, your \
            home folder is written as ~, and no environment variable is copied in. \
            Package names are replaced with placeholders such as brew:package-1 unless \
            you pass --include-packages. The file's "leftOut" list says what else is \
            deliberately missing.

            Nothing is sent anywhere. The file stays on this Mac until you attach it to \
            something yourself.
            """,
        subcommands: [DiagnosticsPreviewCommand.self, DiagnosticsExportCommand.self],
        defaultSubcommand: DiagnosticsPreviewCommand.self
    )
}

// MARK: - preview

struct DiagnosticsPreviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Print exactly what `macup diagnostics export` would write (read-only).",
        discussion: """
            The document goes to standard output byte for byte as `export` would write \
            it, and a short note about what is in it goes to standard error. Nothing is \
            written.

            Exit status: 0 printed; 3 a MACUP_*_DIR override is not an absolute path; \
            130 cancelled. What the check and Doctor found does not change the exit \
            status: problems are what the file is for.
            """
    )

    @Flag(name: .customLong("include-packages"), help: "Keep package names instead of replacing them with placeholders.")
    var includePackages = false

    func run() async throws {
        let context = CLIContext.current
        let data = try await DiagnosticsGathering.gather(includePackageNames: includePackages)
        context.standardOutput.write(String(decoding: data, as: UTF8.self))
        context.printError("This is exactly what `macup diagnostics export` would write. Nothing has been written or sent.")
        context.printError(DiagnosticsGathering.packageNamesNote(includePackages))
        context.printError("The file's \"leftOut\" list says what else is deliberately not in it.")
    }
}

// MARK: - export

struct DiagnosticsExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write the diagnostics to a new file for a bug report.",
        discussion: """
            By default the file goes in the current directory, named for the moment it \
            was made, for example macup-diagnostics-2026-09-29-111500.json. The current \
            directory is where you are and what you can see; a default such as the \
            Desktop could be synced to iCloud Drive without your noticing. --output \
            names the file, or a folder to put it in.

            MacUp never replaces a file and never writes through a symbolic link: if \
            anything is already at that path it stops, writes nothing, and says so. The \
            file is created readable and writable only by you.

            Exit status: 0 written; 73 the file could not be created (something is \
            already there, it is a symbolic link, or the folder is missing or not \
            writable); 3 a MACUP_*_DIR override is not an absolute path; 130 \
            cancelled. What the check and Doctor found does not change the exit status.
            """
    )

    @Option(name: .shortAndLong, help: "The file to write, or a folder to write it in. Default: the current directory.")
    var output: String?

    @Flag(name: .customLong("include-packages"), help: "Keep package names instead of replacing them with placeholders.")
    var includePackages = false

    @Flag(name: .long, help: "Print machine-readable JSON (schema version 1) describing the file written.")
    var json = false

    func validate() throws {
        if output?.isEmpty == true { throw ValidationError("--output needs a path.") }
    }

    func run() async throws {
        let context = CLIContext.current
        let destination = Self.destination(output, context: context, date: Date())

        // Said now rather than after a check that can take a while.
        if let problem = DiagnosticsFile.problem(writingTo: destination) {
            try Self.refuse(problem, context: context)
        }
        let data = try await DiagnosticsGathering.gather(includePackageNames: includePackages)
        do {
            try DiagnosticsFile.write(data, toPath: destination)
        } catch let error as DiagnosticsFileError {
            try Self.refuse(error, context: context)
        }

        if json {
            context.print(try JSONOutput.encode(DiagnosticsExportDocument(
                path: destination,
                bytes: data.count,
                packageNames: includePackages ? .included : .placeholders
            )))
            return
        }
        let style = TextStyle(enabled: context.allowsStyling, homeDirectory: context.homeDirectory)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        context.print("Saved diagnostics to " + style.path(destination) + " (\(size)). Only you can read it.")
        context.print(DiagnosticsGathering.packageNamesNote(includePackages))
        context.print(style.dim(
            "Nothing has been sent anywhere. Read the file before you attach it; `macup diagnostics preview` prints the same content."
        ))
    }

    /// The file to create. `--output` naming a folder, or a link to one, means
    /// "in there, with the usual name"; anything else names the file itself,
    /// and whether something is already there is the writer's to refuse.
    static func destination(_ output: String?, context: CLIContext, date: Date) -> String {
        let name = DiagnosticsFile.defaultName(for: date)
        guard let output else { return (context.currentDirectory as NSString).appendingPathComponent(name) }
        var path = output
        // The shell expands a bare ~, but not one inside quotes.
        if path == "~" || path.hasPrefix("~/") { path = context.homeDirectory + path.dropFirst() }
        if !path.hasPrefix("/") { path = (context.currentDirectory as NSString).appendingPathComponent(path) }
        var isDirectory: ObjCBool = false
        if output.hasSuffix("/")
            || FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue {
            return (path as NSString).appendingPathComponent(name)
        }
        return path
    }

    private static func refuse(_ error: DiagnosticsFileError, context: CLIContext) throws -> Never {
        context.printError("error: " + error.message(homeDirectory: context.homeDirectory))
        switch error.reason {
        case .alreadyExists, .symbolicLink:
            context.printError("Choose another name with --output, or move what is there first.")
        case .noSuchFolder:
            context.printError("Create the folder first, or choose another with --output.")
        case .notPermitted:
            context.printError("Choose a folder you can write to with --output.")
        case .invalidName:
            context.printError("Name a file, for example --output ~/Desktop/macup-diagnostics.json.")
        case .failed:
            break
        }
        throw MacUpExitCode.cannotCreateOutput.exitCode
    }
}

// MARK: - Gathering

/// The one path both subcommands take, so `preview` and `export` produce the
/// same document from the same kind of look at the Mac.
enum DiagnosticsGathering {
    /// Runs a read-only check and Doctor, reads the configuration and recent
    /// history, and renders the file. Throws the exit code when the command
    /// should stop instead.
    static func gather(includePackageNames: Bool) async throws -> Data {
        let context = CLIContext.current
        let paths = try context.resolvePaths()
        let loaded = ConfigurationStore(paths: paths).load()
        // What is scheduled is part of what Doctor reports on.
        let schedule = await context.scheduler(paths: paths).status(loaded.configuration.schedule)
        let collector = DiagnosticsCollector(doctorEngine: context.doctorEngine)
        let environment = context.checkEnvironment
        let snapshot = await Interruption.run(handlingInterrupts: context.handlesInterrupts) {
            await collector.collect(configuration: loaded, environment: environment, paths: paths, schedule: schedule)
        }
        // A cancelled look at the Mac is a partial one, and a partial file
        // attached to a bug report would mislead whoever reads it.
        if snapshot.cancelled {
            context.printError("Cancelled before MacUp had gathered everything. Nothing was written.")
            throw MacUpExitCode.cancelled.exitCode
        }
        do {
            return try DiagnosticsDocument(snapshot, includePackageNames: includePackageNames).encoded()
        } catch {
            context.printError("error: MacUp could not put the diagnostics into a file. Nothing was written.")
            throw MacUpExitCode.failure.exitCode
        }
    }

    static func packageNamesNote(_ included: Bool) -> String {
        included
            ? "Package names are included, because you passed --include-packages."
            : "Package names are replaced with placeholders such as brew:package-1; --include-packages keeps them."
    }
}

/// The machine-readable form of `macup diagnostics export`: where the file
/// went, not what is in it.
struct DiagnosticsExportDocument: Encodable {
    let schemaVersion = 1
    let kind = "diagnosticsExport"
    let macupVersion = MacUp.version
    /// The file written, as an absolute path.
    let path: String
    let bytes: Int
    let packageNames: DiagnosticsDocument.PackageNames
}
