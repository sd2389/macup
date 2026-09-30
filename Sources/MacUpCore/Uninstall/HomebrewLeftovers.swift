import Foundation

/// What a Homebrew formula or cask leaves after `brew uninstall`, found by
/// Homebrew's own naming and nothing looser.
///
/// - A formula's **data and settings** (not ticked): `<prefix>/var/<name>` and
///   `<prefix>/etc/<name>`, such as `var/mysql` or `var/postgresql@16`. Only
///   those exact names; `etc/my.cnf` is not guessed at.
/// - Its **download caches** (ticked), in Homebrew's cache folder:
///   `<name>--<version>` and `<name>_bottle_manifest--<version>`, the
///   downloads they link to, and `downloads/<sha256>--<name>--…` bottles.
///   `--` cannot occur inside a formula name, so `git--` never matches
///   `git-gui--`. A cask's are `Cask/<token>--<version>` and what they link to.
struct HomebrewLeftoverScanner: Sendable {
    var prefix: String?
    var cacheDirectory: String

    /// Homebrew's cache: `HOMEBREW_CACHE` when it is an absolute path,
    /// otherwise `~/Library/Caches/Homebrew`.
    static func cacheDirectory(environment: [String: String], homeDirectory: String) -> String {
        if let value = environment["HOMEBREW_CACHE"], FileTree.isPlainAbsolute(value) { return value }
        return homeDirectory + "/Library/Caches/Homebrew"
    }

    func formula(_ fullName: String) -> [Leftover] {
        let name = fullName.split(separator: "/").last.map(String.init) ?? fullName
        var found: [Leftover] = []
        if let prefix {
            for folder in ["var", "etc"] {
                let path = prefix + "/" + folder + "/" + name
                guard FileTree.exists(path) else { continue }
                found.append(Leftover(
                    path: path,
                    category: .formulaData,
                    selectedByDefault: false,
                    reason: "Homebrew's \(folder) folder for \(name), which `brew uninstall` leaves in place.",
                    warning: "What \(name) keeps here, such as its databases and settings."
                ))
            }
        }
        found += caches(topLevel: cacheDirectory, prefixes: [name + "--", name + "_bottle_manifest--"], owner: name)
        let downloads = cacheDirectory + "/downloads"
        for entry in FileTree.names(in: downloads) ?? [] {
            guard let rest = Self.afterChecksum(entry) else { continue }
            let bottle = rest.hasPrefix(name + "--")
            let manifest = rest.hasPrefix(name + "-") && rest.hasSuffix(".bottle_manifest.json")
                && rest.dropFirst(name.count + 1).first?.isNumber == true
            guard bottle || manifest else { continue }
            let path = downloads + "/" + entry
            guard !found.contains(where: { $0.path == path }) else { continue }
            found.append(cache(path, owner: name))
        }
        return found
    }

    func cask(_ token: String) -> [Leftover] {
        caches(topLevel: cacheDirectory + "/Cask", prefixes: [token + "--"], owner: token)
    }

    /// The entries of `directory` that start with one of `prefixes`, and, for
    /// each that is a link, the download inside the cache it points at.
    private func caches(topLevel directory: String, prefixes: [String], owner: String) -> [Leftover] {
        var found: [Leftover] = []
        let downloads = FileTree.canonicalPath(cacheDirectory + "/downloads")
        for entry in FileTree.names(in: directory) ?? [] where prefixes.contains(where: entry.hasPrefix) {
            let path = directory + "/" + entry
            found.append(cache(path, owner: owner))
            if FileTree.status(path)?.kind == .symlink, let downloads, let target = FileTree.canonicalPath(path),
               FileTree.isInside(target, downloads), (target as NSString).deletingLastPathComponent == downloads {
                let inCache = cacheDirectory + "/downloads/" + (target as NSString).lastPathComponent
                if !found.contains(where: { $0.path == inCache }) { found.append(cache(inCache, owner: owner)) }
            }
        }
        return found
    }

    private func cache(_ path: String, owner: String) -> Leftover {
        Leftover(
            path: path,
            category: .downloadCache,
            selectedByDefault: true,
            reason: "Homebrew's download of \(owner), kept so it can reinstall without the network."
        )
    }

    /// The part of a `downloads` entry after its 64-character checksum and
    /// `--`, or `nil` when it is not named that way.
    static func afterChecksum(_ entry: String) -> Substring? {
        guard entry.count > 66 else { return nil }
        let checksum = entry.prefix(64)
        guard checksum.allSatisfy(\.isHexDigit), entry.dropFirst(64).hasPrefix("--") else { return nil }
        return entry.dropFirst(66)
    }
}
