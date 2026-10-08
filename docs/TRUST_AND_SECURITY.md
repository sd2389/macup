# Trust and Security

## Trust Contract

MacUp publicly commits to:

1. No hidden changes.
2. Read-only means no package/runtimes are modified.
3. Users can inspect a change before execution.
4. MacUp does not store admin passwords.
5. MacUp uses existing package managers instead of replacing them.
6. Saved exclusions/policies are enforced at execution time.
7. Major/unknown/high-risk changes require review.
8. Local inventory stays local by default.
9. Telemetry is off unless the user opts in.
10. Core behavior is open source.
11. Modification attempts are logged.
12. Rollback claims are capability-specific and truthful.
13. Ambiguity causes MacUp to stop/skip rather than guess.
14. MacUp runs only the commands it showed you.

Items 3, 6, 7, 11, 13, and 14 used to be descriptions of intent. They are now
properties of the code, and "Before MacUp changes anything" below says which
type enforces each one. Where a promise and a mechanism disagree, the
mechanism is what the user actually gets, so the mechanism is what is
documented.

## Before MacUp changes anything

MacUp can now modify the machine. This section is the part of the document
that matters most, because everything above it is a promise and this is the
mechanism.

Every one of the following must hold before a single modifying command is
launched. Any one of them failing is a skip with a reason, never a guess.

1. **The configuration could be read.** Not "read approximately" — read
   without errors.
2. **The provider is enabled** in that configuration.
3. **The provider does not pin the item** itself.
4. **Policy allows it**, resolved per-item, then per-provider, then global.
5. **Risk does not raise the bar** past what policy granted. An `auto` item
   whose change is a macOS update, needs an administrator, needs a restart,
   would rewrite a config file or lockfile, is a major runtime change, or
   whose risk MacUp could not judge, still waits for a person.
6. **There is a plan**, built by the owning provider, carrying the exact
   executable and argument array.
7. **Policy still allows it**, re-read from the file immediately before the
   command runs.
8. **A `confirm` decision was actually confirmed**, by a caller that had
   somebody there to confirm it.
9. **The command is in that plan** — same executable, same arguments, same
   effect.
10. **The command matches a reviewed modifying rule.**
11. **The owning provider is loaded and locatable**, so MacUp knows what
    environment the command needs and can read the result back.
12. **The plan gives every step a usable time limit.**

Nothing in this list is enforced by convention. Items 1 to 5 are
`PolicyEngine`; 7 and 8 are the execution engine's own re-check; 9 and 10 are
`ExecutionGuard` and `ModifyingCommandRules`; 11 and 12 are the execution
engine refusing to run a plan it cannot carry out faithfully.
`docs/ARCHITECTURE.md` describes how they fit together.

### Policy is read again, immediately before the command

The plan a user reviewed was built from a copy of the configuration. That
copy can be minutes old. So the execution engine re-reads the configuration
file and re-asks the policy engine for every item, immediately before that
item runs (CLAUDE.md §2.20).

Planning-time policy is not enough, and the reason is ordinary rather than
exotic. A user reviews a list of twenty updates, notices one they do not
want, excludes it, and then confirms the batch. A scheduled run's plan may
have been written before the user changed a rule. In both cases the rule they
have now is the one that should win, and the only way to be sure of that is
to read it now. An exclusion that only applied at the moment a list was
generated would not be an exclusion; it would be a filter on a screen.

The re-check is the decisive one, not a second opinion. If the file now says
`ignore`, the item is skipped even though it is sitting in an approved plan.

### An unreadable configuration allows nothing

If MacUp cannot read its configuration file without errors, every policy
decision is `deny`.

This is not caution for its own sake. **The rules saying which items are
excluded are exactly the rules it could not read.** A configuration MacUp
misparsed might contain `"brew:postgresql": {"policy": "ignore"}` — and
falling back to a permissive default would then upgrade the one package the
user was most careful about. Failing closed is the only reading of a
half-understood file that cannot betray its author.

