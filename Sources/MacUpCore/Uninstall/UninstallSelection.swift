import Foundation

/// What to remove from a plan, built the same way by `macup uninstall` and
/// the app's review sheet.
///
/// It always starts from the plan's own defaults, so data and anything matched
/// only by name stay unticked until someone asks for them; it can only add
/// paths the plan lists, and it never reaches what MacUp cannot remove.
public struct UninstallSelection: Sendable, Hashable {
    public private(set) var paths: Set<String>

    public init(_ plan: UninstallPlan) {
        paths = plan.defaultSelection
    }

    /// Adds every data folder the plan offers (``LeftoverCategory/isData``).
    public mutating func includeData(from plan: UninstallPlan) {
        paths.formUnion(plan.removals.filter { $0.category.isData }.map(\.path))
    }

    /// Everything the plan can remove: the no-residue choice. What MacUp
    /// cannot remove stays in ``UninstallPlan/cannotRemove``, with its steps.
    public mutating func includeEverything(from plan: UninstallPlan) {
        paths.formUnion(plan.everything)
    }

    /// Adds the paths someone named. A path the plan does not list is refused
    /// rather than added, because MacUp removes only what it planned.
    /// Returns the paths it could not match.
    public mutating func include(_ requested: [String], from plan: UninstallPlan, homeDirectory: String) -> [String] {
        let listed = Dictionary(plan.removals.map { (Self.standardized($0.path, home: homeDirectory), $0.path) },
                                uniquingKeysWith: { first, _ in first })
        var unmatched: [String] = []
        for path in requested {
            if let planned = listed[Self.standardized(path, home: homeDirectory)] {
                paths.insert(planned)
            } else {
                unmatched.append(path)
            }
        }
        return unmatched
    }

    /// Ticks or unticks one path. A required path (the app itself) cannot be
    /// unticked, and a path the plan does not list is ignored.
    public mutating func set(_ included: Bool, _ path: String, in plan: UninstallPlan) {
        guard let removal = plan.removals.first(where: { $0.path == path }) else { return }
        if included {
            paths.insert(path)
        } else if !removal.isRequired {
            paths.remove(path)
        }
    }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    static func standardized(_ path: String, home: String) -> String {
        let expanded = path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst() : path
        return (expanded as NSString).standardizingPath
    }
}

/// Sizes the way Finder shows them.
public enum UninstallSizeText {
    public static func text(_ bytes: Int64?, partial: Bool = false) -> String {
        guard let bytes else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 bytes", not "Zero KB", for a link or an empty file.
        formatter.allowsNonnumericFormatting = false
        let formatted = formatter.string(fromByteCount: bytes)
        return partial ? "at least " + formatted : formatted
    }
}
