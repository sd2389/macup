# Security Policy

MacUp changes developer environments, so security and user control are core
product requirements. The trust contract and threat model are in
[docs/TRUST_AND_SECURITY.md](docs/TRUST_AND_SECURITY.md).

## Reporting a vulnerability

Please report vulnerabilities privately with GitHub's private vulnerability
reporting: [**Report a vulnerability**](https://github.com/sd2389/macup/security/advisories/new)
(or the repository's **Security** tab, then **Report a vulnerability**). Only
the maintainer can see the report.

Please do not open public issues, discussions, or pull requests about
unpatched vulnerabilities.

A useful report includes what you found, how to reproduce it, the MacUp commit
or version, your macOS version, and the versions of the providers involved
(Homebrew, npm, mise). Remove tokens, usernames, and private paths from logs
before attaching them.

The maintainer will acknowledge your report, keep you informed, and credit you
in the published advisory unless you prefer otherwise. Fixes ship with
regression tests.

## Supported versions

MacUp is pre-release. Security fixes are made on `main`; there are no
maintained release branches yet.

## Scope

Especially in scope:

- anything that makes MacUp change software without the user's authorization,
  or run a command other than the one it shows;
- bypassing the read-only guarantee, the command allowlist, or a saved policy;
- command or argument injection through package names or provider output;
- secrets leaking into output, logs, history, or exported diagnostics;
- PATH or executable-resolution tricks that make MacUp run the wrong binary;
- configuration or history file handling (symlinks, permissions, atomicity).

## Principles

- no arbitrary remote commands
- no hidden privilege escalation
- no shell interpolation of package/provider output
- least privilege
- local-first
- explicit policy enforcement
- signed/notarized releases
- secrets redacted from logs
