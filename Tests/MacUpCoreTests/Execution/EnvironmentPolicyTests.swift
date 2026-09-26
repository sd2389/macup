import Testing

@testable import MacUpCore

@Suite("EnvironmentPolicy and SearchPath")
struct EnvironmentPolicyTests {
    let source = [
        "HOME": "/Users/example",
        "LANG": "en_US.UTF-8",
        "PATH": "/evil:/usr/bin",
        "TERM": "xterm-256color",
        "AWS_SECRET_ACCESS_KEY": "do-not-pass",
        "GITHUB_TOKEN": "do-not-pass",
        "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
        "NODE_OPTIONS": "--require /tmp/evil.js",
        "HOMEBREW_NO_ANALYTICS": "1",
        "NPM_CONFIG_REGISTRY": "https://registry.example.com",
        "npm_config_cache": "/tmp/npm-cache",
        "NO_COLOR": "",
    ]

    @Test("Only allowlisted variables pass; secrets and injection variables do not")
    func onlyAllowlistedVariablesPass() {
        let environment = EnvironmentPolicy.base.environment(from: source, searchPath: ["/usr/bin"])
        #expect(environment["HOME"] == "/Users/example")
        #expect(environment["LANG"] == "en_US.UTF-8")
        for blocked in ["TERM", "AWS_SECRET_ACCESS_KEY", "GITHUB_TOKEN", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS",
                        "HOMEBREW_NO_ANALYTICS", "NPM_CONFIG_REGISTRY"] {
            #expect(environment[blocked] == nil, "\(blocked) should not be passed")
        }
    }

    @Test("PATH is always the constructed search path, never the inherited one")
    func pathIsConstructed() {
        let environment = EnvironmentPolicy.base.environment(from: source, searchPath: ["/opt/tool/bin", "/usr/bin"])
        #expect(environment["PATH"] == "/opt/tool/bin:/usr/bin")
        let emptyPath = EnvironmentPolicy.base.environment(from: source, searchPath: [])
        #expect(emptyPath["PATH"] == "")
    }

    @Test("Provider prefixes, case-insensitive prefixes, and overrides")
    func prefixesAndOverrides() {
        let policy = EnvironmentPolicy.base.adding(
            prefixes: ["HOMEBREW_"],
            caseInsensitivePrefixes: ["npm_config_"],
            overrides: ["HOMEBREW_NO_AUTO_UPDATE": "1", "NO_COLOR": "1"]
        )
        let environment = policy.environment(from: source, searchPath: ["/usr/bin"])
        #expect(environment["HOMEBREW_NO_ANALYTICS"] == "1")
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["NPM_CONFIG_REGISTRY"] == "https://registry.example.com")
        #expect(environment["npm_config_cache"] == "/tmp/npm-cache")
        #expect(environment["NO_COLOR"] == "1")
    }

    @Test("Overrides win over inherited values")
    func overridesWin() {
        let policy = EnvironmentPolicy.base.adding(prefixes: ["HOMEBREW_"], overrides: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        let environment = policy.environment(from: ["HOMEBREW_NO_AUTO_UPDATE": ""], searchPath: [])
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
    }

    @Test("Values containing NUL are dropped")
    func dropsNulValues() {
        let environment = EnvironmentPolicy.base.environment(from: ["HOME": "/Users/a\u{0}b"], searchPath: [])
        #expect(environment["HOME"] == nil)
    }

    @Test("Search paths drop empty, relative, and duplicate entries")
    func searchPathSanitizing() {
        let parsed = SearchPath.parse("/usr/local/bin:.::bin:./node_modules/.bin:/usr/bin/:/usr/local/bin:/opt/x\ny")
        #expect(parsed == ["/usr/local/bin", "/usr/bin"])
        #expect(SearchPath.parse(nil).isEmpty)
        #expect(SearchPath.combine(["/a", "/b"], ["/b", "/c"], SearchPath.system).prefix(3) == ["/a", "/b", "/c"])
    }
}
