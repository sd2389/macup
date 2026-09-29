# Command execution

MacUp launches external programs in exactly one way: `ProcessCommandRunner`,
behind the `CommandRunning` protocol. `scripts/check-trust-invariants.sh`
fails CI if shipping code launches a process any other way or invokes a
shell.

## Guarantees of `ProcessCommandRunner`

- **No shell.** The executable is launched directly with an argument array.
  Package names and provider output travel as single arguments and are
  never interpreted (tests pass `$(…)`, backticks, `;`, `|`, newlines, and
  leading dashes through verbatim).
- **Absolute executable paths only.** Arguments, environment names, and
  values containing NUL are refused before launch.
- **Exact environment.** The child receives only the environment in the
  request; nothing is inherited implicitly.
- **No interactive prompts.** stdin is `/dev/null`.
- **Bounded output.** stdout and stderr are captured separately, capped at
  32 MiB each by default, and can be streamed. A provider command whose
  output was cut off is an error: a truncated listing is never parsed as
  if it were complete.
- **Timeouts and cancellation depend on what the command does.**
  - A read-only command is stopped on timeout or task cancellation: SIGTERM,
    then SIGKILL after a grace period (3 s).
  - A command that changes something (`modifying`, and a metadata refresh)
    is never killed part-way. Cancelling only keeps it from starting; once it
    is running it is left to finish, and the engine starts nothing after it.
    On timeout it receives SIGINT — what Ctrl+C at a terminal sends, which
    package managers are written to recover from — and MacUp waits for it to
    exit, with no SIGKILL behind it.
  - If a grandchild keeps an output pipe open, MacUp stops waiting after 2 s
    and marks the output truncated rather than hang.
- **Results, not exceptions, for exit codes.** A non-zero exit status is
  returned as data; some providers (`npm outdated`) exit 1 on success.
- **Display is separate from execution.** `CommandInvocation.displayString`
  is a shell-quoted rendering for people (ANSI-C quoting makes control
  characters visible). It is never executed or parsed back.

Why a running change is never killed: `brew upgrade` unlinks the old
version before it builds or pours the new one, and links a version again in
its own cleanup. An earlier MacUp sent SIGTERM and then SIGKILL three seconds
later when the user pressed Stop during a from-source build of `mysql`;
Homebrew was killed inside that cleanup, leaving an empty folder for the new
version and neither version linked. A modifying command now always finishes
or, on its time limit, stops itself the way it would at a terminal.

Signals still go to the process MacUp launched rather than its whole process
group, which now matters only for read-only commands: a helper a cancelled
check spawned may take a moment longer to exit. Process groups are tracked
in `docs/IMPLEMENTATION_CHECKLIST.md`.

## Environment allowlist

Every provider starts from a base allowlist and adds only what it needs:

| Policy | Variables passed | Overrides |
| --- | --- | --- |
| Base | `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*` (common), `__CF_USER_TEXT_ENCODING`, `XDG_*_HOME`, proxy variables | `NO_COLOR=1` |
| Homebrew | base + `HOMEBREW_*`, `SSH_AUTH_SOCK` | `HOMEBREW_NO_AUTO_UPDATE=1`, `HOMEBREW_NO_ENV_HINTS=1`, `HOMEBREW_NO_COLOR=1` |
| npm | base + `npm_config_*` (any case), `NODE_EXTRA_CA_CERTS`, `PREFIX`, and any variable referenced as `${NAME}` in `~/.npmrc` or the Node installation's global `etc/npmrc` (npm refuses to start when such a variable is missing), except the execution-altering names below | `npm_config_update_notifier=false`, `npm_config_fund=false`, `npm_config_audit=false` |
| mise | base + `MISE_*`, `GITHUB_TOKEN`, `GITHUB_API_TOKEN` (mise uses them to avoid GitHub rate limits) | — |
| macOS | base | — |

Everything else — `TERM`, `NODE_OPTIONS`, `DYLD_*`, `RUBYOPT`, unrelated
tokens — is withheld. `NODE_OPTIONS`, `NODE_PATH`, `DYLD_*`, `LD_*`,
`BASH_ENV`, `ENV`, `RUBYOPT`, `PERL5OPT`, `PYTHONPATH`, and `PYTHONSTARTUP`
are withheld even when an npmrc file references them. `PATH` is always constructed explicitly (below).
Values are passed to the provider but never logged; logged and displayed
text passes through `Redactor`.

## Executable resolution

`ExecutableResolver` implements ARCHITECTURE.md "Binary resolution":

1. **Configured path** (`providers.<id>.executablePath`), checked exactly
   as written with the same rules as configuration validation. If it is set
   but unusable (empty, relative, padded with spaces, containing control
   characters, missing, or not named after the tool), the provider is
   reported as failed. MacUp never falls back to another copy: that could
   run a binary the user did not choose. A configuration file that other
   users could change is ignored entirely (docs/CONFIGURATION.md), so its
   `executablePath` is never used.
