# Test Plan

## Principle

Automated tests must not upgrade the host Mac.

## Unit tests

### Policy
- item override beats provider
- provider beats global
- ignore blocks plan
- ask cannot be silently scheduled
- auto allowed only under applicable risk rules
- unknown risk becomes ask
- corrupted config disables automatic modification

### Command runner
- arguments remain separate
- package strings cannot inject shell syntax
- timeout
- cancellation
- stdout/stderr
- non-zero exit
- environment override
- executable not found
- log redaction

### Homebrew parser
Fixtures:
- formula updates
- cask updates
- both
- none
- pinned
- malformed JSON
- schema additions
- Unicode names/descriptions
- failure

### npm parser
Fixtures:
- scoped packages
- multiple packages
- none
- non-zero + valid JSON
- malformed output
- permission error
- npm itself
- package current newer than registry latest

### mise parser
Fixtures:
- exact pin
- fuzzy major
- multiple tools
- inactive
- local/global distinction
- malformed JSON

### macOS parser
Fixtures for supported `softwareupdate` output forms.
Parsing ambiguity must produce an error/finding rather than fabricated state.

### Planning
- exact command details
- high/unknown risk
- excluded item absent
- pin behavior
- provider disabled
- plan stale/policy changed before execution

### Verification
- target reached
- target not reached
- command succeeded but verification failed
- executable disappeared

## Integration tests

Use fake provider binaries or temporary scripts returning fixture outputs.

Test complete:
check -> candidate -> policy -> plan -> mock execution -> verification -> history

## UI tests

Critical flows:
- first launch
- no providers
- updates available
- ignore item
- Ask First item
- plan review
- execution success
- partial failure
- Doctor finding
- scheduling settings

## Security tests

Try hostile item names:
- spaces
- quotes
- semicolon
- `$()`
- backticks
- newline
- Unicode
- leading dash

Confirm they are passed as arguments and never interpreted by a shell.

## Release smoke test

On a clean test Mac:
- install
- launch
- CLI help
- check
- GUI check
- policy persistence
- dry run
- controlled update of a safe disposable test package
- history
- uninstall/remove scheduler
