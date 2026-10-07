import Foundation
import MacUpCore
import Observation

/// The one Doctor fix being reviewed, and what the last one did.
@MainActor
@Observable
final class DoctorFixModel {
    /// The finding whose fix is being shown for confirmation.
    fileprivate(set) var reviewing: DiagnosticFinding?
    fileprivate(set) var isApplying = false
    /// What the last fix did, kept on screen until the next one.
    fileprivate(set) var result: DoctorFixResult?
    /// Why the last fix could not be asked for at all.
    fileprivate(set) var problem: String?
}

extension AppModel {
    /// Whether this finding offers a change MacUp can make.
    func fix(for finding: DiagnosticFinding) -> DiagnosticFix? { finding.fix }

    /// Shows what the fix would change, and waits. Nothing happens until the
    /// person confirms: the sheet is the review, exactly as an update's is.
    func reviewFix(for finding: DiagnosticFinding) {
        guard finding.fix != nil, !doctorFixes.isApplying else { return }
        doctorFixes.result = nil
        doctorFixes.problem = nil
        doctorFixes.reviewing = finding
    }

    func cancelFix() {
        guard !doctorFixes.isApplying else { return }
        doctorFixes.reviewing = nil
    }

    /// Makes the change the reviewed finding offers, behind the same approval
    /// gate as every other change MacUp makes.
    func applyReviewedFix() async {
        guard let finding = doctorFixes.reviewing, !doctorFixes.isApplying else { return }
        doctorFixes.isApplying = true
        defer {
            doctorFixes.isApplying = false
            doctorFixes.reviewing = nil
        }
        guard let paths = try? resolvedPaths() else {
            doctorFixes.problem = "MacUp could not find its own configuration, so it changed nothing."
            return
        }
        let loaded = loadConfiguration()
        let outcome = await ApprovalGate(
            settings: loaded.configuration.security,
            authorizer: authorizer,
            faceUnlock: faceUnlock(loaded.configuration, paths: paths)
        ).approve("change MacUp's own settings to fix one finding")
        guard outcome.allowsChange else {
            doctorFixes.problem = outcome.explanation ?? "MacUp did not get your approval, so it changed nothing."
            return
        }

        // The scheduler is built here, on the main actor, and handed to the
        // fixer ready-made: a fix that does not need one never uses it.
        let prepared: Scheduler? = scheduledExecutable().map { scheduler(paths: paths, executable: $0) }
        let fixer = DoctorFixer(store: ConfigurationStore(paths: paths)) {
            guard let prepared else {
                throw MacUpError(
                    .configurationInvalid,
                    "MacUp could not work out which `macup` command to schedule, so it changed nothing."
                )
            }
            return prepared
        }
        doctorFixes.result = await fixer.apply(finding)
        // The report the button came from is now out of date, in the part
        // that matters most: whether the finding is still there.
        await runDoctor()
        await refreshScheduleStatus()
    }
}