The same reasoning applies in the other direction, to writing. `PolicyEditor`
refuses to save a configuration that has errors, because MacUp writes the
file by re-encoding what it understood; rewriting a file it misread could
drop the exclusions the user is relying on. See `docs/CONFIGURATION.md`.

A file that other local users could change is a separate and stronger case:
it is ignored entirely, built-in defaults apply, and automatic modification
stays off. A file MacUp does not control cannot be allowed to choose which
executables MacUp runs.

### A provider-pinned item is never unpinned

When a provider itself holds an item back — `brew pin` is the case that
exists today — the policy decision is `deny`, whatever the MacUp policy says,
and the Homebrew planner refuses to build a plan for it as well.

A pin is a decision the user already made, in another tool, deliberately.
MacUp could technically unpin, upgrade, and re-pin. It does not, because the
user would have no way to know that happened, and the whole point of MacUp is
that nothing happens to your machine that you could not have predicted from
what MacUp showed you. If you want the upgrade, unpin it yourself; MacUp will
then plan it like anything else.

MacUp's own `pin` policy is a separate, weaker thing: a MacUp-level "hold at
the current version" that MacUp honors. It does not touch the provider's pin
state in either direction.

### A failure stops the run short of high-risk changes

Items run one at a time. A step that does not succeed ends that item — the
later steps of a plan were written assuming the earlier ones worked.

A failure also changes what the *rest of the run* is willing to do: from that
point on, any remaining item whose risk is `high` or `unknown` is skipped,
with that as the reason. This is not a blanket abort, which would be worse
for a batch of small patch updates; it is narrower and better justified than
that. After a failure MacUp no longer knows the state of the machine as well
as it did when the plans were written. The plans still on the list were
described against a machine that has since half-changed. Carrying on through
the changes that would be hardest to unpick, on a description MacUp can no
longer vouch for, is exactly the guessing the trust contract forbids
(CLAUDE.md §2.23, §24 Phase 3).

Low and moderate risk items continue, because MacUp can still say what they
are. A caller that wants the stricter behavior can ask for it
(`stopOnFailure`), and cancellation stops the run outright.

### Rollback is reported as unavailable, not promised

Every plan MacUp builds today reports rollback as **unavailable**, with the
explanation that MacUp has no tested rollback strategy for that action.

The model has three states — available, unavailable, unknown — and the
honest answer is currently the middle one for every action, so that is what
is reported. It would be easy to write something that usually works:
`brew upgrade` leaves the old keg on disk, npm can install a named older
version, mise keeps previous runtimes. None of those are rollback. They do
not restore linked binaries, rebuilt dependents, migrated data directories,
or a lockfile that has already been rewritten, and a user who read the word
"rollback" would reasonably expect all of that.

Rule 22 of the trust contract exists so that the day MacUp does say
"available", it means a specific provider action with an implemented and
tested strategy behind it — not a general reassurance. Until then the field
says unavailable, which is information, rather than unknown, which would be
an evasion.

### What history records, and what it refuses to record

History is a trust feature, not a log (CLAUDE.md §16). It is the record that
makes everything above checkable after the fact, so it is held to the
configuration file's rules.

It records, one JSON object per line in `~/.local/state/macup/history.jsonl`:

- when, and where the run came from — CLI, app, or scheduled
- the item and its provider
- the version before, the version the plan targeted, and the version MacUp
  observed afterwards — read back, with a read-only command, after a success
  and after an attempt that started a command and did not succeed, together
  with anything else that read-back showed, such as a formula left unlinked
- the exact commands as they were displayed to the user
- the outcome, and the verification outcome
- an error summary when something failed
- how long it took
- **every skip, with its reason.** An item MacUp decided not to change is
  part of what it did, and the reason is the useful half. An audit log that
  only listed successes would answer the least interesting question.

It refuses to record:

- passwords, tokens, authorization headers, and secrets from the
  environment. Entries are redacted as the engine builds them and redacted
  again by the store, so a caller that forgets cannot put a secret in the
  audit log.
