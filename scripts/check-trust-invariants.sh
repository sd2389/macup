#!/bin/bash
# Static checks for MacUp's trust contract (CLAUDE.md §2). Scans shipping
# sources only (Sources/ and Apps/). Fails when it finds:
#   1. shell invocation (sh -c, system(), popen(), AppleScript) — except the
#      login-shell environment probe, which runs the user's own shell with a
#      fixed script (see Sources/MacUpCore/Execution/LoginShellEnvironment.swift);
#   2. process launching outside ProcessCommandRunner;
#   3. modifying provider verbs anywhere but the four files that plan them —
#      one rules file and one planning file per provider, so a modifying
#      command can only be named where it has been reviewed;
#   4. scheduling that is not a per-user LaunchAgent running only `macup check`.
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

# Only these files may name a modifying provider verb: the one reviewable
# list of allowed commands, and the one planning file per provider. Every
# other file — the CLI, the app, discovery, scheduling — must not.
# The uninstall plan files are the same kind of file as the update plan files:
# each provider's one reviewed place for the commands an uninstall runs.
planning_files='^Sources/MacUpCore/Execution/ModifyingCommandRules\.swift:|^Sources/MacUpCore/Providers/(Homebrew/Homebrew|Npm/Npm|Mise/Mise)(Update|Uninstall)Plan\.swift:'
# Two uses of the word that are not commands: the uninstall report's document
# kind, and the words History search matches for an uninstall entry.
not_commands='^Sources/MacUpCore/Uninstall/UninstallEngine\.swift:[0-9]+:.*kind|^Sources/MacUpCore/History/HistoryFilter\.swift:[0-9]+:.*fields \+='
verbs=$(grep -rnE '"(upgrade|install|reinstall|uninstall|remove|rm|cleanup|autoremove|prune|self-update|use|--install|--download|--bump|--all)"' Sources Apps \
    | grep -vE "$planning_files" | grep -vE "$not_commands" || true)
if [[ -n "$verbs" ]]; then
    echo "$verbs" >&2
    fail "modifying provider command found outside the reviewed planning files"
fi

# --bump would move the version the user requested, so it may appear nowhere.
if grep -rn -- '"--bump"' Sources Apps; then
    fail "mise --bump must never appear: it rewrites the user's requested version"
fi

# The uninstaller may name the system's launch daemon folder in one file, only
# to read it and tell the user what to remove by hand; that file must never be
# able to run anything.
daemons=$(grep -rnE 'LaunchDaemons|"system/|"bootstrap", *"system' Sources Apps \
    | grep -v '^Sources/MacUpCore/Uninstall/SystemLeftovers\.swift:' || true)
if grep -nE 'CommandRunning|CommandRequest|runner|launchctl", *\[' Sources/MacUpCore/Uninstall/SystemLeftovers.swift; then
    fail "SystemLeftovers.swift may only read /Library and describe manual steps; it must not run commands"
fi
if [[ -n "$daemons" ]]; then
    echo "$daemons" >&2
    fail "scheduling must stay a per-user LaunchAgent; MacUp installs no system daemon"
fi

# MacUp itself opens no network connection (CLAUDE.md §18): only the package
# managers it runs do. A release link is opened by the user's browser, and the
# opt-in AI help that once needed a connection was removed by the owner.
network=$(grep -rnE 'URLSession|NWConnection|NWPathMonitor|URLRequest|CFStream|CFSocket|NSURLConnection' Sources Apps || true)
if [[ -n "$network" ]]; then
    echo "$network" >&2
    fail "network code found: MacUp makes no network request of its own"
fi

# The scheduled job may only ever run a read-only check.
if ! grep -q 'var arguments = \["check", "--save-state"\]' Sources/MacUpCore/Scheduling/LaunchAgent.swift; then
    fail "the launchd agent must run only 'macup check --save-state'"
fi

if [[ $status -eq 0 ]]; then
    echo "Trust invariants hold."
fi
exit $status
