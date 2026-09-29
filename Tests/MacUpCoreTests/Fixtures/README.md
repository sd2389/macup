# Provider output fixtures

Captured or hand-written provider output used by parser tests.

Rules:
- Fixtures are shaped like real output from the provider versions noted in
  each test. Real captures are anonymized: home directories become
  `/Users/example` and nothing identifies a real machine or person.
- Tests never run provider binaries. They feed these files to parsers or
  serve them from a fake command runner.
- Add a fixture before (or with) any parser change.

`history/` holds history lines exactly as earlier versions of MacUp wrote
them, so a change to `HistoryEntry` is tested against what is already on
people's disks. `before-read-back.jsonl` predates the after-state MacUp now
reads back after an unsuccessful attempt; its last line is a real entry from
an upgrade that was stopped part-way, anonymized.

`typesafe/` holds TypeSafe System One replies shaped like the documented
examples (https://docs.typesafe.ai/api.md), plus malformed ones MacUp must
refuse. They are written by hand: no test has an API key, and none ever
reaches the network.
