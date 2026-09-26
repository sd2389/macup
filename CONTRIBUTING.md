# Contributing

Thank you for contributing to MacUp.

## Before a PR

- read `CLAUDE.md`
- read `docs/TRUST_AND_SECURITY.md`
- add/update tests
- do not make provider checks mutate user packages
- do not add shell interpolation
- do not add telemetry or networking unrelated to provider behavior without design review

## Provider contributions

A new provider must include:
- detection
- read-only inventory/outdated behavior
- machine-readable parsing where possible
- fixture tests
- execution-plan design
- verification strategy
- capability declaration
- trust/security notes

Do not add a provider solely by invoking a blanket “upgrade everything” command.

## PR quality

Explain:
- problem
- approach
- trust/security impact
- tests
- manual verification

## Security issues

Do not report vulnerabilities in public issues or pull requests. See
[SECURITY.md](SECURITY.md) for private reporting.

## Code of conduct

Everyone taking part in MacUp is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
