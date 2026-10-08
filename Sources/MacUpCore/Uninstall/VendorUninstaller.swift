import Foundation

/// An uninstaller the app's own maker shipped, found beside what it left
/// behind.
///
/// Some installers put their own remover in `/Library/Application
/// Support/<maker>`: TeamViewer's `TeamViewerUninstaller.app` is the case
/// that prompted this. It is the right tool for such an app, because it knows
/// about the privileged helpers, the launchd jobs and the authorization
/// plugins its installer put in place — and because telling somebody to drag
/// that folder to the Trash deletes the uninstaller before it is ever used.
///
/// MacUp names it and stops there. It does not run another maker's program:
/// what that program removes would not be in MacUp's plan, its history, or
/// its boundary (CLAUDE.md §2).
public struct VendorUninstaller: Sendable, Hashable, Codable {
    /// The app bundle, or the command-line tool inside one.
    public var path: String
    /// The folder MacUp was looking at, which holds it. Left out of the
    /// script MacUp writes, so the uninstaller survives long enough to run.
    public var foundIn: String
    /// Who signed it, checked rather than claimed. `nil` when the signature
    /// does not verify — then MacUp says so instead of vouching for it.
    public var signedBy: String?
    /// What to do with it, in the person's words.
    public var steps: [String]

    public init(path: String, foundIn: String, signedBy: String?, steps: [String]) {
        self.path = path
        self.foundIn = foundIn
        self.signedBy = signedBy
        self.steps = steps
    }

    /// One line for the top of a plan.
    public var summary: String {
        let name = (path as NSString).lastPathComponent
        if let signedBy {
            return "\(name) is the maker's own uninstaller, signed by \(signedBy). Running it removes the parts MacUp will not, including the ones that need an administrator."
        }
        return "\(name) looks like the maker's own uninstaller, but its signature does not verify, so MacUp cannot say who wrote it. Check it before you run it."
    }
}

public enum VendorUninstallerScanner {
    /// How a maker names its remover. Matched case-insensitively against the
    /// bundle's name, so `TeamViewerUninstaller.app` and `Uninstall Foo.app`
    /// are both found.
    static let markers = ["uninstall", "remover"]

    /// Looks one level inside each folder for a bundle whose name says it
    /// uninstalls the app. Reads names and one signature; runs nothing.
    public static func find(
        in folders: [String],
        signatures: any CodeSignatureReading,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> VendorUninstaller? {
        for folder in folders {
            guard fileSystem.isDirectory(atPath: folder) else { continue }
            for name in (FileTree.names(in: folder) ?? []).sorted() {
                let lowercased = name.lowercased()
                guard lowercased.hasSuffix(".app"), markers.contains(where: lowercased.contains) else { continue }
                let path = folder + "/" + name
                guard fileSystem.isDirectory(atPath: path) else { continue }
                return VendorUninstaller(
                    path: path,
                    foundIn: folder,
                    signedBy: signatures.verifiedSigner(ofBundleAt: path),
                    steps: steps(for: path, in: folder)
                )
            }
        }
        return nil
    }

    private static func steps(for path: String, in folder: String) -> [String] {
        [
            "Open it: \(CommandInvocation.quoted(path)). It asks for an administrator's password itself.",
            "When it has finished, remove what is left: run this uninstall again, or remove \(CommandInvocation.quoted(folder)) yourself.",
        ]
    }
}
