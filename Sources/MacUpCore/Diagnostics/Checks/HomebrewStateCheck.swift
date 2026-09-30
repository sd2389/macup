import Foundation

/// Looks at Homebrew's own records of what is installed, whether or not an
/// update is waiting (CLAUDE.md §9, §13).
///
/// Everything here comes from the inventory the check already read — the
/// install receipts, links, and ready-made builds ``HomebrewProvider``
/// records for each formula — so this check runs nothing. Where something
/// needs repairing, the recommendation is a list of steps for a person, in
/// the only order that is safe. MacUp runs none of them: moving an install
/// to the Trash is a decision about someone's software, and Doctor explains
/// rather than fixes.
public struct HomebrewStateCheck: DiagnosticCheck {
    public let id = "homebrew.state"
    public let title = "Whether Homebrew's installed formulae are in a state Homebrew can use"

    /// Where Homebrew's ready-made builds are made to be used.
    public var standardPrefixes: [String]

    public init(standardPrefixes: [String] = ["/opt/homebrew", "/usr/local"]) {
        self.standardPrefixes = standardPrefixes
    }

    public func run(_ input: DiagnosticInput) async -> [DiagnosticFinding] {
        guard let report = input.report(for: .homebrew), report.availability == .available,
              let items = report.items
        else { return [] }
        let prefix = report.facts.first { $0.key == "prefix" }?.value
        let formulae = items.filter { $0.kind == .formula }

        var findings: [DiagnosticFinding] = []
        for item in formulae {
            if let prefix, let finding = unfinishedInstall(item, prefix: prefix, input: input) {
                findings.append(finding)
            }
            if let finding = notLinked(item, among: formulae, prefix: prefix, input: input) {
                findings.append(finding)
            }
        }
        if let prefix, let finding = sourceBuilds(formulae, prefix: prefix, input: input) {
            findings.append(finding)
        }
        return findings
    }

    // MARK: An install that never finished

    /// A version folder with no `INSTALL_RECEIPT.json`: Homebrew writes the
    /// receipt when an install completes, so the install stopped part-way.
    ///
    /// The order of the repair is the point of this finding. `brew link`
    /// links the newest version folder, whatever state it is in, and points
    /// `opt/<name>` at it. With an unfinished folder still in place, the
    /// newest one is usually the unfinished one, so linking first would
    /// break everything that runs the formula through `opt`, its service
    /// included. The folder goes first; linking afterwards finds the finished
    /// version.
    private func unfinishedInstall(_ item: ManagedItem, prefix: String, input: DiagnosticInput) -> DiagnosticFinding? {
        guard let listed = item.details["incompleteVersions"] else { return nil }
        let unfinished = listed.components(separatedBy: ", ")
        let finished = item.installedVersions.map(\.raw).filter { !unfinished.contains($0) }
        let name = input.display(item.displayName)
        let rack = prefix + "/Cellar/" + Self.rackName(item)
        let opt = input.display(prefix + "/opt/" + Self.rackName(item))
        let folders = unfinished.map { rack + "/" + $0 }
        let one = folders.count == 1

        var detail = "Homebrew writes an install receipt when an install completes. "
            + DiagnosticText.list(folders.map(input.display)) + (one ? " has none, so that install" : " have none, so those installs")
            + " stopped part-way."
        let listings = folders.map { input.environment.fileSystem.contentsOfDirectory(atPath: $0) }
        if listings.allSatisfy({ $0?.isEmpty == true }) {
            detail += one ? " The folder is empty." : " The folders are empty."
        }
        if let target = item.details["optVersion"] {
            detail += unfinished.contains(target)
                ? " \(opt) points at the unfinished folder, so anything that runs \(name) from there, such as its service, will not start."
                : " \(opt) points at \(input.display(target)), whose install finished."
        }

        let plain = ShellWord.isPlain(item.displayName)
        var steps = [
            "In Finder, choose Go > Go to Folder, enter \(input.display(rack)), and move the "
                + DiagnosticText.list(unfinished.map(input.display)) + (one ? " folder" : " folders") + " to the Trash.",
        ]
        var caution: String?
        if finished.isEmpty {
            steps.append("No finished version of \(name) is left, so if you still want it, install it again"
                + (plain ? " with `brew install \(name)`." : " with Homebrew."))
        } else if item.details["kegOnly"] != "true" && item.activeVersion == nil {
            let version = input.display(HomebrewOutdatedParser.newest(finished))
            steps.append("Then run " + (plain ? "`brew link \(name)`" : "`brew link` with its name")
                + ", which links \(version) again and puts \(name)'s commands back on your PATH.")
            caution = "Do these in this order. Run `brew link` first and Homebrew links the newest folder, which is "
                + "the unfinished one, and points \(opt) at it, which breaks anything that runs \(name) from there."
        } else if let target = item.details["optVersion"], unfinished.contains(target) {
            steps.append("Homebrew then needs a finished version to point \(opt) at again"
                + (plain ? "; `brew reinstall \(name)` installs one." : "; reinstalling it with Homebrew installs one."))
        }

        return DiagnosticFinding(
            id: "homebrew.unfinishedInstall",
            severity: .warning,
            provider: .homebrew,
            title: "An install of \(name) did not finish",
            detail: detail,
            recommendation: Self.steps("To repair it yourself", steps, caution: caution)
        )
    }

