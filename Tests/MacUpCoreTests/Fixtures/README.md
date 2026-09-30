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

`homebrew/info-installed-uninstall.json` is real `brew info --json=v2
--installed` output (Homebrew 7.0.7), anonymized and cut down to what the
uninstaller reads: three formulae, the `codex` and `redis-insight` casks with
their app targets and `zap` lists exactly as Homebrew printed them, and one
hand-written cask, `example-pkg`, shaped like a cask that installs through an
installer package.
