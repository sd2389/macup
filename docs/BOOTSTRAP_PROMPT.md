# First prompt to give Claude Code

You are implementing MacUp in this repository.

Treat `CLAUDE.md` as the authoritative specification and read all files in `docs/` before editing code.

Your first assignment is **Phase 0 + Phase 1 only**.

Do not perform real package upgrades on this machine.

Tasks:

1. Inspect the entire current repository and summarize what already exists.
2. Compare it against `CLAUDE.md`.
3. Preserve useful existing code; refactor only where required.
4. Establish the Swift package/core/CLI/test structure.
5. Implement a hardened, mockable command-runner abstraction.
6. Implement the initial domain models.
7. Implement versioned local configuration with atomic writes.
8. Implement read-only Homebrew provider using documented machine-readable output where possible.
9. Implement read-only npm global provider.
10. Implement read-only mise provider.
11. Implement macOS update detection only.
12. Implement concurrent unified `macup check`.
13. Implement `macup check --json`.
14. Add fixture-driven tests for every provider and parser.
15. Add tests proving hostile package names cannot become shell injection.
16. Add/update GitHub Actions CI.
17. Run the complete test suite.
18. Do not run `brew upgrade`, `npm update -g`, `mise upgrade`, `softwareupdate --install`, uninstall, cleanup, or prune commands.
19. Do not push, merge, tag, or release unless explicitly instructed.
20. Finish by reporting:
    - architecture created
    - files changed
    - commands/tests run
    - current test results
    - risks/unknowns
    - exact manual commands I can use to try the read-only CLI

When a provider command or output format is uncertain, verify it against current official documentation or the locally installed tool's `--help`; do not invent syntax.

Do not move on to modifying updates until Phase 1 is reviewed and green.
