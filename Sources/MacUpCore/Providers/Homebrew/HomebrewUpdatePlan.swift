import Foundation

/// Planning and verification for Homebrew formulae and casks
/// (CLAUDE.md §9, §11).
///
/// MacUp upgrades one named item at a time. That is not a performance
/// choice: `brew upgrade` with no arguments upgrades everything Homebrew
/// considers outdated, which would walk straight past the items a user
/// excluded, so naming the item is what makes an exclusion mean anything.
///
/// The commands were confirmed against `brew help upgrade` (Homebrew 7.0.6),
/// which is also where three other decisions come from:
///
/// `--formula` and `--cask` are always passed, because the same word can be
/// both a formula name and a cask token and MacUp does not let Homebrew guess
/// which one the user reviewed. `--yes` is passed because Homebrew's ask mode
/// is now the default and MacUp's subprocesses have no terminal to answer
/// from; the confirmation belongs in MacUp, where the user saw the plan.
/// And two guarantees have no flag at all, only environment variables, so
/// they live in ``HomebrewProvider/executionEnvironment(context:)``.
extension HomebrewProvider {
    /// `brew info --json=v2 --installed`, the read-only listing MacUp reads
    /// back to confirm an upgrade. It is already on the read-only allowlist
    /// and takes no package name, so verification cannot become a command
    /// that touches something else.
    static let installedInfoArguments = ["info", "--json=v2", "--installed"]

    /// Homebrew's read-only environment plus the two things an upgrade must
    /// not do.
    ///
    /// `HOMEBREW_NO_INSTALL_CLEANUP` stops Homebrew running `brew cleanup`
    /// after the upgrade, which MacUp never does on its own
    /// (CLAUDE.md §2.16, §2.17). `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK`
    /// stops Homebrew upgrading installed dependents of the named item,
    /// which would change software the user never reviewed and could
    /// override an exclusion. `brew help upgrade` documents both as the only
    /// way to turn these off; there is no command-line flag.
    static let modifyingEnvironmentPolicy = environmentPolicy.adding(overrides: [
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK": "1",
    ])

    public func executionEnvironment(context: ProviderContext) -> [String: String] {
        let searchPath = context.installation.map { childSearchPath($0.executable) } ?? SearchPath.system
        return Self.modifyingEnvironmentPolicy.environment(from: context.environment, searchPath: searchPath)
    }

