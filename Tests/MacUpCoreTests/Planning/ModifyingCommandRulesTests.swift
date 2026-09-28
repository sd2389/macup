import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Modifying command rules")
struct ModifyingCommandRulesTests {
    private func request(_ executable: String, _ arguments: [String], effect: CommandEffect = .modifying) -> CommandRequest {
        CommandRequest(executable: URL(fileURLWithPath: executable), arguments: arguments, effect: effect)
    }

    private func isAllowed(_ executable: String, _ arguments: [String], effect: CommandEffect = .modifying) -> Bool {
        let request = request(executable, arguments, effect: effect)
        return ModifyingCommandRules.all.contains { $0.matches(request) }
    }

    @Test("The shapes MacUp's providers plan are allowed")
    func plannedShapesAreAllowed() {
        #expect(isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "git"]))
        #expect(isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--cask", "--yes", "firefox"]))
        #expect(isAllowed("/opt/homebrew/bin/npm", ["install", "-g", "@anthropic-ai/claude-code@2.1.283"]))
        #expect(isAllowed("/Users/example/.local/bin/mise", ["upgrade", "--cd", "/Users/example", "node"]))
    }

    @Test("Blanket Homebrew upgrades are not allowed, because exclusions depend on naming the item")
    func blanketHomebrewUpgradeRefused() {
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade"]))
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--yes"]))
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula"]), "no --yes: not a shape MacUp plans")
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "git", "curl"]), "two items at once")
    }

    @Test("Commands MacUp must never run have no rule")
    func forbiddenCommandsHaveNoRule() {
        let forbidden: [(String, [String])] = [
            ("/opt/homebrew/bin/brew", ["cleanup"]),
            ("/opt/homebrew/bin/brew", ["cleanup", "git"]),
            ("/opt/homebrew/bin/brew", ["unpin", "postgresql@16"]),
            ("/opt/homebrew/bin/brew", ["uninstall", "git"]),
            ("/opt/homebrew/bin/brew", ["autoremove"]),
            ("/opt/homebrew/bin/brew", ["install", "cowsay"]),
            ("/opt/homebrew/bin/npm", ["update", "-g"]),
            ("/opt/homebrew/bin/npm", ["uninstall", "-g", "corepack"]),
            ("/opt/homebrew/bin/npm", ["install", "-g", "--ignore-scripts", "corepack@1.0.0"]),
            ("/Users/example/.local/bin/mise", ["upgrade", "--bump", "node"]),
            ("/Users/example/.local/bin/mise", ["upgrade", "--cd", "/Users/example", "--bump", "node"]),
            ("/Users/example/.local/bin/mise", ["prune"]),
            ("/Users/example/.local/bin/mise", ["self-update"]),
            ("/Users/example/.local/bin/mise", ["use", "node@26"]),
            ("/usr/sbin/softwareupdate", ["--install", "-a"]),
            ("/usr/bin/sudo", ["brew", "upgrade", "--formula", "--yes", "git"]),
        ]
        for (executable, arguments) in forbidden {
            #expect(!isAllowed(executable, arguments), "\(executable) \(arguments.joined(separator: " ")) must have no rule")
        }
    }

    @Test("A read-only or metadata-refresh request never matches a modifying rule")
    func effectMustMatch() {
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "git"], effect: .readOnly))
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "git"], effect: .metadataRefresh))
    }

    @Test("A name that could be read as an option is refused as a positional")
    func optionShapedNamesRefused() {
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "--force"]))
        #expect(!isAllowed("/opt/homebrew/bin/brew", ["upgrade", "--formula", "--yes", "-rf"]))
        #expect(!isAllowed("/opt/homebrew/bin/npm", ["install", "-g", "--registry=http://evil"]))
    }

    @Test("Names carrying control or bidirectional characters are refused as positionals")
    func unreadableNamesRefused() {
        for name in HostileInput.unrepresentableNames {
            #expect(!ModifyingCommandRule.isAcceptablePositional(name), "\(name.debugDescription) is not displayable")
        }
        // Shell metacharacters are inert in an argument array, so they are
        // accepted verbatim: what is refused is what a reader could not see.
        for name in ["pkg; rm -rf ~", "$(touch /tmp/x)", "`id`", "${HOME}", "pkg && echo pwned", "glob*?[abc]"] {
            #expect(ModifyingCommandRule.isAcceptablePositional(name))
        }
    }

    @Test("Every rule is a modifying command that names at most two arguments")
    func rulesStayNarrow() {
        #expect(ModifyingCommandRules.all.count == 4, "adding a rule is a trust decision")
        for rule in ModifyingCommandRules.all {
            #expect(rule.effect == .modifying)
            #expect(rule.maximumPositionals >= 1 && rule.maximumPositionals <= 2)
            #expect(!rule.leadingArguments.isEmpty)
            #expect(!rule.leadingArguments.contains("--bump"))
            #expect(["brew", "npm", "mise"].contains(rule.executableName))
        }
    }
}
