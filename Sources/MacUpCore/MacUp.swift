/// Facts about MacUp itself.
public enum MacUp {
    /// The MacUp version, and the single place it is written.
    ///
    /// This is the version of the code, not of a release: it names what the
    /// binary contains, and 0.4.0 is where Phases 2 to 4 left it. Only
    /// v0.1.0 has been tagged, so `CHANGELOG.md` still marks 0.2.0 to 0.4.0
    /// unreleased. The app bundle takes its version from here at build time
    /// rather than keeping a second copy that could drift.
    public static let version = "0.4.0"

    /// Reverse-DNS prefix used for OSLog subsystems.
    /// Placeholder until a release bundle identifier is chosen.
    public static let identifier = "dev.macup"
}