- a dry run. Nothing was attempted, so there is nothing to record.
- an entry it cannot encode, or one containing a line break, which would
  silently split into two unreadable lines.
- a guess about a line it cannot read back. Undecodable lines are counted and
  reported as a finding, never interpreted.

The file itself is treated as owner-only data: created `0600` inside a `0700`
directory, opened `O_NOFOLLOW` relative to an opened directory descriptor so
it is never written through a symlink or into a directory somebody else could
change, checked to be a regular file MacUp owns, and `fsync`ed. Trimming to
the entry limit replaces the file by atomic rename, so a crash during a trim
cannot lose the entries it was keeping.

History that could not be written is reported to the system log and does not
abort the run. Refusing to update because a log file is unwritable would be a
worse answer than an incomplete log — but the failure is never silent.

## Threat model

Assets:
- user's developer environment
- executable search path
- package-manager configuration
- shell/runtime configuration
- credentials present in environment
- local filesystem
- administrator authorization
- trust in signed MacUp releases

Threats:
- command injection via package names/provider output
- PATH hijacking
- malicious or compromised upstream package
- parser confusion causing wrong target
- policy race/change between planning and execution
- accidental privilege escalation
- logging secrets
- corrupted configuration changing policy
- compromised update distribution
- symlink/path attacks on writable files
- malicious project-local config affecting global maintenance
- remote command capability introduced later

Mitigations:
- argument arrays, no shell interpolation
- explicit executable path
- provider output validation
- two command allowlists: one bounding what a check may run, one bounding
  what an update may run
- an execution guard that additionally refuses any command not in the plan
  the user reviewed
- positional arguments checked, not trusted: no leading `-`, no control or
  bidirectional-override characters, and an exact count so an upgrade can
  never be launched naming nothing
- policy re-check before execute
- one item at a time; no overlapping modifications
- local-first
- atomic config
- strict file permissions where appropriate
- log redaction, applied twice on the path into history
- signed/notarized release
- checksums
- dependency minimization
- no root daemon
- no remote arbitrary command schema

## Doctor

Doctor answers "why does this machine behave the way it does". Eleven
deterministic checks read the result of one read-only check and say what they
saw; none of them is a model, a heuristic score, or a repair.

Three properties are the trust-relevant ones.

**It changes nothing, and it offers to change nothing.** Doctor explains. It
has no fix action, not even an opt-in one, because a diagnostic that also
repairs is a diagnostic you cannot run to find out what is going on.

**It issues exactly one command**: reading the user's login shell, so it can
say whether MacUp sees the same `PATH` a terminal does. That goes through the
same `CommandRunning` abstraction as everything else, with effect
`readOnly`, and the captured environment is compared and then dropped rather
than logged or stored. Everything else — architectures, ownership, directory
permissions — is read from bytes or from `stat`, never from a subprocess. Two
tests pin this: one asserts Doctor records no commands at all when the shell
reader is stubbed, the other that every command it does record is read-only.

**A fact MacUp does not have becomes a finding that says so**, never a
guess. An architecture MacUp cannot interpret is reported as undetermined and
produces no finding at all. A launchd state it could not ask about is
reported as unknown rather than as running. A directory it could not inspect
is reported as unknown rather than as safe. Provider output it could not
parse is reported as unparsed rather than as a partial list.

Findings carry stable, namespaced identifiers (for example
`homebrew.multipleInstallations`, `paths.directoryWritableByOthers`) because
scripts will match on them, and they are ordered deterministically — most
severe first, then by identifier, then title, then detail — so two runs over
one machine produce the same output.

Severity is a judgment rather than decoration. A provider that is not
installed is information: most Macs do not have all four. A directory another
user can write is an error, because it decides what MacUp is allowed to
change. A `PATH` missing directories the login shell has is a warning,
because a tool living only there is one MacUp will not find; a `PATH` with
extra directories is information, because that is what running from an
editor's terminal looks like.

