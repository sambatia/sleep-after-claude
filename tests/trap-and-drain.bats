#!/usr/bin/env bats
# F-11 + F-12 regression tests.

load 'lib/common'

@test "F-12: on_interrupt no longer calls cleanup_fd_and_tmp directly" {
  # The EXIT trap handles cleanup. Calling it again from on_interrupt
  # is idempotent today but fragile. The post-fix source must NOT
  # invoke cleanup_fd_and_tmp from inside on_interrupt.
  run awk '/^on_interrupt\(\) \{/,/^\}$/' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
  # The function body should NOT contain a direct call to
  # cleanup_fd_and_tmp (it's run via the EXIT trap).
  run bash -c "awk '/^on_interrupt\(\) \{/,/^\}\$/' '$REPO_ROOT/sleep-after-claude' | grep -c '^[^#]*cleanup_fd_and_tmp'"
  [ "$output" = "0" ]
}

@test "F-12: EXIT trap for cleanup_fd_and_tmp is still registered" {
  run grep -E 'trap cleanup_fd_and_tmp EXIT' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-11: installer drain is bounded by a 5s timeout" {
  run grep -E '(gtimeout|timeout) 5 cat' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "F-11: installer drain has a fallback for systems without timeout(1)" {
  # Source-level: the fallback branch uses a background cat + watchdog
  # kill.
  run grep 'sleep 5 && kill' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}
