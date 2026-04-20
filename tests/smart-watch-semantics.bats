#!/usr/bin/env bats
# F-01 + F-08 regression tests — smart_watch_loop busy-dir semantics.
#
# These tests don't run the full watch loop (it polls forever); they
# source smart_watch_loop's internals and unit-test the specific
# decision points that the audit identified as broken.

load 'lib/common'

setup() {
  setup_sandbox
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
  export SMART_IDLE_SECONDS=30
  export SMART_STALE_MARKER_MINS=1440
  # Extract the two functions under test + their color-var deps.
  {
    echo 'BUSY_DIR="'"$BUSY_DIR"'"'
    echo 'SMART_IDLE_SECONDS='"$SMART_IDLE_SECONDS"
    echo 'SMART_STALE_MARKER_MINS='"$SMART_STALE_MARKER_MINS"
    sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/cbs.sh"
  [ -s "$BATS_TEST_TMPDIR/cbs.sh" ]
}

@test "F-01: smart_watch_loop source guards 'cold start' before declaring idle" {
  # Source-level contract: seen_busy must be initialized and consulted.
  run grep -n 'seen_busy=' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # The idle-check branch must require seen_busy == true.
  run grep -n '\[\[ "\$seen_busy" == true \]\]' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-01: smart_watch_loop emits 'Waiting for a Claude prompt' when cold" {
  # The cold-start branch must tell the user what's happening.
  run grep 'Waiting for a Claude prompt' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-08: stale-marker threshold is configurable via SAC_STALE_MARKER_MINUTES" {
  run grep -E 'SAC_STALE_MARKER_MINUTES' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # Default should be 24h (1440 minutes), not 120 minutes.
  run grep -E 'SMART_STALE_MARKER_MINS=.*:-1440' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-08: count_busy_sessions uses \$SMART_STALE_MARKER_MINS (not hardcoded 120)" {
  run grep -E 'find "\$BUSY_DIR".*-mmin \+"\$SMART_STALE_MARKER_MINS"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # And the old hardcoded 120-minute value must be gone from the reaper line.
  run grep -E 'find "\$BUSY_DIR".*-mmin \+120 -delete' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -ne 0 ]
}

@test "F-08: fresh marker is NOT reaped when threshold is 24h" {
  mkdir -p "$BUSY_DIR"
  touch "$BUSY_DIR/fresh-session"
  run bash -c "source '$BATS_TEST_TMPDIR/cbs.sh'; count_busy_sessions"
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/fresh-session" ]
}

@test "F-08: a marker 12h old is NOT reaped when threshold is 24h" {
  mkdir -p "$BUSY_DIR"
  touch "$BUSY_DIR/long-running"
  # Backdate by 12h
  touch -t "$(date -v-12H +%Y%m%d%H%M)" "$BUSY_DIR/long-running" 2>/dev/null
  run bash -c "source '$BATS_TEST_TMPDIR/cbs.sh'; count_busy_sessions"
  [ "$output" = "1" ]
  [ -f "$BUSY_DIR/long-running" ]
}

@test "F-08: a marker 48h old IS reaped (stale beyond default threshold)" {
  mkdir -p "$BUSY_DIR"
  touch "$BUSY_DIR/crashed-session"
  touch -t "$(date -v-48H +%Y%m%d%H%M)" "$BUSY_DIR/crashed-session" 2>/dev/null
  run bash -c "source '$BATS_TEST_TMPDIR/cbs.sh'; count_busy_sessions"
  [ "$output" = "0" ]
  [ ! -f "$BUSY_DIR/crashed-session" ]
}
