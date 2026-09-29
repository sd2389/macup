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
#   4. scheduling that is not a per-user LaunchAgent running only `macup check`;
#   5. network access anywhere but the opt-in AI transport, or that transport
#      talking to any host but api.typesafe.ai — MacUp's only traffic of its
#      own, and off unless the user turns it on (docs/TRUST_AND_SECURITY.md);
#   6. Keychain access anywhere but the one file that stores the AI key.
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
planning_files='^Sources/MacUpCore/Execution/ModifyingCommandRules\.swift:|^Sources/MacUpCore/Providers/(Homebrew/Homebrew|Npm/Npm|Mise/Mise)UpdatePlan\.swift:'
verbs=$(grep -rnE '"(upgrade|install|reinstall|uninstall|remove|rm|cleanup|autoremove|prune|self-update|use|--install|--download|--bump|--all)"' Sources Apps \
    | grep -vE "$planning_files" || true)
if [[ -n "$verbs" ]]; then
    echo "$verbs" >&2
    fail "modifying provider command found outside the reviewed planning files"
fi

# --bump would move the version the user requested, so it may appear nowhere.
if grep -rn -- '"--bump"' Sources Apps; then
    fail "mise --bump must never appear: it rewrites the user's requested version"
fi

daemons=$(grep -rnE 'LaunchDaemons|"system/|"bootstrap", *"system' Sources Apps || true)
if [[ -n "$daemons" ]]; then
    echo "$daemons" >&2
    fail "scheduling must stay a per-user LaunchAgent; MacUp installs no system daemon"
fi

# The scheduled job may only ever run a read-only check.
if ! grep -q 'var arguments = \["check", "--save-state"\]' Sources/MacUpCore/Scheduling/LaunchAgent.swift; then
    fail "the launchd agent must run only 'macup check --save-state'"
fi

# MacUp's own network traffic is the opt-in AI transport and nothing else:
# every other request MacUp causes is made by a package manager it runs.
transport='^Sources/MacUpCore/AI/TypeSafeTransport\.swift:'
network=$(grep -rnE 'URLSession|NSURLConnection|NWConnection|NWPathMonitor|CFHTTP|CFReadStreamCreate|URLRequest|import Network' Sources Apps \
    | grep -vE "$transport" || true)
if [[ -n "$network" ]]; then
    echo "$network" >&2
    fail "network access found outside Sources/MacUpCore/AI/TypeSafeTransport.swift"
fi
# That transport talks to one host, fixed in code, and checks it on the way
# out and on the way back. TypeSafe's SDKs honor TYPESAFE_BASE_URL; MacUp
# must never let the environment choose where the key is sent.
if ! grep -q 'public static let host = "api.typesafe.ai"' Sources/MacUpCore/AI/TypeSafeWire.swift \
    || ! grep -q 'URL(string: "https://api.typesafe.ai/v1/systemone")!' Sources/MacUpCore/AI/TypeSafeWire.swift \
    || ! grep -q 'guard Self.isPinned(request.url) else' Sources/MacUpCore/AI/TypeSafeTransport.swift \
    || ! grep -q 'Self.isPinned(url) else' Sources/MacUpCore/AI/TypeSafeTransport.swift; then
    fail "the AI transport must send only to https://api.typesafe.ai/v1/systemone and check the host both ways"
fi
if grep -rn 'TYPESAFE_BASE_URL' Sources Apps; then
    fail "MacUp must not let TYPESAFE_BASE_URL redirect where the API key is sent"
fi

# The AI key is read and written in one reviewed place.
keychain=$(grep -rnE 'SecItem(Add|Update|Delete|CopyMatching)' Sources Apps \
    | grep -v '^Sources/MacUpCore/AI/AIKeyStore.swift:' || true)
if [[ -n "$keychain" ]]; then
    echo "$keychain" >&2
    fail "Keychain access found outside Sources/MacUpCore/AI/AIKeyStore.swift"
fi

if [[ $status -eq 0 ]]; then
    echo "Trust invariants hold."
fi
exit $status
