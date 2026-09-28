import Foundation

/// Planning and verification for globally installed npm packages
/// (CLAUDE.md §9, §11).
///
/// One package at a time, named as `<name>@<version>` so the plan the user
/// approved and the version npm installs are the same thing. `npm help
/// install` documents that spec: `<name>@<version>` is resolved from the
/// registry, and the version is separated at the last `@`, which is what
/// makes a scoped name like `@anthropic-ai/claude-code` work. Nothing is
/// concatenated into a command line — the spec is one element of an
/// argument array.
///
/// The bare `npm install -g <name>` form would install whatever the `latest`
/// tag points at when the command runs, which can differ from the version
/// shown in the plan. Naming the version removes that gap and lets
/// verification assert an exact result.
extension NpmProvider {
    /// `npm ls -g --json --depth=0`, the read-only listing MacUp reads back
    /// to confirm an install. Already on the read-only allowlist, and it
    /// names no package.
    static let globalListArguments = ["ls", "-g", "--json", "--depth=0"]

    /// Characters a version may contain after its leading digit.
    ///
    /// The position a version occupies in a package spec also accepts dist
    /// tags, ranges, paths, and git URLs, so a value that is not plainly a
    /// version could quietly mean something else — `npm install -g pkg@next`
    /// is a different request from the one the user reviewed. A published
    /// semantic version always starts with a digit, which is the cheap,
    /// unambiguous test; anything else is refused rather than interpreted.
    private static let versionCharacters = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+_")

    public func executionEnvironment(context: ProviderContext) -> [String: String] {
        guard let installation = context.installation else {
            return EnvironmentPolicy.base.environment(from: context.environment, searchPath: SearchPath.system)
        }
        return environmentPolicy(installation, context: context).environment(
            from: context.environment,
            searchPath: childSearchPath(installation, context: context)
        )
    }

    public func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        let installation = try PlanSupport.installation(context, id)
        let name = try PlanSupport.argument(naming: candidate.id)
        let version = try Self.version(of: candidate)
        let signals = Set(candidate.signals)
        let arguments = ["install", "-g", "\(name)@\(version)"]

        let node = installation.fact(FactKey.nodePath)
        let nodeVersion = installation.fact(FactKey.nodeVersion)
        let manager = installation.fact(FactKey.nodeManager)
        var rationale = "npm installs \(name)@\(version) into its global packages"
        if let node {
            rationale += ", which belong to the Node at \(node)"
            if let nodeVersion { rationale += " (\(nodeVersion))" }
            if let manager, manager != NodeManager.unknown.displayName {
                rationale += " managed by \(manager)"
            }
        }
        rationale += ". MacUp installs the one package you selected, naming the exact version, so nothing else changes."
        if candidate.id.name == "npm" {
            rationale += " This replaces the npm your shell and MacUp use; a later check reads the new one."
            if let manager, manager != NodeManager.unknown.displayName {
                rationale += " Updating Node through \(manager) may be the better way."
            }
        }
        // A global package lives under one Node version, so a later runtime
        // change would take it away (CLAUDE.md §9).
        if let manager, manager != NodeManager.unknown.displayName, manager != NodeManager.homebrew.displayName {
            rationale += " Global packages belong to this one Node version; changing the active version with "
                + "\(manager) gives you a different set of global packages."
        }
        if signals.contains(.packageManagerSelfUpdate) && candidate.id.name != "npm" {
            rationale += " \(name) manages other software, so this can change how that software is installed."
        }
        if let prefix = installation.fact(FactKey.globalPrefix) {
            rationale += " MacUp never uses sudo: if \(prefix) is not yours to write, npm fails and says so."
        }

        return ExecutionPlan(
            createdAt: context.now(),
            item: candidate.id,
            currentVersion: candidate.installedVersion,
            proposedVersion: candidate.availableVersion,
            risk: candidate.risk,
            rationale: rationale,
            steps: [
                ExecutionStep(
                    summary: "Install \(name)@\(version) globally",
                    invocation: CommandInvocation(executable: installation.executable.path, arguments: arguments),
                    effect: .modifying,
                    expectsNetwork: true,
                    mayRequirePrivilege: false,
                    timeoutSeconds: 900
                )
            ],
            expectsNetwork: true,
            mayRequirePrivilege: false,
            mayRequireRestart: false,
            mayChangeUserConfiguration: false,
            verification: [
                VerificationStep(
                    summary: "List npm's global packages and look for \(name) at \(version).",
                    invocation: CommandInvocation(
                        executable: installation.executable.path,
                        arguments: Self.globalListArguments
                    ),
                    expectedVersion: version
                )
            ],
            rollback: .notImplemented
        )
    }

    public func verify(
        _ result: ExecutionResult,
        for candidate: UpdateCandidate,
        context: ProviderContext
    ) async throws -> VerificationResult {
        let expected = candidate.availableVersion.raw
        do {
            let installation = try PlanSupport.installation(context, id)
            let listing = try await run(Self.globalListArguments, installation, context: context, timeout: .seconds(120))
            // `npm ls` exits 1 when it finds problems but still prints the
            // tree, so the parser decides, not the exit status.
            let items = try NpmParsers.parseInventory(
                listing,
                context: NpmParsers.Context(command: listing.invocation.displayString)
            )
            guard let item = items.elements.first(where: { $0.id == candidate.id }) else {
                return PlanSupport.compare(candidate.id, expected: expected, observed: nil)
            }
            return PlanSupport.compare(candidate.id, expected: expected, observed: item.activeVersion?.raw)
        } catch {
            return PlanSupport.unverifiable(
                candidate.id,
                expected: expected,
                because: MacUpError.wrapping(error, context: "Listing npm's global packages again").message
            )
        }
    }

    /// The version to name in the command, or an error when the value npm
    /// reported is not plainly a version.
    static func version(of candidate: UpdateCandidate) throws -> String {
        let version = candidate.availableVersion.raw
        guard let first = version.first, first.isASCII, first.isNumber,
              version.count <= 64,
              version.allSatisfy({ versionCharacters.contains($0) })
        else {
            throw PlanSupport.cannotPlan(
                "npm offered \(candidate.displayName) something MacUp will not repeat back to it as a version.",
                detail: "Offered: \(TerminalText.sanitize(version.debugDescription))",
                recoverySuggestion: "npm reads tags, ranges, and paths where a version goes, so MacUp does not guess which one this is."
            )
        }
        return version
    }
}
