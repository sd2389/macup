import Foundation

/// One command a root shell would run to remove something MacUp will not.
///
/// An argument array, never a string: the words are quoted once, by
/// ``AdminRemovalScript``, when the script is written. A path operand is
/// preceded by `--` where the tool supports it, so a name beginning with a
/// hyphen is a path and not an option (CLAUDE.md §8).
public struct AdminCommand: Sendable, Hashable, Codable {
    /// The executable and its arguments, exactly as a shell would receive
    /// them after quoting.
    public var words: [String]
    /// Whether the script carries on when this command fails. True for
    /// stopping a launchd job that may not be loaded, where "not loaded" is
    /// the outcome asked for.
    public var ignoreFailure: Bool
    /// One line the script prints before running it, so somebody watching
    /// sees what is happening in the order it happens.
    public var describes: String

    public init(_ words: [String], ignoreFailure: Bool = false, describes: String) {
        self.words = words
        self.ignoreFailure = ignoreFailure
        self.describes = describes
    }
}

/// A script that removes what MacUp refuses to remove itself, written for the
/// person to read and then run with `sudo`.
///
/// MacUp never becomes an administrator: it does not run as root, hold a
/// password, install a privileged helper, or hide an escalation
/// (docs/TRUST_AND_SECURITY.md, "Privilege"). What it can do is write down
/// exactly what it would have done, in a file that can be read before it
/// runs, and let `sudo` ask the person for their own password in their own
/// terminal. Every line comes from the plan they already reviewed; nothing is
/// added to it here.
///
/// The script is deliberately dull: a fixed header, `set -euo pipefail`, a
/// root check, then one quoted command per planned item. There is no loop, no
/// wildcard, no `find`, and no path that was not in the plan.
public struct AdminRemovalScript: Sendable, Hashable {
    /// The whole script, for showing before it is run.
    public var text: String
    /// Where it was written. Inside MacUp's own state directory, `0600`.
    public var path: String
    /// What to type. `sudo` asks for the password, not MacUp.
    public var command: String
    /// The items the script removes, in order.
    public var items: [ManualRemoval]
    /// Items MacUp left out of the script, and why. They keep their written
    /// steps; what MacUp will not do is put them in a file that runs as root.
    public var refused: [(item: ManualRemoval, reason: String)]

    public static func == (lhs: AdminRemovalScript, rhs: AdminRemovalScript) -> Bool {
        lhs.text == rhs.text && lhs.path == rhs.path && lhs.command == rhs.command && lhs.items == rhs.items
            && lhs.refused.map(\.item) == rhs.refused.map(\.item)
            && lhs.refused.map(\.reason) == rhs.refused.map(\.reason)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(path)
    }

    /// Whether there is anything to run.
    public var isEmpty: Bool { items.isEmpty }
}

public enum AdminRemovalScriptWriter {
    /// The file name for one plan's script, from the subject rather than from
    /// anything a third party chose: a cask token or an app name never
    /// reaches the file system here.
    static let fileName = "admin-removal.sh"

    /// Builds the script's text from a plan, and says what it left out.
    ///
    /// Pure: nothing is written, nothing is run. An item is left out when it
    /// has no command MacUp built itself, or when any word of that command
    /// holds a character MacUp cannot write into a script and still promise
    /// the script means what it says.
    public static func render(
        _ plan: UninstallPlan,
        generatedAt: Date = Date(),
        macUpVersion: String = MacUp.version
    ) -> (text: String, items: [ManualRemoval], refused: [(item: ManualRemoval, reason: String)]) {
        var items: [ManualRemoval] = []
        var refused: [(item: ManualRemoval, reason: String)] = []
        var body: [String] = []

        for item in plan.cannotRemove {
            guard !item.commands.isEmpty else {
                refused.append((item, "MacUp has no exact command for it, so the written steps are the only way."))
                continue
            }
            var lines: [String] = []
            var problem: String?
            for command in item.commands {
                guard let rendered = render(command) else {
                    problem = command.words.first.map(tools.contains) == true
                        ? "Its path holds a character MacUp will not write into a script that runs as root."
                        : "Its command is not one of the three tools MacUp writes into a script: rm, launchctl, pkgutil."
                    break
                }
                lines += rendered
            }
            if let problem {
                refused.append((item, problem))
                continue
            }
            items.append(item)
            body.append("# " + comment(item.path))
            body += lines
            body.append("")
        }

        var text = header(plan, generatedAt: generatedAt, macUpVersion: macUpVersion, items: items)
        text += body.joined(separator: "\n")
        text += "\nprintf '%s\\n' 'Done. MacUp removed nothing; this script did, as root.'\n"
        return (text, items, refused)
    }

