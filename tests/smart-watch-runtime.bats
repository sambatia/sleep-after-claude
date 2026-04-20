#!/usr/bin/env bats
# Runtime tests for smart_watch_loop. These actually drive the poll
# loop with a scripted BUSY_DIR and assert on observable outcomes.
# Source-level contract tests live in tests/smart-watch-semantics.bats;
# this file is pure behavior.
#
# Speed strategy: override SMART_IDLE_SECONDS to 2s so the loop
# returns promptly.

load 'lib/common'

setup() {
  setup_sandbox
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
  mkdir -p "$BUSY_DIR"
  {
    echo 'BUSY_DIR="'"$BUSY_DIR"'"'
    echo 'SMART_IDLE_SECONDS=2'
    echo 'SMART_STALE_MARKER_MINS=1440'
    echo 'USE_SPINNER=false'
    echo 'BOLD="" DIM="" GREEN="" YELLOW="" CYAN="" RESET=""'
    echo 'print_ok()   { echo "OK $1"; }'
    echo 'clear_line() { :; }'
    sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^smart_watch_loop() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/loop.sh"
  [ -s "$BATS_TEST_TMPDIR/loop.sh" ]
}

@test "F-01 runtime: empty BUSY_DIR at start does NOT trigger sleep (cold-start)" {
  # Reproduces the original Critical bug: no marker ever appears. The
  # loop must NOT hit "All Claude sessions idle" within a bounded
  # wait. We verify by running the loop for a fixed duration and
  # asserting the idle-success message never appears.
  :>"$BATS_TEST_TMPDIR/output"
  bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    smart_watch_loop
    echo LOOP_RETURNED
  " >"$BATS_TEST_TMPDIR/output" 2>&1 &
  local loop_pid=$!
  sleep 5
  kill "$loop_pid" 2>/dev/null || true
  wait "$loop_pid" 2>/dev/null || true
  run cat "$BATS_TEST_TMPDIR/output"
  # The idle-success log must NOT have fired.
  assert_not_contains "$output" "All Claude sessions idle for"
  # And the loop must NOT have returned normally within the window.
  assert_not_contains "$output" "LOOP_RETURNED"
  # The cold-state message must have appeared (either spinner or
  # non-TTY variant). Match on the common substring "Claude prompt".
  assert_contains "$output" "Claude prompt"
}

@test "F-01 runtime: busy marker then removal DOES trigger sleep" {
  # Happy path: prompt submitted (marker present), Claude responds
  # (marker removed), loop detects idle transition and returns.
  touch "$BUSY_DIR/session-1"
  (sleep 1 && rm -f "$BUSY_DIR/session-1") &
  local cleanup_pid=$!
  run bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    smart_watch_loop
    echo LOOP_RETURNED
  "
  wait "$cleanup_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  assert_contains "$output" "All Claude sessions idle for 2s"
  assert_contains "$output" "LOOP_RETURNED"
}

@test "F-01 runtime: entry with pre-existing marker counts as seen_busy" {
  # If a marker already exists when the loop starts, seen_busy is
  # seeded true — loop doesn't stay in cold state.
  touch "$BUSY_DIR/pre-existing"
  (sleep 1 && rm -f "$BUSY_DIR/pre-existing") &
  local cleanup_pid=$!
  run bash -c "
    source '$BATS_TEST_TMPDIR/loop.sh'
    smart_watch_loop
    echo LOOP_RETURNED
  "
  wait "$cleanup_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  assert_contains "$output" "All Claude sessions idle"
  assert_contains "$output" "LOOP_RETURNED"
}