    // MARK: Installed but not linked

    /// A formula that is not keg-only is meant to be linked into the prefix;
    /// with no version linked, its commands are not on `PATH`, although
    /// anything that runs it through `opt/<name>` still works.
    ///
    /// Not every unlinked formula is a problem. Only one of two versions that
    /// provide the same commands can be linked, and a formula installed only
    /// as another's dependency is used through `opt`, not through `PATH`, so
    /// both of those are notes rather than warnings.
    private func notLinked(
        _ item: ManagedItem,
        among formulae: [ManagedItem],
        prefix: String?,
        input: DiagnosticInput
    ) -> DiagnosticFinding? {
        guard item.activeVersion == nil, item.details["kegOnly"] != "true" else { return nil }
        let unfinished = Set(item.details["incompleteVersions"]?.components(separatedBy: ", ") ?? [])
        let finished = item.installedVersions.map(\.raw).filter { !unfinished.contains($0) }
        // With nothing finished there is nothing to link; the unfinished
        // install says what to do instead.
        guard !finished.isEmpty else { return nil }

        let name = input.display(item.displayName)
        let plain = ShellWord.isPlain(item.displayName)
        let family = RuntimeCatalog.baseName(item.id.name)
        let linkedInstead = formulae.first {
            $0.id != item.id && $0.activeVersion != nil && RuntimeCatalog.baseName($0.id.name) == family
        }

        var detail = "Homebrew has \(name) \(input.display(HomebrewOutdatedParser.newest(finished))) installed, "
            + "but no version of it is linked, so its commands are not on your PATH."
        if let prefix, let target = item.details["optVersion"], !unfinished.contains(target) {
            let opt = input.display(prefix + "/opt/" + Self.rackName(item))
            detail += item.details["definesService"] == "true"
                ? " Anything that runs it through \(opt), such as its service, still gets \(input.display(target))."
                : " Anything that uses it through \(opt) still gets \(input.display(target))."
        }
        if let linkedInstead {
            detail += " \(input.display(linkedInstead.displayName)) is linked instead."
        }

        let severity: DiagnosticFinding.Severity
        let recommendation: String
        if !unfinished.isEmpty {
            severity = .warning
            recommendation = "Do not run `brew link` yet: an install of \(name) did not finish, and `brew link` would "
                + "link that unfinished folder. Doctor lists the steps to repair it, and the last of them links \(name)."
        } else if let linkedInstead {
            let other = input.display(linkedInstead.displayName)
            severity = .info
            recommendation = "Usually on purpose: only one of them can provide the same commands. "
                + (plain && ShellWord.isPlain(linkedInstead.displayName)
                    ? "To use \(name) instead, run `brew unlink \(other)` and then `brew link \(name)`."
                    : "To use \(name) instead, unlink \(other) and link \(name) with Homebrew.")
        } else {
            severity = item.details["installedOnRequest"] == "false" ? .info : .warning
            recommendation = "If you did not unlink it on purpose, "
                + (plain ? "run `brew link \(name)`" : "link it with Homebrew") + " to put its commands back on your PATH."
        }

        return DiagnosticFinding(
            id: "homebrew.notLinked",
            severity: severity,
            provider: .homebrew,
            title: "\(name) is installed but not linked",
            detail: detail,
            recommendation: recommendation
        )
    }

