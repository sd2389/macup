import Foundation
import MacUpTestSupport
import Testing

@testable import MacUpCore

@Suite("Policy listing")
struct PolicyListingTests {
    private func configuration(_ json: String) throws -> LoadedConfiguration {
        let directory = try TemporaryDirectory(prefix: "macup-policy-listing")
        let file = directory.appending("config.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        let loaded = ConfigurationStore(fileURL: file).load()
        // Keep the directory alive until the configuration has been read.
        withExtendedLifetime(directory) {}
        return loaded
    }

    @Test("With no rules of their own, the listing is the built-in defaults")
    func defaults() {
        let listing = PolicyListing(configuration: .defaults)
        #expect(listing.defaultPolicy == .ask)
        #expect(listing.confirmMajorUpdates)
        #expect(listing.items.isEmpty)
        #expect(listing.unreadableItemKeys.isEmpty)
        #expect(listing.isDefault)
        #expect(listing.providers.map(\.provider) == ProviderID.known)
        #expect(listing.providers.allSatisfy { $0.enabled && $0.policy == .inherit && $0.effectivePolicy == .ask })
        #expect(listing.automaticModificationsAllowed)
        #expect(listing.configurationFile == nil)
    }

    @Test("Every explicit rule is reported, with where it came from")
    func explicitRules() throws {
        let loaded = try configuration("""
            {
              "schemaVersion": 1,
              "global": { "defaultPolicy": "auto", "confirmMajorUpdates": false },
              "providers": {
                "npm": { "enabled": false, "policy": "ignore" },
                "mise": { "enabled": true, "policy": "inherit" }
              },
              "items": {
                "npm:@anthropic-ai/claude-code": { "policy": "ask" },
                "brew:postgresql": { "policy": "ignore" },
                "brew:git": { "policy": "inherit" }
              }
            }
            """)
        #expect(loaded.issues.isEmpty, "\(loaded.issues)")
        let listing = PolicyListing(loaded)

        #expect(listing.defaultPolicy == .auto)
        #expect(!listing.confirmMajorUpdates)
        #expect(listing.configurationFile == loaded.path)
        #expect(!listing.isDefault)

        #expect(listing.items.map(\.item.rawValue) == ["brew:git", "brew:postgresql", "npm:@anthropic-ai/claude-code"])
        #expect(listing.items.allSatisfy { $0.source == .item })
        let git = try #require(listing.rule(for: try PackageID(parsing: "brew:git")))
        #expect(git.policy == .inherit)
        #expect(git.effectivePolicy == .auto, "brew:git inherits the global default")
        #expect(git.path == "items.brew:git.policy")
        #expect(git.provider == .homebrew)

        let claude = try #require(listing.rule(for: try PackageID(parsing: "npm:@anthropic-ai/claude-code")))
        #expect(claude.policy == .ask)
        #expect(claude.effectivePolicy == .ask)

        let npm = try #require(listing.rule(for: .npm))
        #expect(npm.explicit)
        #expect(!npm.enabled)
        #expect(npm.policy == .ignore)
        #expect(npm.effectivePolicy == .ignore)
        #expect(npm.path == "providers.npm")
        #expect(npm.source == .provider)

        let mise = try #require(listing.rule(for: .mise))
        #expect(mise.explicit)
        #expect(mise.policy == .inherit)
        #expect(mise.effectivePolicy == .auto, "inherit resolves to the global default")

        let homebrew = try #require(listing.rule(for: .homebrew))
        #expect(!homebrew.explicit, "the file says nothing about Homebrew")
        #expect(homebrew.enabled)
        #expect(homebrew.policy == .inherit)
    }

    @Test("A provider the file names but MacUp does not know is still listed, after the known ones")
    func unknownProviderIsListedLast() throws {
        let loaded = try configuration(#"{"schemaVersion":1,"providers":{"cargo":{"enabled":true,"policy":"auto"}}}"#)
        #expect(loaded.hasErrors, "an unknown provider is a configuration error")

        // The rule is reported even though it is the reason nothing automatic
        // may run: a listing that hid it would hide why.
        let listing = PolicyListing(loaded)
        #expect(!listing.automaticModificationsAllowed)
        #expect(listing.providers.map(\.provider.rawValue) == ProviderID.known.map(\.rawValue) + ["cargo"])
        #expect(listing.rule(for: ProviderID(rawValue: "cargo"))?.explicit == true)
        #expect(listing.rule(for: .homebrew)?.explicit == false)
    }

    @Test("An item key that is not a package ID is reported, not dropped")
    func unreadableItemKeysAreKept() {
        var configuration = MacUpConfiguration.defaults
        configuration.items["pip:requests"] = MacUpConfiguration.ItemSettings(policy: .ignore)
        configuration.items["brew:git"] = MacUpConfiguration.ItemSettings(policy: .auto)

        let listing = PolicyListing(configuration: configuration, automaticModificationsAllowed: false)
        #expect(listing.items.map(\.item.rawValue) == ["brew:git"])
        #expect(listing.unreadableItemKeys == ["pip:requests"])
        #expect(!listing.isDefault)
    }

    @Test("A listing agrees with the decision the engine will make")
    func listingMatchesTheEngine() throws {
        let loaded = try configuration("""
            {
              "schemaVersion": 1,
              "global": { "defaultPolicy": "ignore" },
              "providers": { "homebrew": { "enabled": true, "policy": "auto" } },
              "items": { "brew:postgresql": { "policy": "ask" } }
            }
            """)
        let engine = PolicyEngine(loaded)
        let listing = engine.rules()

        for name in ["brew:postgresql", "brew:git", "npm:typescript", "mise:node"] {
            let item = try PackageID(parsing: name)
            let resolved = engine.effectivePolicy(for: item).policy
            if let rule = listing.rule(for: item) {
                #expect(rule.effectivePolicy == resolved, "\(name)")
            } else if let provider = listing.rule(for: item.provider) {
                #expect(provider.effectivePolicy == resolved, "\(name)")
            }
        }
        #expect(listing.defaultPolicy == .ignore)
        #expect(listing.rule(for: .homebrew)?.effectivePolicy == .auto)
    }

    @Test("Listing the rules creates nothing, even when there is no file yet")
    func listingIsReadOnly() throws {
        let directory = try TemporaryDirectory(prefix: "macup-policy-listing")
        let loaded = ConfigurationStore(fileURL: directory.appending("config.json")).load()
        let listing = PolicyEngine(loaded).rules()

        #expect(listing.isDefault)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("A listing survives a round trip through JSON, for --json output")
    func codable() throws {
        var configuration = MacUpConfiguration.defaults
        configuration.items["brew:git"] = MacUpConfiguration.ItemSettings(policy: .pin)
        let listing = PolicyListing(
            configuration: configuration,
            automaticModificationsAllowed: true,
            configurationFile: "/tmp/config.json"
        )
        let data = try JSONEncoder().encode(listing)
        #expect(try JSONDecoder().decode(PolicyListing.self, from: data) == listing)
    }
}
