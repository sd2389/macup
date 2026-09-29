import MacUpCore

/// Skipping one version and keeping a note, written through ``PolicyEditor``
/// exactly as `macup policy skip|unskip|note` are, behind the same approval.
extension AppModel {
    /// The version the last check found on offer for an item, if it found one.
    ///
    /// The app only ever skips a version from here, so what it stores is the
    /// exact string the provider reported and the one the engine will compare.
    func offeredVersion(of item: PackageID) -> AvailableVersion? {
        report?.updates.first { $0.id == item }?.availableVersion
    }

    /// Leaves this version of the item out of plans until a different one is
    /// offered.
    func skipVersion(_ version: AvailableVersion, for item: PackageID) async {
        await editPolicy("skip \(item.rawValue) \(TerminalText.sanitize(version.raw))") {
            try $0.skipVersion(version.raw, for: item)
        }
    }

    /// Stops skipping, so the version follows the item's rule again.
    func stopSkipping(_ item: PackageID) async {
        await editPolicy("stop skipping a version of \(item.rawValue)") { try $0.clearSkippedVersion(for: item) }
    }

    func setNote(_ note: String, for item: PackageID) async {
        await editPolicy("change the note on \(item.rawValue)") { try $0.setNote(note, for: item) }
    }

    func clearNote(for item: PackageID) async {
        await editPolicy("remove the note on \(item.rawValue)") { try $0.clearNote(for: item) }
    }

    /// Updates left alone because the user skipped the version on offer.
    /// Counted apart from ignored and pinned ones: they come back by
    /// themselves with the next version.
    var skippedUpdateCount: Int {
        decisions.values.filter { $0.source == .skippedVersion }.count
    }
}