    /// Writes the rendered script into MacUp's own state directory, `0600`,
    /// replacing an earlier one. Returns what was written and the command to
    /// run it, which is `bash <path>` under `sudo`: the file is not made
    /// executable, so it cannot be run by accident later.
    public static func write(
        _ plan: UninstallPlan,
        paths: MacUpPaths,
        generatedAt: Date = Date(),
        macUpVersion: String = MacUp.version
    ) throws -> AdminRemovalScript {
        let rendered = render(plan, generatedAt: generatedAt, macUpVersion: macUpVersion)
        let directory = try PrivateDirectory(paths.stateDirectory)
        try directory.write(Data(rendered.text.utf8), named: fileName)
        let path = paths.stateDirectory + "/" + fileName
        return AdminRemovalScript(
            text: rendered.text,
            path: path,
            command: "sudo bash " + CommandInvocation.quoted(path),
            items: rendered.items,
            refused: rendered.refused
        )
    }

    // MARK: Rendering

    private static func header(
        _ plan: UninstallPlan,
        generatedAt: Date,
        macUpVersion: String,
        items: [ManualRemoval]
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let subject = comment(plan.subject.name)
        return """
            #!/bin/bash
            # Removing \(subject): the part that needs an administrator.
            #
            # Written by MacUp \(macUpVersion) at \(formatter.string(from: generatedAt)) from the plan you
            # reviewed. MacUp does not run this: you do, with sudo, which asks you for
            # your own password. MacUp never sees it, never stores it, and never runs
            # as root itself.
            #
            # Read it before you run it. Every line below removes one thing the plan
            # listed, in the order it listed them. \(items.count) item\(items.count == 1 ? "" : "s").
            #
            # These removals are permanent. Root does not use the Trash, so there is
            # nothing to put back afterwards.
            #
            #   sudo bash <the path MacUp printed for this file>
            set -euo pipefail

            if [[ "$(id -u)" != 0 ]]; then
                echo "This script has to run as root: sudo bash $0" >&2
                exit 1
            fi

            """
    }

    /// The only three tools the script may call. A command naming anything
    /// else is not written, whatever built it: this is the list a reader of
    /// the script can check it against.
    static let tools = ["rm", "launchctl", "pkgutil"]

    /// One command as script lines: what it is about to do, then the command.
    /// `nil` when the tool is not one of ``tools`` or any argument cannot be
    /// written safely.
    private static func render(_ command: AdminCommand) -> [String]? {
        guard let tool = command.words.first, tools.contains(tool) else { return nil }
        var quoted: [String] = [tool]
        for word in command.words.dropFirst() {
            guard let safe = quotedWord(word) else { return nil }
            quoted.append(safe)
        }
        guard let message = quotedWord(command.describes) else { return nil }
        return [
            "printf '%s\\n' " + message,
            quoted.joined(separator: " ") + (command.ignoreFailure ? " || true" : ""),
        ]
    }

    /// A word for a script: always single-quoted, so nothing in it is read by
    /// the shell, and refused outright when it holds a character that would
    /// make the file say one thing and do another — a control character, a
    /// newline, a bidirectional override, or a NUL.
    static func quotedWord(_ word: String) -> String? {
        guard !word.isEmpty, !word.contains("\0"),
              !word.unicodeScalars.contains(where: TerminalText.isUnsafe),
              !word.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" })
        else { return nil }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Text for a comment line: sanitised, and with every newline removed, so
    /// a comment cannot become a command.
    static func comment(_ text: String) -> String {
        TerminalText.sanitize(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

public extension AdminCommand {
    /// Removes a file or a folder, permanently. `--` guards a path whose name
    /// begins with a hyphen.
    static func remove(_ path: String, isDirectory: Bool) -> AdminCommand {
        AdminCommand(
            isDirectory ? ["rm", "-rf", "--", path] : ["rm", "-f", "--", path],
            describes: "Removing " + path
        )
    }

    /// Stops a launchd job. Failure is ignored: a job that is not loaded is
    /// already in the state this asks for.
    static func bootout(domain: String, label: String) -> AdminCommand {
        AdminCommand(
            ["launchctl", "bootout", domain + "/" + label],
            ignoreFailure: true,
            describes: "Stopping " + domain + "/" + label
        )
    }

    /// Forgets an installer package's receipt. The identifier is checked
    /// rather than quoted alone, because `pkgutil` takes no `--` guard.
    static func forget(_ identifier: String) -> AdminCommand? {
        let allowed = identifier.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "_"
        }
        guard allowed, !identifier.isEmpty, !identifier.hasPrefix("-") else { return nil }
        return AdminCommand(
            ["pkgutil", "--forget", identifier],
            describes: "Forgetting the receipt for " + identifier
        )
    }
}
