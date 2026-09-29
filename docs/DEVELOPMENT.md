# Development

## Requirements

- macOS 14 or later
- Xcode 16.3 or later, or the matching Command Line Tools (Swift 6.1+).
  The package itself needs Swift 6.0; the tests use Swift Testing features
  from 6.1.

## Build and run

```bash
swift run macup --help
```

The `Makefile` wraps the common tasks: `make install`, `make uninstall`,
`make test`, and `make app`.

## Desktop app

```bash
scripts/build-app.sh          # builds build/MacUp.app (release); pass "debug" for developer tooling
open build/MacUp.app
```

Until Xcode is installed, the app is a SwiftPM library target
(`MacUpAppCore`, at `Apps/MacUpApp/MacUpApp`) plus a one-line executable
target (`MacUpApp`, at `Apps/MacUpApp/Main`), wrapped into an ad-hoc signed
bundle that runs on this Mac only. The Xcode project will compile the same
folder. `scripts/build-app.sh` also copies the `macup` CLI to
`Contents/Helpers/macup`, so the app and the CLI it schedules can never be
different versions.

To review the UI from a script (no Screen Recording permission needed),
debug builds accept `--snapshot-dir`: the app runs a check, renders every
screen in light and dark mode plus Settings to PNG files, and quits. The
directory must be private to you (created owner-only if missing); a shared
location such as `/tmp/macup-shots` is refused, because another local user
could read the screenshots or plant symlinks there.

```bash
scripts/build-app.sh debug
open -n build/MacUp.app --args --snapshot-dir "$(mktemp -d)"
```

### The camera face match cannot capture in a local build

This is a property of how the bundle is signed, not a bug, so it is written
down rather than rediscovered.

Without a certificate, `scripts/build-app.sh` signs the bundle **ad-hoc**
(`codesign --sign -`), and a build tool cannot create a certificate for you. An ad-hoc signature carries no team identifier, so macOS
has no developer to attribute the app to — and macOS will not grant camera
access to a bundle it cannot attribute. It never presents the prompt,
`AVCaptureDevice.authorizationStatus` stays `notDetermined`, and the capture
connection never goes live.

So the face match cannot capture in a locally built MacUp: **it never asks,
and the connection never opens.** No amount of clicking in System Settings
changes that, and what macOS reports about access is not evidence the camera
will work — this build was observed being told access was granted and still
never getting a live connection. The signature is what MacUp checks, not the
access status. The signing identifier is pinned to the bundle identifier,
which is as far as this can be improved without a certificate; the
signature's hash still changes on every build, so macOS could not remember a
decision even if it made one.

Because it is settled rather than intermittent, both surfaces say so:

- the app's **Features** screen states it where someone would meet it, and
  the enrol button is not offered;
- `MacUp --face-check` (debug builds) leads with the same words, from the
  same `CameraReadiness` value, so a diagnostic run and the screen can never
  tell different stories.

The way out for a local build is a signing identity that names a team.
`scripts/build-app.sh` now uses one automatically when this Mac has one: an
**Apple Development** certificate, free with an Apple ID (Xcode > Settings >
Accounts > your Apple ID > Manage Certificates > + > Apple Development), or a
Developer ID Application certificate. `MACUP_SIGNING_IDENTITY` picks one
explicitly. The script says which way it signed. A team-named signature is
what `CameraReadiness` looks for, and the one macOS needs before it will ask;
it has not yet been verified end to end on this Mac, which has no certificate.
Without one the build stays ad-hoc and everything above still holds.
Distribution is still the signing and notarization in `docs/RELEASE.md`.
Everything else in the app — including the approval prompt through
`LocalAuthentication` — works in a local build.

## Test

```bash
scripts/test.sh
```

`scripts/test.sh` wraps `swift test`. With only the Command Line Tools
installed, SwiftPM does not find the Swift Testing macro plugin by itself, so
the script passes its location to the compiler. With full Xcode (and in CI)
plain `swift test` works.

