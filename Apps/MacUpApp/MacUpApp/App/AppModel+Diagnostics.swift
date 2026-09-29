import Foundation
import MacUpCore
import Observation

/// The Export Diagnostics sheet: what MacUp gathered, the exact bytes it
/// would save, and what happened when it tried (CLAUDE.md §13, §16).
///
/// The preview and the saved file are one `Data`, rendered from one look at
/// the Mac. Ticking "Include package names" renders that same look again
/// rather than checking the Mac a second time, so the choice can change the
/// names and nothing else.
@MainActor
@Observable
final class DiagnosticsExport {
    /// What MacUp found, before anything is taken out. `nil` while gathering.
    private(set) var snapshot: DiagnosticsSnapshot?
    private(set) var includesPackageNames = false
    /// The exact bytes Save writes, which are also what the preview shows.
    private(set) var content: Data?
    /// Why there is nothing to save, or why the last save did not happen.
    private(set) var problem: String?
    /// Where the file went, once the content on screen has been saved.
    private(set) var savedPath: String?
    /// Whose home folder is written as `~`, in the file and in messages.
    let homeDirectory: String
    private var gathering: Task<Void, Never>?

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    var isGathering: Bool { snapshot == nil }

    /// The file's text, exactly.
    var preview: String {
        content.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var packageNames: DiagnosticsDocument.PackageNames {
        includesPackageNames ? .included : .placeholders
    }

    /// What is in the file and what is not, in the words the CLI uses too.
    var included: [String] { DiagnosticsDocument.included(packageNames: packageNames) }
    var leftOut: [String] { DiagnosticsDocument.leftOut(packageNames: packageNames) }

    /// What the save panel suggests: named for the moment MacUp gathered it.
    var suggestedFileName: String {
        DiagnosticsFile.defaultName(for: snapshot?.createdAt ?? Date())
    }

    /// Starts gathering. ``cancel()`` stops it.
    func start(_ gather: @escaping @MainActor () async -> DiagnosticsSnapshot?) {
        gathering = Task { [weak self] in
            guard let snapshot = await gather(), !Task.isCancelled else { return }
            self?.show(snapshot)
        }
    }

    /// Stops gathering. Nothing has been written, so nothing needs undoing,
    /// and what was gathered by then is never shown.
    func cancel() {
        gathering?.cancel()
    }

    /// Returns once gathering has finished, however it finished. Lets a test
    /// or a snapshot run wait for the preview instead of guessing how long a
    /// check takes.
    func waitUntilGathered() async {
        await gathering?.value
    }

    func show(_ snapshot: DiagnosticsSnapshot) {
        self.snapshot = snapshot
        render()
    }

    func setIncludesPackageNames(_ include: Bool) {
        guard include != includesPackageNames else { return }
        includesPackageNames = include
        // A file saved before the choice changed holds the other content, so
        // "saved" would no longer describe what is on screen.
        savedPath = nil
        render()
    }

    /// Writes exactly ``content`` to `url`: a new file, readable only by its
    /// owner, never a replacement and never through a symbolic link.
    @discardableResult
    func save(to url: URL) -> Bool {
        guard let content else { return false }
        problem = nil
        do {
            try DiagnosticsFile.write(content, toPath: url.path)
            savedPath = url.path
            return true
        } catch let error as DiagnosticsFileError {
            problem = error.message(homeDirectory: homeDirectory)
        } catch {
            problem = "The file could not be written, so nothing was saved."
        }
        return false
    }

    private func render() {
        guard let snapshot else { return }
        do {
            content = try DiagnosticsDocument(snapshot, includePackageNames: includesPackageNames).encoded()
            problem = nil
        } catch {
            content = nil
            problem = "MacUp could not put the diagnostics into a file, so there is nothing to save."
        }
    }
}

extension AppModel {
    /// Opens Export Diagnostics and starts gathering what goes in it: one
    /// read-only check with Doctor over it, the configuration, and recent
    /// history. Nothing is written until the user saves, and nothing is sent
    /// anywhere at all.
    func beginDiagnosticsExport() {
        guard diagnosticsExport == nil else { return }
        let export = DiagnosticsExport(homeDirectory: environment.homeDirectory)
        diagnosticsExport = export
        export.start { [weak self] in
            await self?.gatherDiagnostics()
        }
    }

    /// Closes the sheet, stopping any gathering still under way.
    func endDiagnosticsExport() {
        diagnosticsExport?.cancel()
        diagnosticsExport = nil
    }

    /// One look at this Mac for an export, through the same collector as
    /// `macup diagnostics`, and seeing the same environment the app's own
    /// checks do.
    func gatherDiagnostics() async -> DiagnosticsSnapshot {
        let processEnvironment = await loadEnvironment()
        let loaded = loadConfiguration()
        // When the paths cannot be resolved, loadConfiguration has already
        // said so as an issue, and that issue is in the file.
        let paths = (try? resolvedPaths()) ?? MacUpPaths.standard(homeDirectory: environment.homeDirectory)
        return await DiagnosticsCollector(doctorEngine: environment.doctorEngine).collect(
            configuration: loaded,
            environment: checkEnvironment(processEnvironment),
            paths: paths,
            schedule: scheduleStatus
        )
    }
}
