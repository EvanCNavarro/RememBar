#!/usr/bin/env bash
#
# test-packaged-app.sh — prove a freshly PACKAGED RememBar.app launches without crashing on a machine
# that is NOT the build machine.
#
# Why the theatrics: Bundle.module's generated accessor has a hardcoded absolute .build path baked in
# at compile time. On the build machine that path resolves, so a locally-built .app can appear healthy
# even when a required resource was never packaged into Contents/Resources — while the SAME code from
# CI crashes on every other machine (0.3.0 shipped exactly this bug). To catch it, we move the local
# .build resource bundle aside so the baked-in path CANNOT mask a packaging gap, then launch.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/remembar-packaged-test"
FAIL=0
say()  { printf '  %s\n' "$1"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

echo "→ building release .app…"
rm -rf "$WORK"; mkdir -p "$WORK"
APP="$(CONFIGURATION=release REMEMBAR_VERSION="0.0.0-test" REMEMBAR_DIST_DIR="$WORK" \
  "$PROJECT_DIR/scripts/build-remembar-app.sh" | tail -1)"
[ -d "$APP" ] || { fail "build produced no .app"; exit 1; }

echo "→ no source touches Bundle.module outside the DEBUG-guarded helper…"
# The invariant that broke 0.3.0: release code must NEVER reference Bundle.module (its accessor
# fatalErrors when the SPM bundle isn't packaged). Only BundleResources.swift may, and only inside
# its own #if DEBUG. Any other hit is a latent crash-on-launch.
STRAY="$(grep -rn "Bundle\.module" "$PROJECT_DIR/Sources" 2>/dev/null | grep -v "BundleResources.swift" || true)"
if [ -z "$STRAY" ]; then pass "no stray Bundle.module references"; else fail "Bundle.module used outside the DEBUG helper:"; echo "$STRAY" | sed 's/^/      /'; fi

echo "→ required resources are packaged into Contents/Resources…"
for res in RememBarAppIcon.png RememBar.icns RememBarMenuGlyph.pdf; do
  if [ -f "$APP/Contents/Resources/$res" ]; then pass "$res present"; else fail "$res MISSING from Contents/Resources"; fi
done

echo "→ launching with the baked-in Bundle.module build path neutralized (simulates any other Mac)…"
# Move every local SPM resource bundle aside so Bundle.module's hardcoded fallback cannot resolve.
STASH="$WORK/stashed-bundles"; mkdir -p "$STASH"; i=0
while IFS= read -r b; do
  [ -n "$b" ] || continue
  mv "$b" "$STASH/$i.bundle"; echo "$b" > "$STASH/$i.path"; i=$((i+1))
done < <(find "$PROJECT_DIR/.build" -name "RememBar_BrowserMemoryBar.bundle" 2>/dev/null)
restore_bundles() { for p in "$STASH"/*.path; do [ -f "$p" ] || continue; mv "$STASH/$(basename "$p" .path).bundle" "$(cat "$p")"; done; }
trap restore_bundles EXIT

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
BEFORE="$(ls -1 "$CRASH_DIR"/RememBar-* 2>/dev/null | wc -l | tr -d ' ')"
"$APP/Contents/MacOS/RememBar" >/dev/null 2>&1 &
PID=$!
ALIVE=0
for _ in $(seq 1 8); do            # ~4s: the crash fires within ~2s of launch
  kill -0 "$PID" 2>/dev/null || break
  ALIVE=1; sleep 0.5
done
# Definitive signals: process still alive after the window AND no fresh crash report.
sleep 0.5
AFTER="$(ls -1 "$CRASH_DIR"/RememBar-* 2>/dev/null | wc -l | tr -d ' ')"
if kill -0 "$PID" 2>/dev/null; then
  pass "app still running after launch (no crash)"
  kill "$PID" 2>/dev/null
else
  [ "$ALIVE" = "1" ] && fail "app launched then exited early (likely crash)" || fail "app never came up"
fi
if [ "$AFTER" -gt "$BEFORE" ]; then fail "a new RememBar crash report was written during launch"; else pass "no new crash report"; fi

restore_bundles; trap - EXIT
[ "$FAIL" = "0" ] && echo "✔ packaged app launches clean on a foreign machine" || echo "✘ packaged-app test FAILED"
exit "$FAIL"
