/// The exact executable and argument array for one external command.
///
/// This is what MacUp actually passes to the operating system. The
/// ``displayString`` is a separate, shell-quoted rendering for people to read;
/// it is never executed and never parsed back into a command.
public struct CommandInvocation: Sendable, Hashable, Codable {
    /// Absolute path of the executable.
    public var executable: String
    /// Arguments passed verbatim, one array element per argument.
    public var arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// A POSIX-shell-quoted rendering, for display only.
    ///
    /// Arguments containing control characters use ANSI-C quoting
    /// (`$'…'`) so newlines or escape sequences are visible rather than acted on.
    public var displayString: String {
        ([executable] + arguments).map(Self.quoted).joined(separator: " ")
    }

    static func quoted(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        if argument.unicodeScalars.allSatisfy(isPlainCharacter) { return argument }
        if argument.unicodeScalars.contains(where: TerminalText.isUnsafe) {
            return ansiCQuoted(argument)
        }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    private static func isPlainCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9":
            return true
        case "@", "%", "+", "=", ":", ",", ".", "/", "_", "-":
            return true
        default:
            return false
        }
    }

    private static func ansiCQuoted(_ argument: String) -> String {
        var result = "$'"
        for scalar in argument.unicodeScalars {
            switch scalar {
            case "\\": result += #"\\"#
            case "'": result += #"\'"#
            case "\n": result += #"\n"#
            case "\r": result += #"\r"#
            case "\t": result += #"\t"#
            default:
                if TerminalText.isUnsafe(scalar) {
                    if scalar.value <= 0xFF {
                        result += "\\x" + hex(scalar.value, width: 2)
                    } else {
                        result += "\\u" + hex(scalar.value, width: 4)
                    }
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "'"
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
