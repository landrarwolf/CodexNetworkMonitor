#!/bin/zsh
set -euo pipefail
TASK_SOURCE="${0:A:h}"
# File Provider adds Finder metadata to test bundles under Documents, which breaks codesigning.
TASK_SCRATCH="${1:-${TMPDIR:-/private/tmp}/codex-network-monitor-tests}"
TASK_SCRATCH="${TASK_SCRATCH:A}"
source "$TASK_SOURCE/scripts/toolchain.zsh"
TASK_PLUGIN="${TASK_SWIFT:h:h}/lib/swift/host/plugins/testing"
TASK_PLUGIN_FLAGS=()
if [[ -d "$TASK_PLUGIN" ]]; then
    TASK_PLUGIN_FLAGS=(-Xswiftc -plugin-path -Xswiftc "$TASK_PLUGIN")
fi
"$TASK_SWIFT" test --package-path "$TASK_SOURCE" --scratch-path "$TASK_SCRATCH" --cache-path "$TASK_SCRATCH/cache" --config-path "$TASK_SCRATCH/config" --security-path "$TASK_SCRATCH/security" --disable-sandbox --disable-xctest "${TASK_PLUGIN_FLAGS[@]}"