    // MARK: Builds from source

    /// Homebrew's ready-made builds are made for a fixed location, and most
    /// can be used only there. A Homebrew anywhere else compiles those
    /// formulae instead, which is slow and can fail part-way.
    ///
    /// Only formulae Homebrew has ready-made builds for, just not for this
    /// location, are counted: a formula with no ready-made build at all
    /// would be built anywhere, so it says nothing about the location.
    private func sourceBuilds(_ formulae: [ManagedItem], prefix: String, input: DiagnosticInput) -> DiagnosticFinding? {
        let canonical = input.environment.fileSystem.canonicalPath(ofPath: prefix) ?? prefix
        guard !standardPrefixes.contains(prefix), !standardPrefixes.contains(canonical) else { return nil }
        let affected = formulae.filter {
            $0.details["buildsFromSource"] == "true" && !($0.details["bottleCellars"] ?? "").isEmpty
        }
        guard !affected.isEmpty else { return nil }

        // Spelled out step by step: older compilers give up type-checking
        // this as one chained expression.
        var cellars = Set<String>()
        for item in affected {
            for line in (item.details["bottleCellars"] ?? "").split(separator: "\n") where line.hasPrefix("/") {
                cellars.insert(String(line))
            }
        }
        let prefixes: [String] = cellars.map { cellar in
            cellar.hasSuffix("/Cellar") ? String(cellar.dropLast("/Cellar".count)) : cellar
        }
        let madeFor: [String] = prefixes.sorted().map { input.display($0) }
        let names = affected.map { input.display($0.displayName) }.sorted()
        let usual = input.environment.system.architecture == "arm64" ? "/opt/homebrew" : "/usr/local"
        let count = affected.count == 1 ? "1 installed formula" : "\(affected.count) installed formulae"

        return DiagnosticFinding(
            id: "homebrew.buildsFromSource",
            severity: .info,
            provider: .homebrew,
            title: "Homebrew builds from source in this location",
            detail: "This Homebrew is in \(input.display(prefix)). The ready-made builds of \(count) are made for "
                + (madeFor.isEmpty ? "Homebrew's usual location" : DiagnosticText.list(madeFor, limit: 3))
                + " and cannot be used here, so Homebrew compiles each of these from source when it installs or "
                + "upgrades them: \(DiagnosticText.list(names)).",
            recommendation: "Nothing needs fixing: this is how Homebrew works outside its usual location. A build "
                + "from source takes longer, an hour or more for a large package, and should be left to finish; "
                + "MacUp gives one more time and never stops it part-way. Only a Homebrew installed in \(usual) "
                + "can use the ready-made builds."
        )
    }

    // MARK: Helpers

    /// The folder under `Cellar` a formula is installed in: its short name,
    /// even when it comes from another tap.
    private static func rackName(_ item: ManagedItem) -> String {
        item.id.name.split(separator: "/").last.map(String.init) ?? item.id.name
    }

    /// Steps one per line, numbered when there is more than one, so the
    /// order is impossible to miss.
    private static func steps(_ lead: String, _ steps: [String], caution: String?) -> String {
        var lines = steps.count == 1
            ? ["\(lead): \(steps[0].prefix(1).lowercased() + steps[0].dropFirst())"]
            : ["\(lead):"] + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        if let caution { lines.append(caution) }
        return lines.joined(separator: "\n")
    }
}
