# Development

## Requirements

- macOS 14 or later
- Xcode 16.3 or later, or the matching Command Line Tools (Swift 6.1+).
  The package itself needs Swift 6.0; the tests use Swift Testing features
  from 6.1.

## Build and run

```bash
swift build
.build/debug/macup --help
```

## Desktop app

```bash
scripts/build-app.sh          # builds build/MacUp.app (debug); pass "release" for a release build
open build/MacUp.app
```

Until Xcode is installed, the app is a SwiftPM executable target
(`Apps/MacUpApp/MacUpApp`) wrapped into an ad-hoc signed bundle that runs
on this Mac only. The Xcode project will compile the same folder.

To review the UI from a script (no Screen Recording permission needed),
debug builds accept `--snapshot-dir`: the app runs a check, renders every
screen in light and dark mode plus Settings to PNG files, and quits.

```bash
open -n build/MacUp.app --args --snapshot-dir /tmp/macup-shots
```

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

Fails if shipping sources invoke a shell, launch processes outside
`ProcessCommandRunner`, or contain modifying provider commands. CI runs it on
every push and pull request.

## Layout

```text
Sources/MacUpCore/        Core library shared by the CLI and (later) the app
  Configuration/          Paths, config schema, validation, atomic storage
  Discovery/              Concurrent check engine and the check report
  Execution/              CommandRunner, environment allowlist, executable
                          resolution, read-only guard and allowlist, recording
  Models/                 Domain models (IDs, versions, candidates, plans…)
  Providers/              Homebrew, npm, mise, macOS adapters and parsers
  Utilities/              Redaction, terminal-safe text, JSON, file system
Sources/macup/            The `macup` CLI (argument parsing and output only)
Apps/MacUpApp/MacUpApp/   The SwiftUI desktop app (uses MacUpCore only)
Tests/MacUpCoreTests/     Core tests; Fixtures/ holds provider output samples
Tests/MacUpCLITests/      CLI parsing, output, and exit-code tests
Tests/MacUpTestSupport/   Fakes shared by the test targets
scripts/                  Test and CI helpers
```

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
- A passing test suite must not alter the host development environment.
