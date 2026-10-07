import Foundation
import MacUpCore

extension AppModel {
    /// How this copy of MacUp was installed, and whether Homebrew has a newer
    /// one — worked out from the check that has already run, so opening
    /// Settings runs nothing.
    ///
    /// `nil` until the first check finishes: MacUp says it does not know yet
    /// rather than claiming to be up to date.
    var selfUpdateStatus: SelfUpdateStatus? {
        guard let report else { return nil }
        return SelfUpdate.status(
            check: report,
            executablePath: environment.bundledExecutablePath,
            appBundlePath: uninstallEnvironment.currentAppBundle,
            fileSystem: environment.fileSystem
        )
    }

    /// The MacUp update to review, when Homebrew has one.
    var selfUpdateItem: PackageID? { selfUpdateStatus?.updates.first?.id }

    /// Opens the ordinary update review for MacUp's own item: the same plan,
    /// commands, confirmation, and approval gate as any other update, because
    /// updating MacUp is not a special case (CLAUDE.md §2).
    func reviewSelfUpdate() async {
        guard let item = selfUpdateItem else { return }
        await reviewUpdates([item])
    }
}
