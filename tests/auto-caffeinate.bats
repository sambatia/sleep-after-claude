#!/usr/bin/env bats
# Auto-start caffeinate -dim behavior.

load 'lib/common'

setup() {
  setup_sandbox
  # Extract the function + its config.
  {
    echo 'AUTO_STARTED_CAFFEINATE_PID=""'
    echo 'NO_AUTO_CAFFEINATE=false'
    sed -n '/^ensure_caffeinate_running() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } > "$BATS_TEST_TMPDIR/ensure.sh"
  [ -s "$BATS_TEST_TMPDIR/ensure.sh" ]
}

@test "ensure_caffeinate: no-op when --no-auto-caffeinate" {
  run bash -c "
    BOLD='' DIM='' GREEN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    source '$BATS_TEST_TMPDIR/ensure.sh'
    # Set AFTER sourcing — the sourced file re-initializes the default.
    NO_AUTO_CAFFEINATE=true
    ensure_caffeinate_running
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "DONE"
  assert_not_contains "$output" "Started"
  assert_not_contains "$output" "caffeinate already running"
}

@test "ensure_caffeinate: leaves existing caffeinate alone" {
  shim pgrep 'echo 99999; exit 0'  # pretend something is already running
  run bash -c "
    NO_AUTO_CAFFEINATE=false
    BOLD='' DIM='' GREEN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { :; }
    export PATH='$SHIM_DIR:'\$PATH
    source '$BATS_TEST_TMPDIR/ensure.sh'
    ensure_caffeinate_running
    echo DONE
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "caffeinate already running"
  assert_not_contains "$output" "Started"
}

@test "ensure_caffeinate: starts caffeinate when none running" {
  shim pgrep 'exit 1'                 # none found
  shim caffeinate 'sleep 30; exit 0'  # a fake caffeinate that just sleeps
  run bash -c "
    NO_AUTO_CAFFEINATE=false
    BOLD='' DIM='' GREEN='' RESET=''
    print_ok() { echo \"OK \$1\"; }
    log_event() { echo \"log: \$1\"; }
    export PATH='$SHIM_DIR:'\$PATH
    source '$BATS_TEST_TMPDIR/ensure.sh'
    ensure_caffeinate_running
    echo \"pid=\$AUTO_STARTED_CAFFEINATE_PID\"
  " 2>&1
  [ "$status" -eq 0 ]
  assert_contains "$output" "Started"
  assert_contains "$output" "log: AUTO_CAFFEINATE_STARTED"
  # Cleanup the fake caffeinate we spawned
  pkill -f 'sleep 30' 2>/dev/null || true
}
