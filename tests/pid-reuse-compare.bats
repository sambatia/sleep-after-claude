#!/usr/bin/env bats
# F-10 regression tests — PID-reuse detection must compare only the
# binary path, not the full argv string, to avoid false-positives on
# legitimate argv mutation (setproctitle, exec -a).

load 'lib/common'

# The binary-extraction primitive used at both TARGET_BIN computation
# and inside the watch-loop comparison.
extract_bin() {
  echo "$1" | awk '{print $1}'
}

@test "F-10: binary extraction returns first whitespace-separated token" {
  run extract_bin "/usr/local/bin/claude --dangerously-skip-permissions"
  [ "$status" -eq 0 ]
  [ "$output" = "/usr/local/bin/claude" ]
}

@test "F-10: argv mutation with same binary does NOT indicate PID reuse" {
  before="$(extract_bin "/usr/local/bin/claude --dangerously-skip-permissions")"
  after="$(extract_bin "/usr/local/bin/claude writing some long prompt that changed")"
  [ "$before" = "$after" ]
}

@test "F-10: different binary path DOES indicate PID reuse" {
  before="$(extract_bin "/usr/local/bin/claude --foo")"
  after="$(extract_bin "/bin/sleep 30")"
  [ "$before" != "$after" ]
}

@test "F-10: empty current command (process exited) is not a reuse signal" {
  # The watch loop guards: `if [[ -n "$CURRENT_BIN" && ... ]]` — an
  # empty current command must not trigger the reuse branch.
  current=""
  current_bin="$(extract_bin "$current")"
  [ -z "$current_bin" ]
}

@test "F-10: watch-loop guard in source code uses binary compare, not full argv" {
  # Belt-and-suspenders: assert the fix is still present in the source.
  # If someone reverts to full-argv compare, this test catches it.
  run grep -n 'CURRENT_BIN' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  assert_contains "$output" "CURRENT_BIN"
  # And the old full-string comparison must be gone.
  run grep -c 'CURRENT_CMD" != "\$TARGET_CMD_FULL"' "$REPO_ROOT/sleep-after-claude"
  [ "$output" -eq 0 ]
}
