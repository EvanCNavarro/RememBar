#!/bin/sh
set -eu

APP_PATH="${APP_PATH:-$HOME/Applications/RememBar/RememBar.app}"
APP_EXEC="$APP_PATH/Contents/MacOS/RememBar"
SMOKE_ROOT="${SMOKE_ROOT:-${TMPDIR:-/tmp}/remembar-diagnostics-smoke-$(date +%Y%m%d%H%M%S)-$$}"
DIAGNOSTICS_DIR="${DIAGNOSTICS_DIR:-$SMOKE_ROOT/Diagnostics}"
LOG_PATH="$DIAGNOSTICS_DIR/remembar-diagnostics.jsonl"
STATE_PATH="$DIAGNOSTICS_DIR/session-state.json"
APP_OUTPUT="$SMOKE_ROOT/remembar.out"
app_pid=""

fail() {
  printf 'smoke-remembar-diagnostics: %s\n' "$1" >&2
  exit 1
}

cleanup() {
  terminate_launched_app
}
trap cleanup EXIT INT TERM

terminate_launched_app() {
  [ -n "$app_pid" ] || return 0
  kill -KILL "$app_pid" >/dev/null 2>&1 || true
  wait "$app_pid" 2>/dev/null || true
  app_pid=""
}

wait_for_file() {
  path="$1"
  seconds="$2"
  count=0
  while [ "$count" -lt "$seconds" ]; do
    [ -s "$path" ] && return 0
    sleep 1
    count=$((count + 1))
  done
  return 1
}

line_count() {
  [ -f "$1" ] || {
    printf '0\n'
    return 0
  }
  wc -l < "$1" | tr -d ' '
}

wait_for_log_growth() {
  previous_count="$1"
  seconds="$2"
  count=0
  while [ "$count" -lt "$seconds" ]; do
    current_count="$(line_count "$LOG_PATH")"
    [ "$current_count" -gt "$previous_count" ] && return 0
    sleep 1
    count=$((count + 1))
  done
  return 1
}

launch_app() {
  previous_count="$(line_count "$LOG_PATH")"
  mkdir -p "$SMOKE_ROOT"
  REMEMBAR_DIAGNOSTICS_DIR="$DIAGNOSTICS_DIR" "$APP_EXEC" >"$APP_OUTPUT" 2>&1 &
  app_pid="$!"
  wait_for_file "$LOG_PATH" 8 || fail "diagnostics log was not created; app output: $APP_OUTPUT"
  wait_for_log_growth "$previous_count" 8 || fail "diagnostics log did not advance; app output: $APP_OUTPUT"
  kill -0 "$app_pid" >/dev/null 2>&1 || fail "RememBar process exited early; app output: $APP_OUTPUT"
}

kill_app_uncleanly() {
  terminate_launched_app
}

[ -x "$APP_EXEC" ] || fail "missing app executable at $APP_EXEC"

if pgrep -x RememBar >/dev/null 2>&1; then
  fail "existing RememBar process is running; quit it before smoke testing"
fi

launch_app
grep -q '"name":"diagnostics.session.started"' "$LOG_PATH" || fail "missing launch breadcrumb"
grep -q '"cleanExit":false' "$STATE_PATH" || fail "session state was not marked open"

kill_app_uncleanly
launch_app
grep -q '"name":"diagnostics.previous_session_unclean"' "$LOG_PATH" || fail "missing previous unclean session breadcrumb"
grep -q '"lastEventName":"diagnostics.session.started"' "$LOG_PATH" || fail "unclean breadcrumb did not include last event"

printf 'smoke-remembar-diagnostics: passed using %s\n' "$DIAGNOSTICS_DIR"
