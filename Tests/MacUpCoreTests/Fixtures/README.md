# Provider output fixtures

Captured or hand-written provider output used by parser tests.

Rules:
- Fixtures are shaped like real output from the provider versions noted in
  each test. Real captures are anonymized: home directories become
  `/Users/example` and nothing identifies a real machine or person.
- Tests never run provider binaries. They feed these files to parsers or
  serve them from a fake command runner.
- Add a fixture before (or with) any parser change.