    public func makePlan(for candidate: UpdateCandidate, context: ProviderContext) async throws -> ExecutionPlan {
        let installation = try PlanSupport.installation(context, id)
        let name = try PlanSupport.argument(naming: candidate.id)
        let signals = Set(candidate.signals)

        guard !signals.contains(.pinnedByProvider) else {
            throw PlanSupport.cannotPlan(
                "\(candidate.displayName) is pinned in Homebrew, and MacUp does not unpin anything for you.",
                recoverySuggestion: "Unpin it in Homebrew yourself if you want this upgrade."
            )
        }

        // Upgrading on top of an install that never finished would ask
        // Homebrew to reason from a state it did not leave on purpose. The
        // person who knows why it stopped is the one to repair it.
        guard !signals.contains(.installationIncomplete) else {
            throw PlanSupport.cannotPlan(
                "An earlier install of \(candidate.displayName) did not finish, so MacUp will not start another upgrade on top of it.",
                detail: candidate.details["incompleteVersions"].map { "Unfinished: \(candidate.displayName) \($0)" },
                recoverySuggestion: "Check `brew info \(name)` and repair or remove the unfinished version yourself. "
                    + "MacUp changes nothing here until Homebrew's own state is consistent again."
            )
        }

        let isCask: Bool
        switch candidate.id.namespace {
        case .brew: isCask = false
        case .brewCask: isCask = true
        default:
            throw PlanSupport.cannotPlan(
                "MacUp cannot tell whether \(candidate.displayName) is a Homebrew formula or a cask, so it will not choose for you.",
                detail: "Package ID: \(candidate.id.rawValue)"
            )
        }

        let arguments = ["upgrade", isCask ? "--cask" : "--formula", "--yes", name]
        let label = isCask ? "cask" : "formula"
        let current = candidate.installedVersion?.raw ?? "an unreported version"
        let needsAdministrator = signals.contains(.administratorAuthorizationMayBeRequired)

        var rationale = "Homebrew upgrades the \(label) \(name) from \(current) to \(candidate.availableVersion.raw). "
            + "MacUp names the item instead of upgrading everything, so the items you excluded stay excluded, "
            + "and it asks Homebrew to leave installed dependents alone and to skip its automatic cleanup."
        if needsAdministrator {
            rationale += " This cask installs through a macOS installer package, so Homebrew may ask for an administrator "
                + "password itself; MacUp neither supplies nor stores one."
        }
        let buildsFromSource = signals.contains(.buildsFromSource)
        if buildsFromSource {
            rationale += " Homebrew has no ready-made build for where it is installed, so it will compile \(name) from "
                + "source, which can take an hour or more. Let it finish: MacUp never stops it part-way, because "
                + "Homebrew unlinks the old version before it builds the new one."
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
                    summary: "Upgrade the \(label) \(name)",
                    invocation: CommandInvocation(executable: installation.executable.path, arguments: arguments),
                    effect: .modifying,
                    expectsNetwork: true,
                    mayRequirePrivilege: needsAdministrator,
                    // An hour: a cask can be a multi-gigabyte download. Four
                    // when Homebrew has said it must compile, because a large
                    // package can take longer than one; on the limit MacUp
                    // interrupts Homebrew the way Ctrl+C would, never kills it.
                    timeoutSeconds: buildsFromSource ? 4 * 3600 : 3600
                )
            ],
            expectsNetwork: true,
            mayRequirePrivilege: needsAdministrator,
            mayRequireRestart: signals.contains(.restartRequired),
            mayChangeUserConfiguration: false,
            verification: [
                VerificationStep(
                    summary: "Read Homebrew's installed versions back and look for \(candidate.availableVersion.raw).",
                    invocation: CommandInvocation(
                        executable: installation.executable.path,
                        arguments: Self.installedInfoArguments
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
            let listing = try await run(Self.installedInfoArguments, installation, context: context)
            guard listing.succeeded else {
                return PlanSupport.unverifiable(
                    candidate.id,
                    expected: expected,
                    because: "`brew info` failed afterwards, so MacUp cannot say which version is installed now."
                )
            }
            var items = try HomebrewInventoryParser.parse(
                listing.standardOutput,
                ownership: nil,
                command: listing.invocation.displayString
            )
            if let prefix = installation.fact("prefix") {
                items.elements = Self.annotate(items.elements, prefix: prefix, fileSystem: context.fileSystem)
            }
            guard let item = items.elements.first(where: { $0.id == candidate.id }) else {
                return PlanSupport.compare(candidate.id, expected: expected, observed: nil)
            }
            return PlanSupport.compare(candidate.id, expected: expected, observed: Self.observedVersion(of: item))
        } catch {
            return PlanSupport.unverifiable(
                candidate.id,
                expected: expected,
                because: MacUpError.wrapping(error, context: "Reading Homebrew's installed versions back").message
            )
        }
    }

    /// The version now in use: the linked keg or installed cask version when
    /// Homebrew names one, then the `opt` link, otherwise the newest keg whose
    /// install finished.
    ///
    /// Several versions can remain installed at once — MacUp deliberately
    /// suppresses Homebrew's cleanup — so "installed" alone would not say
    /// which one an upgrade produced. And an interrupted upgrade leaves an
    /// empty folder named after the new version, which must never read as
    /// the upgrade having worked.
    static func observedVersion(of item: ManagedItem) -> String? {
        if let inUse = versionInUse(item) { return inUse }
        let versions = item.installedVersions.map(\.raw)
        return versions.isEmpty ? nil : HomebrewOutdatedParser.newest(versions)
    }
}