Everything that reaches a finding is redacted and sanitized first: provider
output is untrusted input, the home directory becomes `~` so a pasted report
carries no username, and no finding ever prints an environment variable's
value. A test plants `GITHUB_TOKEN`, `AWS_SECRET_ACCESS_KEY`, and
`NODE_OPTIONS` in the environment and asserts that no finding contains their
values.

## Exported diagnostics

Export Diagnostics (`macup diagnostics`, and Settings → Diagnostics in the
app) is the one place MacUp's local inventory is packaged to leave the Mac,
so it is held to the privacy rules (CLAUDE.md §2.15, §16, §18) by mechanism
rather than by care:

- **It is an explicit action with a preview.** `preview` and the app's sheet
  show the exact bytes before anything is written; both come from one
  rendering of one look at the Mac, so what was shown is what is saved.
  MacUp never sends the file anywhere.
- **Fields are chosen, not inherited.** `DiagnosticsDocument` lists every
  field it writes. A property added to a model later does not reach the file
  until someone adds it there, and every string passes through one scrubber:
  `Redactor`, the home folder as `~`, the account name on its own as `<user>`,
  control and bidirectional characters escaped.
- **No environment variables.** Nothing from the process or login-shell
  environment is copied in; only Doctor's findings, which can name folders on
  `PATH`. Tests plant tokens and a custom variable and assert neither their
  values nor the custom name appear.
- **Package names are placeholders by default**, because what someone has
  installed can identify their employer, their projects, or an outdated
  version worth attacking. Placeholders are numbered by first mention, so a
  number reveals nothing about names the file never shows; free text is
  masked too, including cask display names, npm scopes, and third-party taps.
  The one exception is MacUp's own vocabulary — the runtimes and package
  managers its source recognizes by name — because Doctor's findings are
  written in those terms and they identify nobody. Versions are kept; they
  are what most bug reports are about. Item notes are never included. The
  names and bundle identifiers of apps MacUp uninstalled are masked the same
  way, because a skip reason or an error can name them.
- **The file is new or it is nothing.** It is created with `O_CREAT |
  O_EXCL | O_NOFOLLOW` relative to an opened folder, owner-only (`0600`,
  `fchmod`ed past the umask), and removed if writing fails part-way. An
  existing file is never replaced and a symbolic link at the destination —
  even a dangling one — is refused. The folders above it are the user's
  choice. The CLI's default is the current directory rather than the Desktop,
  which iCloud Drive may sync.

## Uninstalling

An uninstall is the one thing MacUp does that removes files, so it carries
every rule an update carries and a few of its own (ADR-022):

- **Reviewed and confirmed.** Nothing is removed without a plan the person saw
  and confirmed; the package manager's commands are exact argument arrays
  from the uninstall rules in `ModifyingCommandRules`, and never `--zap`,
  `--ignore-dependencies`, `autoremove`, or `cleanup`.
- **Trash first, chosen each time.** Move to Trash or Delete Permanently is
  asked for every uninstall and starts at the Trash; a permanent deletion is
  confirmed again with its count and size.
- **Data is opt-in.** App data, formula data, and name-only matches are never
  ticked for the person.
- **Only planned paths, checked again.** The guarded remover removes only what
  the confirmed plan lists, re-checks each path immediately before removing
  it, removes a symbolic link as a link, and refuses anything outside the
  allowed folders or at the top of one (the home folder, `~/Library`, a
  top-level Library folder, the Trash, `/System`, `/usr`, `/bin`, `/sbin`).
  `scripts/check-trust-invariants.sh` keeps removal calls in that one place.
- **An app's claims are not taken at their word.** A bundle identifier is
  whatever the app's `Info.plist` says. One with fewer than three parts
  (`com`, `com.google`) is not used to find files at all, because names that
  start with it belong to other apps too; one in Apple's namespace
  (`com.apple.…`) finds files but ticks none of them, because macOS keeps its
  own settings under such names. The plan says which applied.
