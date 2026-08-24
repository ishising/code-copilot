#!/bin/bash
# Build the bundle, then launch it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

"$ROOT/bundle.sh" "${1:-debug}"

# Quit any running copy first. `open` on an already-running app just focuses
# the existing instance — it does not load the binary that was just built — so
# without this you rebuild, relaunch, and watch the old bug happen again.
if pgrep -x CodeCopilot >/dev/null 2>&1; then
  osascript -e 'quit app "Code Copilot"' >/dev/null 2>&1 || pkill -x CodeCopilot || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x CodeCopilot >/dev/null 2>&1 || break
    sleep 0.3
  done
  echo "  quit the previous instance"
fi

open "$ROOT/build/CodeCopilot.app"
echo "  launched"
