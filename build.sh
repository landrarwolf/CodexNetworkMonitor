#!/bin/zsh
set -euo pipefail
TASK_SOURCE="${0:A:h}"
# Keep signing away from File Provider folders; publish only generated artifacts in dist/.
TASK_SCRATCH="${1:-${TMPDIR:-/private/tmp}/codex-network-monitor-build}"
TASK_SCRATCH="${TASK_SCRATCH:A}"
source "$TASK_SOURCE/scripts/toolchain.zsh"
TASK_FLAGS=(--package-path "$TASK_SOURCE" --scratch-path "$TASK_SCRATCH" --cache-path "$TASK_SCRATCH/cache" --config-path "$TASK_SCRATCH/config" --security-path "$TASK_SCRATCH/security" --disable-sandbox)
"$TASK_SWIFT" build "${TASK_FLAGS[@]}" -c release
TASK_BIN_DIR="$("$TASK_SWIFT" build "${TASK_FLAGS[@]}" -c release --show-bin-path)"
TASK_APP="$TASK_SCRATCH/app-stage/Codex Network Monitor.app"
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources"
cp "$TASK_BIN_DIR/CodexNetworkMonitor" "$TASK_APP/Contents/MacOS/CodexNetworkMonitor"
cp "$TASK_SOURCE/Info.plist" "$TASK_APP/Contents/Info.plist"
chmod +x "$TASK_APP/Contents/MacOS/CodexNetworkMonitor"
# File Provider may add FinderInfo metadata if the caller chooses a synced scratch directory.
if /usr/bin/xattr -p com.apple.FinderInfo "$TASK_APP" > /dev/null 2>&1; then
    /usr/bin/xattr -px com.apple.FinderInfo "$TASK_APP" > "$TASK_SCRATCH/app-FinderInfo.hex"
    /usr/bin/xattr -d com.apple.FinderInfo "$TASK_APP"
fi
/usr/bin/codesign --force --sign - "$TASK_APP"
/usr/bin/codesign --verify --strict "$TASK_APP"
TASK_ARCH="$(/usr/bin/lipo -archs "$TASK_APP/Contents/MacOS/CodexNetworkMonitor")"
mkdir -p "$TASK_SOURCE/dist"
/usr/bin/ditto --norsrc --noextattr "$TASK_APP" "$TASK_SOURCE/dist/Codex Network Monitor.app"
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$TASK_APP" "$TASK_SOURCE/dist/CodexNetworkMonitor-macOS-$TASK_ARCH.zip"
print -r -- "$TASK_SOURCE/dist/CodexNetworkMonitor-macOS-$TASK_ARCH.zip"
