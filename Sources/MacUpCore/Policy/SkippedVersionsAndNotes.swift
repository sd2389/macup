/// What a skipped version and a note may hold, in one place.
///
/// The configuration validator, ``PolicyEditor``, the CLI, and the app all ask
/// these same questions, so a value one of them accepts is never one another
/// refuses. Both values are the user's own text. MacUp stores them as written
/// and never reads meaning into them: a note cannot change what MacUp does,
/// and a skipped version only ever keeps an update out of a plan.
extension MacUpConfiguration.ItemSettings {
    /// The longest note MacUp keeps, counted in characters as a person counts
    /// them.
    public static let maximumNoteLength = 200

    /// Longer than any version a provider reports. A bound, not a format:
    /// MacUp does not assume version strings are SemVer (CLAUDE.md §10).
    public static let maximumSkipVersionLength = 128

    /// Whether `offered` is the version the user skipped.
    ///
    /// Compared exactly, as text. MacUp will not decide that `26.7.0` and
    /// `26.7.0_2` are the same version, so a skip applies to the one version
    /// the provider offered when it was set and to nothing else.
    public func skips(_ offered: AvailableVersion) -> Bool {
        skipVersion == offered.raw
    }

    /// True when the entry says nothing no entry would: it inherits, skips no
    /// version, and has no note. The editor removes such an entry rather than
    /// keep a second way of saying "no rule".
    public var isEmpty: Bool {
        policy == .inherit && skipVersion == nil && note == nil
    }

    /// Why `version` cannot be stored as a skipped version, or `nil` when it
    /// can.
    public static func problem(withSkipVersion version: String) -> String? {
        if version.allSatisfy(\.isWhitespace) {
            return "The version to skip is empty."
        }
        if version.unicodeScalars.contains(where: TerminalText.isUnsafe) {
            return "The version to skip contains control or bidirectional-override characters."
        }
        if version.first?.isWhitespace == true || version.last?.isWhitespace == true {
            return "The version to skip has leading or trailing whitespace, so it could never match a version a provider offers."
        }
        if version.count > maximumSkipVersionLength {
            return "The version to skip is longer than \(maximumSkipVersionLength) characters."
        }
        return nil
    }

    /// Why `note` cannot be stored, or `nil` when it can.
    ///
    /// A note is one line: it is shown beside an item in a terminal table and
    /// in a list row, where a line break or a tab would break the layout and
    /// a control character could do worse.
    public static func problem(withNote note: String) -> String? {
        if note.allSatisfy(\.isWhitespace) {
            return "A note cannot be empty."
        }
        if note.unicodeScalars.contains(where: TerminalText.isUnsafe) || note.contains(where: \.isNewline) {
            return "A note is one line of text, without line breaks, tabs, or other control characters."
        }
        if note.count > maximumNoteLength {
            return "A note can be at most \(maximumNoteLength) characters; this one has \(note.count)."
        }
        return nil
    }
}
