#!/usr/bin/env bash
#
# demo-update.sh — replay the REAL Sparkle update flow on demand, safely.
#
# Builds a test copy of RememBar labeled an OLDER version (default 0.1.0) into a SCRATCH dir — never
# ~/Applications (the real install) — pointing at the real GitHub appcast feed, then launches it with
# the auto-check hook so Sparkle shows the genuine flow (available → download → Install and Relaunch)
# against the real published release. Installing simply lands the test copy on the current release;
# your real install is never touched.
#
# Usage:
#   scripts/demo-update.sh [version]         # default version 0.1.0
#   REMEMBAR_DEMO_DIR=/path scripts/demo-update.sh
#   REMEMBAR_DEMO_NOLAUNCH=1 scripts/demo-update.sh   # build only, don't launch (for tests)
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_VERSION="${1:-0.1.0}"
SCRATCH_DIR="${REMEMBAR_DEMO_DIR:-${TMPDIR:-/tmp}/remembar-update-demo}"

# Hard guard: never build the demo into a real install location.
case "$SCRATCH_DIR" in
    "$HOME/Applications"* | /Applications*)
        echo "refusing to build the demo into a real install location: $SCRATCH_DIR" >&2
        exit 1
        ;;
esac

rm -rf "$SCRATCH_DIR"
mkdir -p "$SCRATCH_DIR"

echo "Building RememBar $DEMO_VERSION (test copy) into $SCRATCH_DIR …"
APP_PATH="$(REMEMBAR_VERSION="$DEMO_VERSION" REMEMBAR_DIST_DIR="$SCRATCH_DIR" \
    "$PROJECT_DIR/scripts/build-remembar-app.sh" | tail -1)"
echo "Built: $APP_PATH"

if [ -n "${REMEMBAR_DEMO_NOLAUNCH:-}" ]; then
    echo "REMEMBAR_DEMO_NOLAUNCH set — skipping launch."
    exit 0
fi

echo "Launching with auto-check — Sparkle will show the real update flow …"
REMEMBAR_AUTOCHECK=1 "$APP_PATH/Contents/MacOS/RememBar" &
echo "Launched (pid $!). Click through: Install Update → download → Install and Relaunch."
echo "This test copy lives in $SCRATCH_DIR and never touches your ~/Applications install."