Filter with any `swift test` option, for example
`scripts/test.sh --filter ProcessCommandRunner`.

## Static trust checks

```bash
scripts/check-trust-invariants.sh
```

Fails if shipping sources invoke a shell or launch processes outside
`ProcessCommandRunner`, if a scheduled job is anything but a per-user
LaunchAgent running `macup check --save-state`, or if `mise --bump` appears
anywhere at all.

It also fails if a modifying provider verb appears outside the four files
allowed to name one: `ModifyingCommandRules.swift`, and one planning file per
provider. The check used to ban those verbs everywhere, which was correct
while MacUp could change nothing; now it confines them to the files where a
command has been reviewed, and still fails for the CLI, the app, discovery,
and scheduling.

CI runs it on every push and pull request.

## Layout

```text
Sources/MacUpCore/        Core library shared by the CLI and the app
  Configuration/          Paths, config schema, validation, atomic storage
  Diagnostics/            Doctor: the report, and one type per check
  Discovery/              Concurrent check engine and the check report
  Execution/              CommandRunner, environment allowlist, executable
                          resolution, read-only guard and allowlist,
                          modifying-command rules, execution guard,
                          execution engine, recording
  History/                The JSONL history store
  Models/                 Domain models (IDs, versions, candidates, plans…)
  Planning/               The update planner and the plan report
  Policy/                 Policy engine, editor, and listing
  Providers/              Homebrew, npm, mise, macOS adapters, parsers, and
                          each provider's own planning and verification
  Scheduling/             The launchd user agent and the scheduler
  Security/               Approval gate, biometrics, camera face match
  Utilities/              Redaction, terminal-safe text, JSON, file system
Sources/macup/            The `macup` CLI (argument parsing and output only)
Apps/MacUpApp/MacUpApp/   MacUpAppCore: the SwiftUI desktop app as a library,
                          so its model can be tested (uses MacUpCore only)
Apps/MacUpApp/Main/       The MacUpApp executable's entry point — one line
Tests/MacUpCoreTests/     Core tests; Fixtures/ holds provider output samples
Tests/MacUpCLITests/      CLI parsing, output, and exit-code tests
Tests/MacUpAppTests/      App model tests (imports MacUpAppCore)
Tests/MacUpTestSupport/   Fakes shared by the test targets
scripts/                  Test and CI helpers
```

The app is a library plus a one-line entry point rather than a single
executable, because a test target cannot import an executable and the app's
model decides real things: whether a check may start, whether a change is
approved, what the menu bar is allowed to claim. `AppModel` takes an
`AppEnvironment` instead of building its own command runner, file system,
authenticator, and camera, and `AppEnvironment.live()` supplies exactly what
it used to build for itself — so the shipping path is the one it always was.
The file layout under `Apps/MacUpApp/MacUpApp/` did not change.

## Rules that tests enforce

- Tests never run provider binaries (`brew`, `npm`, `node`, `mise`,
  `softwareupdate`). Provider behavior is tested with fixtures and
  `FakeCommandRunner`, which throws on any command a test did not register.
- `ProcessCommandRunner` tests launch only harmless system tools (`printf`,
  `echo`, `env`, `sleep`, `dd`, `pwd`, `cat`) and throwaway scripts in a
  temporary directory.
- `Tests/MacUpCoreTests/Integration` runs the real runner against stub
  executables generated in a temporary directory; standard locations are
  overridden so the real tools can never be picked up.
- CLI tests use a temporary `MACUP_CONFIG_DIR`, so they never read your
  real configuration.
- No test runs a modifying provider command. The execution engine is tested
  against a scripted provider and a fake runner, so the plans it carries out
  exist only in the test.
- `Tests/MacUpAppTests/HostIsolationTests.swift` asserts the golden rule
  directly: no test opens a camera, shows an authentication prompt, runs a
  provider command, installs a launchd agent, or touches the real config and
  state directories.
- A passing test suite must not alter the host development environment.