2. **The user's search path.** For the CLI this is the `PATH` MacUp was
   started with — the user's login-shell `PATH`. The app, which inherits
   launchd's minimal `PATH` when launched from Finder, gets it from
   `LoginShellEnvironment` (below).
3. **Standard locations**: `/opt/homebrew/bin/…`, `/usr/local/bin/…`, and
   `~/.local/bin/mise` — but only when the file (after resolving symlinks)
   and every directory above it belong to root or the user and nobody else
   can write them (group write is tolerated for `wheel` and `admin`, whose
   members can already become root). Otherwise the provider is reported as
   failed with the reason, and MacUp suggests adding the directory to
   `PATH` or setting `executablePath` if the user trusts it.

The chosen path and its symlink-resolved canonical path are recorded and
shown (`macup provider list`). Multiple distinct Homebrew installations
(by canonical path) produce a finding.

Special cases:

- `softwareupdate` is always `/usr/sbin/softwareupdate`, never resolved
  through `PATH`.
- npm is a Node script (`#!/usr/bin/env node`), so which `node` runs it
  depends on `PATH`. MacUp picks `node` next to npm, then next to npm's
  symlink target, then on the search path, and records the choice. The
  child `PATH` puts that node's directory first so `/usr/bin/env node`
  finds the same one. A node found elsewhere is flagged.

## Login-shell environment (desktop app)

`LoginShellEnvironment` reads the environment a terminal would have: it runs
the user's login shell (from the account database, and only if listed in
`/etc/shells`; otherwise `/bin/zsh`) as `-l -i -c <fixed script>` in the home
directory, with the base allowlisted environment, `TERM=dumb`, and
`MACUP_RESOLVING_ENVIRONMENT=1` (so dotfiles can skip slow work). The script
runs the shell's prompt hooks first — zsh `precmd_functions`, bash
`PROMPT_COMMAND`, fish `fish_prompt` handlers — because tools such as mise
update `PATH` there, then prints `env -0` between markers built from a
per-run nonce. Startup-file noise around the markers is ignored.

This is the only shell `-c` in MacUp (the trust-invariants check enforces
that): nothing but the nonce is inserted, the output is parsed and never
executed, and the captured environment is never logged. It runs once per
app launch with a 10 second timeout; if it fails, the app falls back to its
own environment plus standard locations and says so in Doctor.

## PATH hijacking considerations

- Empty and relative `PATH` entries (including `.`, which an empty entry
  also means) are dropped: resolving tools relative to the current
  directory would let any checked-out project shadow `brew` or `npm`.
- Entries containing control characters are dropped.
- Child processes get a constructed `PATH`: the provider's own directory
  first, then the sanitized user search path (npm, mise), then system
  directories. Homebrew gets only its own directory and system directories.
- Standard locations are not on every user's `PATH` (`/opt/homebrew/bin` is
  added by each user's shell profile), so MacUp only runs a copy there when
  root or the user controls it; see rule 3 above.
- Remaining risk: a malicious executable placed earlier in the user's own
  `PATH` (for example a writable `~/.local/bin`) would be used, exactly as
  the user's shell would use it. MacUp shows the path it chose; Doctor
  (Phase 4) should flag provider binaries in directories writable by other
  users.

## The read-only guard

Every request declares its effect: `readOnly`, `metadataRefresh`, or
`modifying`. During `macup check` and `macup provider list`, all commands
pass through `ReadOnlyCommandGuard`, which:

- refuses anything `modifying`;
- refuses `metadataRefresh` unless `--refresh` was given;
- refuses any command not in `CommandAllowlist.readOnlyCheck`, matched by
  executable name, leading arguments, and an exact set of allowed options
  (so positional arguments such as package names cannot be appended).
  Asking what depends on one formula (`macup dependents`) adds
  `CommandAllowlist.dependentsLookup`, whose `brew uses` rules take exactly
  one checked name; a check never has those rules.

Refused commands never reach the operating system; they are recorded in
the report with outcome `refused`. A test runs a deliberately misbehaving
provider that attempts `brew upgrade git` during a check and asserts the
guard stops it.

The same guard is used for every read-only operation, not only a check:
planning hands providers a runner wrapped in it (with the metadata refresh
switched off), and so does locating a provider before a plan runs.

## The modifying guard

A modifying command passes through `ExecutionGuard` instead, which is
stricter in a different direction: it allows positional arguments, because a
modifying command has to name what it changes, and then requires both that
the command appear in the plan the user reviewed and that it match one of the
reviewed shapes in `ModifyingCommandRules`.

The two allowlists exist for different jobs, which is why there are two.
`docs/ARCHITECTURE.md` ("Two allowlists") explains the split and what each
one is protecting against; `docs/PROVIDER_NOTES.md` lists the four modifying
shapes and where each was confirmed.
