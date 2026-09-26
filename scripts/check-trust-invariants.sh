#!/bin/bash
# Static checks for MacUp's trust contract (CLAUDE.md §2). Scans shipping
# sources only (Sources/ and Apps/). Fails when it finds:
#   1. shell invocation (sh -c, system(), popen(), AppleScript) — except the
#      login-shell environment probe, which runs the user's own shell with a
#      fixed script (see Sources/MacUpCore/Execution/LoginShellEnvironment.swift);
#   2. process launching outside ProcessCommandRunner;
#   3. modifying provider verbs — MacUp is read-only until Phase 3 adds an
#      execution engine, at which point this rule moves to that engine's files.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
fail() {
    echo "error: $1" >&2
    status=1
}

shells=$(grep -rnE '"/bin/(ba|z|k|c|tc)?sh"|"(ba|z|k)?sh", *"-c"|"-c",|[^A-Za-z_.]system\(|popen\(|NSAppleScript|NSUserAppleScriptTask' Sources Apps \
    | grep -v '^Sources/MacUpCore/Execution/LoginShellEnvironment.swift:' || true)
if [[ -n "$shells" ]]; then
    echo "$shells" >&2
    fail "shell invocation found (use CommandRunner with an argument array)"
fi

launches=$(grep -rnE '(^|[^A-Za-z_.])Process\(\)|posix_spawn|NSTask' Sources Apps \
    | grep -v '^Sources/MacUpCore/Execution/ProcessCommandRunner.swift:' || true)
if [[ -n "$launches" ]]; then
    echo "$launches" >&2
    fail "external processes must be launched through ProcessCommandRunner"
fi

if grep -rnE '"(upgrade|install|reinstall|uninstall|remove|rm|cleanup|autoremove|prune|self-update|use|--install|--download|--bump|--all)"' Sources Apps; then
    fail "modifying provider command found during the read-only phases"
fi

if [[ $status -eq 0 ]]; then
    echo "Trust invariants hold."
fi
exit $status
