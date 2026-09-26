import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("PackageID")
struct PackageIDTests {
    @Test(
        "Provider-qualified IDs parse and round-trip",
        arguments: [
            ("brew:git", "brew", "git", ProviderID.homebrew),
            ("brew:python@3.12", "brew", "python@3.12", .homebrew),
            ("brew:user/tap/formula", "brew", "user/tap/formula", .homebrew),
            ("brew-cask:visual-studio-code", "brew-cask", "visual-studio-code", .homebrew),
            ("npm:@anthropic-ai/claude-code", "npm", "@anthropic-ai/claude-code", .npm),
            ("mise:node", "mise", "node", .mise),
            ("mise:npm:prettier", "mise", "npm:prettier", .mise),
            ("macos:macOS 27.2 Beta-26B5091g", "macos", "macOS 27.2 Beta-26B5091g", .macos),
        ]
    )
    func parses(raw: String, namespace: String, name: String, provider: ProviderID) throws {
        let id = try PackageID(parsing: raw)
        #expect(id.namespace.rawValue == namespace)
        #expect(id.name == name)
        #expect(id.provider == provider)
        #expect(id.rawValue == raw)
    }

    @Test("Names are never assumed unique across providers")
    func namespacesDistinguish() throws {
        #expect(try PackageID(parsing: "brew:node") != PackageID(parsing: "mise:node"))
        #expect(try PackageID(parsing: "brew:firefox") != PackageID(parsing: "brew-cask:firefox"))
    }

    @Test("Malformed IDs are rejected with a reason", arguments: ["git", "pip:requests", "brew:", ":git"])
    func rejectsMalformed(raw: String) {
        #expect(throws: PackageID.ValidationError.self) { try PackageID(parsing: raw) }
    }

    @Test("Names that could confuse a command or a terminal are rejected")
    func rejectsUnrepresentableNames() {
        for name in HostileInput.unrepresentableNames {
            #expect(PackageID.validateName(name) != nil, "\(name.debugDescription) should be rejected")
            #expect(throws: PackageID.ValidationError.self) { try PackageID(.npm, name) }
        }
    }

    @Test("Other unusual but printable names are kept verbatim")
    func keepsPrintableHostileNames() throws {
        for name in HostileInput.names where PackageID.validateName(name) == nil {
            let id = try PackageID(.npm, name)
            #expect(id.name == name)
            #expect(try PackageID(parsing: id.rawValue) == id)
        }
    }

    @Test("IDs encode as plain strings and validate when decoded")
    func codable() throws {
        let id = try PackageID(parsing: "npm:@scope/pkg")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["npm:@scope\/pkg"]"#)
        #expect(try JSONDecoder().decode([PackageID].self, from: data) == [id])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PackageID].self, from: Data(#"["brew:-rf"]"#.utf8))
        }
    }
}
