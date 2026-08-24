#!/bin/bash
# Relaunch Chrome so it exposes page content to accessibility.
#
# Chrome keeps its renderer accessibility tree off by default, and — measured
# on this machine — setting AXManualAccessibility does not turn it on:
#
#   normal Chrome                        58 nodes, no AXWebArea
#   --force-renderer-accessibility    1,640 nodes, AXWebArea, 163 links
#
# Without it the app can read Chrome's toolbar and tabs and nothing of the
# page, so there is nothing on GitHub to point at.
#
# This uses your normal profile, so tabs, logins and extensions are unchanged.
# Chrome restores your tabs on relaunch.
#
# Safari needs none of this and can be used instead.
set -euo pipefail

if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  echo "Quitting Chrome (it will restore your tabs)…"
  osascript -e 'quit app "Google Chrome"'
  for _ in $(seq 1 20); do
    pgrep -x "Google Chrome" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "Google Chrome" >/dev/null 2>&1; then
    echo "Chrome is still running — close it by hand, then run this again." >&2
    exit 1
  fi
fi

open -a "Google Chrome" --args --force-renderer-accessibility
echo "Chrome restarted with accessibility enabled."
echo "It stays enabled until you quit Chrome and open it normally again."
