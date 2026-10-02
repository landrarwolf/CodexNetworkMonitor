#!/bin/zsh
set -euo pipefail
TASK_SOURCE="${0:A:h:h}"
TASK_APP="$TASK_SOURCE/dist/Codex Network Monitor.app/Contents/MacOS/CodexNetworkMonitor"
if [[ ! -x "$TASK_APP" ]]; then
    print -u2 -- 'Run zsh build.sh first.'
    exit 1
fi
mkdir -p "$TASK_SOURCE/docs/screenshots"
for TASK_SCENE in healthy proxy; do
    "$TASK_APP" --demo "$TASK_SCENE" --render-preview "$TASK_SOURCE/docs/screenshots/$TASK_SCENE.png"
done
print -r -- 'Screenshots use synthetic demo data. Visually review them before publishing.'