- **A cask's `zap` list is bounded.** Patterns are expanded in code, never by
  a shell, never with `**`, and never through a link. A wildcard must be tied
  to the app: after the folders many apps share (`~/Library/Preferences`, its
  `ByHost` folder, `Logs/DiagnosticReports`, the home folder's standard
  folders, Apple's `com.apple.…` folders), the next name must be literal or
  start with the cask's token, the app's name or bundle identifier, or a
  three-part reverse-DNS name — and a name that is the start of every app's
  identifier (`com`, `org`, `com.google`) is not accepted as the cask's own,
  because Homebrew constrains neither the token nor the name.
  `~/Library/Preferences/*` is listed as left in place instead of expanded. No
  wildcard is expanded anywhere inside your own document folders — iCloud
  Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`) and
  `~/Library/CloudStorage` — whatever literal folder it is anchored on;
  nothing is removed inside them at any depth either, so the pattern and the
  removal boundary agree about them. What a wildcard matched is ticked only
  when the file's own name says it is the app's: a wildcard's anchor says
  where MacUp looked, not whose files it found. Anything else is still shown,
  unticked, with that reason. An exact path the cask wrote out is ticked as
  before. A folder the cask removes only when empty
  (`rmdir`) is removed only if it is empty — apart from Finder's `.DS_Store` —
  when MacUp reaches it, and one holding files the cask does not list is
  never offered, not even by "include everything".
- **Never into another disk.** A folder with another disk mounted inside it is
  listed as left in place, and a folder deleted permanently is walked again
  first; if MacUp cannot check all of it, or finds a mount, it is skipped.
- **No administrator.** What needs one is listed with manual steps, never
  removed. Because of that, `/Library` and the installer receipts are read by
  wider rules than `~/Library`: the bundle identifier, the maker's part of it
  (`com.teamviewer` in `com.teamviewer.TeamViewer`, how an installer names its
  own helpers, daemons, and receipts), and a folder named exactly like the
  app. The plan says which rule found each one, the two weaker rules say to
  check it first, and anything another installed app's identifier or name
  claims is left to that app. An app in `/Applications` that an installer put
  there as root is described as that, not as another person's.
- **Stops for the obvious reasons.** An open app, a formula others need, or an
  unreadable configuration stops the uninstall; scheduled runs cannot
  uninstall at all.
- **Tests never touch real files.** Every uninstall test runs over a pretend
  Mac in a temporary folder with a fake Trash.

Known limit: the last check and the removal are two steps by path, not one
step through an open folder handle. A program running as the same user could
swap a folder for a link in between. MacUp accepts this because such a
program can already remove anything the user can, so it gains nothing by
steering MacUp; MacUp never runs as another user or as root.

## Privilege

The main process runs as the user.

Scheduling does not change that. `macup schedule enable` installs a per-user
LaunchAgent in `~/Library/LaunchAgents`, loaded into the user's own launchd
domain (`gui/<uid>`). There is no `LaunchDaemon`, no root, no privilege
helper, no authorization prompt, and no process running between runs. The
scheduled job runs as you and is removable by you: `macup schedule disable`
unloads it and deletes the property list, and `macup schedule status` shows
the exact command that would run, so an installed schedule is never something
you have to take on trust.

The scheduled job runs one of exactly two commands. By default it is
`macup check --save-state`, which cannot install, upgrade, or remove anything.
When you ask for it with `macup schedule enable --install-updates` it is
`macup update --scheduled` instead, which installs only the items whose rule
is Auto Update: Ask First items wait for you, ignored and pinned items are
never touched, a plan that may need a password or a restart is refused, and a
Mac that asks the owner to approve every change installs nothing on a schedule
(ADR-023). `scripts/check-trust-invariants.sh` fails the build if the agent
could be given any other command, or any argument beyond `--refresh`, and
`macup schedule status` names which of the two is installed.


Updates do not change that either. MacUp never uses `sudo` and holds no
password. Where a change may genuinely need one — a Homebrew cask that
installs through a macOS installer package is the case that exists — the plan
says so before it runs, the prompt comes from Homebrew and macOS rather than
from MacUp, and MacUp neither supplies nor stores an answer. If a global npm
prefix is not the user's to write, npm fails and says so; MacUp does not
escalate to make it work.

An unattended run refuses such a plan outright. Nobody is there to answer an
authorization prompt, and a scheduled job that sat waiting on one would be
worse than a scheduled job that skipped and explained. The same rule covers
anything that may require a restart.

When an operation legitimately needs authorization:
- explain why
- let macOS present standard authorization
- never collect the password in MacUp UI
- avoid custom privilege helpers until a separately reviewed need exists

## Approval, and what it is not

MacUp can require the device owner's approval before it changes anything
(`macup security require on`, or Settings → Approval). macOS does the asking
through `LocalAuthentication`, with whatever sensor the Mac reports — Touch
ID, Face ID, or Optic ID — and the login password or an unlocked Apple Watch
as the fallback. MacUp passes a reason string it wrote itself and receives a
yes or a no. It never sees, stores, or transmits a fingerprint, a face, or a
password, which is the same rule as rule 9 of the trust contract.

It is deliberately described as a confirmation, never as a lock:

- MacUp runs as the user. Anyone at an unlocked Mac can run `brew`, `npm`, or
  `mise` directly, with no prompt from anyone.
- The configuration file is the user's own file and can be edited to turn the
  requirement off. MacUp does not defend against its owner.
- There is no secret for the OS to withhold: v1 has no account, no tokens, and
  no cloud, so there is nothing to put behind a Keychain access-control list,
  which is where macOS would really enforce biometrics.

What it does buy is one deliberate step in front of every change MacUp itself
makes, enforced in one place (`ApprovalGate`) for the CLI and the app alike,
so a future modifying action cannot quietly skip it. Approval that MacUp could
not obtain is a refusal, not a pass.

### The camera face match

MacUp does include a face check of its own, off by default, and it is
documented here rather than advertised, because it is not security.

macOS exposes no face-recognition API: Vision finds *a* face in a picture and
does not tell you whose. What MacUp does is crop to the face and compare
Vision image feature prints — a measure of how alike two pictures look. A
photograph of the enrolled person passes it. There is no Secure Enclave, no
liveness check, and no macOS enforcement behind it.

It is constrained so that it cannot be mistaken for a lock:

- It can only approve early. A face that does not match falls through to the
  macOS prompt rather than refusing, so it can never lock anyone out, and it
  never replaces the macOS check as the only way through.
- It reports `cameraFace`, never `faceID`, so what approved a change is always
  distinguishable from a hardware sensor in the UI, the logs, and `--json`.
- It does nothing unless approval is also required; the validator warns when
  it is on and inert.
- What is stored is a list of numbers derived from the pictures, owner-only in
  the state directory. No image is kept, nothing leaves the Mac, and the
  camera is open only for the moment of capture, recording light on.
- Enrolment reports how far apart the enrolled samples of one face are, so the
  threshold can be judged rather than trusted. When the spread is wider than
  the threshold, MacUp says matching cannot work.

If this feature were ever presented as protecting anything, that would be
misrepresentation. It is a convenience for its owner, on their own machine,
and every surface that shows it says so.

## Remote architecture rule

If cloud/team functionality exists later, the server may express declarative desired state/policy, never arbitrary shell commands.

Allowed concept:
```json
{"tool":"node","policy":"pin","version":"24"}
```

Forbidden concept:
```json
{"command":"curl https://example | sudo sh"}
```

## Release security

Before public v1:
- Developer ID signature
- Apple notarization
- SHA-256 checksums
- GitHub protected release workflow
- documented build steps
- security reporting process
- dependency lock/review
- no secrets in repository or CI logs

## Incident principle

If MacUp causes or risks destructive behavior:
- stop release/update distribution if necessary
- disclose concrete scope
- provide remediation
- do not minimize impact
- add regression tests before restoring affected functionality
