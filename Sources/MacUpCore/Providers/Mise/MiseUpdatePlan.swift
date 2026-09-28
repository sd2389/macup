import Foundation

/// Planning and verification for mise-managed runtimes (CLAUDE.md §9, §11).
///
/// `mise upgrade --help` (mise 2026.7.3) states the behaviour MacUp relies
/// on: "By default, this keeps the range specified in mise.toml. So if you
/// have node@20 set, it will upgrade to the latest 20.x.x version available."
/// That is the whole plan — the user's request is preserved and no major
/// version is bumped, because `--bump` is the flag that would rewrite
/// `mise.toml`, and MacUp never passes it (CLAUDE.md §2.18).
///
/// The same help says "This will update mise.lock if it is enabled", and
/// MacUp cannot see that setting from the outside, so every mise plan says a
/// lockfile may change.
///
/// `--cd` names the directory mise resolves configuration from. It is in the
/// arguments rather than left to whatever directory MacUp was started in,
/// because mise walks up from the working directory: run from inside a
/// project, the same command would target that project's configuration. A
/// plan that shows the directory is a plan that means the same thing
/// wherever it runs.
extension MiseProvider {
    /// `mise ls --json`, the read-only listing MacUp reads back to confirm an
    /// upgrade. Already on the read-only allowlist, and it names no tool.
    static let toolListArguments = ["ls", "--json"]

    public func executionEnvironment(context: ProviderContext) -> [String: String] {
        let directory = context.installation.map { [$0.executable.directory] } ?? []
        return Self.environmentPolicy.environment(
            from: context.environment,
            searchPath: SearchPath.combine(directory, context.searchPath, SearchPath.system)
        )
    }

    public func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        let installation = try PlanSupport.installation(context, id)
        let tool = try PlanSupport.argument(naming: candidate.id)
        let requested = candidate.details["requested"]
        let scope = MiseConfigScope(rawValue: candidate.details["configScope"] ?? "") ?? .unknown
        let configPath = candidate.details["configPath"]

        switch scope {
        case .global, .home:
            break
        case .project:
            throw PlanSupport.cannotPlan(
                "\(candidate.displayName) is requested by a project's own configuration, so MacUp reports it rather than changing it.",
                detail: configPath.map { "Requested by \($0)." },
                recoverySuggestion: "Run mise in that project yourself if you want to upgrade it there."
            )
        case .system:
            throw PlanSupport.cannotPlan(
                "\(candidate.displayName) is requested by a system-wide mise configuration, which MacUp does not change.",
                detail: configPath.map { "Requested by \($0)." }
            )
        case .unknown:
            throw PlanSupport.cannotPlan(
                "MacUp could not tell which configuration file requests \(candidate.displayName), so it will not guess which one an upgrade would follow.",
                recoverySuggestion: "Run `mise outdated` to see where the request comes from."
            )
        }

        // An exact request is already satisfied: the newest version matching
        // it is the one installed. mise could only reach the newer version by
        // editing the request, which is exactly what MacUp will not do.
        if let requested, let current = candidate.installedVersion?.raw, requested == current {
            throw PlanSupport.cannotPlan(
                "\(candidate.displayName) is pinned to exactly \(current) in your mise configuration. "
                    + "Reaching \(candidate.availableVersion.raw) means editing that request, which MacUp does not do for you.",
                detail: configPath.map { "Requested by \($0)." },
                recoverySuggestion: "Change the requested version yourself, then MacUp can upgrade within the new range."
            )
        }

        let arguments = ["upgrade", "--cd", context.homeDirectory, tool]
        let signals = Set(candidate.signals)
        let lockfile = candidate.details["lockfile"]

        var rationale = "mise upgrades \(tool) to the newest version matching"
        rationale += requested.map { " your request \"\($0)\"" } ?? " your configured request"
        rationale += ", which is \(candidate.availableVersion.raw). "
        rationale += "The requested version itself is left alone, so no major version is bumped."
        if let lockfile {
            rationale += " Your lockfile \(lockfile) may be rewritten to record the new version."
        } else {
            rationale += " Your mise configuration is not rewritten, though mise updates a lockfile if you have lockfiles enabled."
        }
        rationale += " MacUp resolves configuration from \(context.homeDirectory), so a project you happen to be in cannot change what this does."
        if signals.contains(.runtimeOrToolchain) {
            rationale += " This is a language runtime, so anything built against the old version may need attention."
        }
        // Changing the active Node changes which global npm packages exist,
        // which is exactly the kind of surprise a plan should name (CLAUDE.md §9).
        if ["node", "nodejs"].contains(RuntimeCatalog.baseName(tool)) {
            rationale += " Global npm packages are installed per Node version, so the ones you have under "
                + "\(candidate.installedVersion?.raw ?? "the current version") will not be there until you reinstall them."
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
                    summary: "Upgrade \(tool) within its requested version",
                    invocation: CommandInvocation(executable: installation.executable.path, arguments: arguments),
                    effect: .modifying,
                    expectsNetwork: true,
                    mayRequirePrivilege: false,
                    // An hour: mise compiles some runtimes from source.
                    timeoutSeconds: 3600
                )
            ],
            expectsNetwork: true,
            mayRequirePrivilege: false,
            mayRequireRestart: false,
            // mise.toml is not touched without --bump, but mise.lock is
            // updated when lockfiles are enabled, and MacUp cannot see that
            // setting, so it says so rather than promising otherwise.
            mayChangeUserConfiguration: true,
            verification: [
                VerificationStep(
                    summary: "List mise's tools and look for \(tool) active at \(candidate.availableVersion.raw).",
                    invocation: CommandInvocation(
                        executable: installation.executable.path,
                        arguments: Self.toolListArguments
                    ),
                    expectedVersion: candidate.availableVersion.raw
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
            let listing = try await run(Self.toolListArguments, installation, context: context, timeout: .seconds(120))
            guard listing.succeeded else {
                return PlanSupport.unverifiable(
                    candidate.id,
                    expected: expected,
                    because: "`mise ls` failed afterwards, so MacUp cannot say which version is active now."
                )
            }
            let items = try MiseParsers.parseInventory(
                listing.standardOutput,
                context: parserContext(installation, context: context, command: listing.invocation.displayString)
            )
            guard let item = items.elements.first(where: { $0.id == candidate.id }) else {
                return PlanSupport.compare(candidate.id, expected: expected, observed: nil)
            }
            // The active version is the one that matters: mise keeps older
            // installs around, and MacUp does not prune them.
            return PlanSupport.compare(candidate.id, expected: expected, observed: item.activeVersion?.raw)
        } catch {
            return PlanSupport.unverifiable(
                candidate.id,
                expected: expected,
                because: MacUpError.wrapping(error, context: "Listing mise's tools again").message
            )
        }
    }
}
