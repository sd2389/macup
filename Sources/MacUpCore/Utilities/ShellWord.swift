import Foundation

/// Whether a name can appear, as it is, in a command MacUp suggests.
///
/// MacUp never runs the repair commands it suggests, but a person may paste
/// one into a shell. A name taken from provider output goes into such a
/// suggestion only when it is made of characters a shell gives no meaning
/// to, so pasting it cannot do more than the text says. Anything else gets
/// the advice without the command.
enum ShellWord {
    private static let plain = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@/-"
    )

    static func isPlain(_ word: String) -> Bool {
        !word.isEmpty && !word.hasPrefix("-") && word.unicodeScalars.allSatisfy(plain.contains)
    }
}
