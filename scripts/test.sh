#!/bin/bash
# Runs the test suite. Extra arguments are passed to `swift test`.
#
# With only the Command Line Tools installed (no Xcode), SwiftPM does not find
# the Swift Testing macro plugin on its own; point the compiler at it. Full
# Xcode installations and CI need no extra flags.
set -euo pipefail

extra_flags=()
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    plugin_dir="$developer_dir/usr/lib/swift/host/plugins/testing"
    if [[ -d "$plugin_dir" ]]; then
        extra_flags+=(-Xswiftc -plugin-path -Xswiftc "$plugin_dir")
    fi
fi

exec swift test --force-resolved-versions ${extra_flags[@]+"${extra_flags[@]}"} "$@"
