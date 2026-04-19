#!/usr/bin/env bats
# F-04 regression tests for scripts/check-parity.sh.
#
# The embedded payload inside install-sleep-after-claude.sh must stay
# byte-identical to the standalone sleep-after-claude script. These
# tests verify the parity guard succeeds on the current repo and fails
# on induced drift.

load 'lib/common'

setup() {
  setup_sandbox
}

@test "F-04: parity check passes on the committed tree" {
  run bash "$REPO_ROOT/scripts/check-parity.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "check-parity: OK"
}

@test "F-04: parity check fails when embedded payload drifts" {
  # Work in an isolated copy so we don't mutate the real repo.
  cp -R "$REPO_ROOT/sleep-after-claude" \
        "$REPO_ROOT/install-sleep-after-claude.sh" \
        "$REPO_ROOT/scripts" \
        "$BATS_TEST_TMPDIR/"
  mkdir -p "$BATS_TEST_TMPDIR/fake-repo/scripts"
  cp "$REPO_ROOT/sleep-after-claude"             "$BATS_TEST_TMPDIR/fake-repo/sleep-after-claude"
  cp "$REPO_ROOT/install-sleep-after-claude.sh"  "$BATS_TEST_TMPDIR/fake-repo/install-sleep-after-claude.sh"
  cp "$REPO_ROOT/scripts/check-parity.sh"        "$BATS_TEST_TMPDIR/fake-repo/scripts/check-parity.sh"

  # Induce drift: append a harmless comment line to the standalone copy.
  echo "# drift-induced-by-test" >> "$BATS_TEST_TMPDIR/fake-repo/sleep-after-claude"

  run bash "$BATS_TEST_TMPDIR/fake-repo/scripts/check-parity.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "FAILED"
  assert_contains "$output" "drifted"
}

@test "F-04: parity check fails when installer markers are missing" {
  mkdir -p "$BATS_TEST_TMPDIR/fake-repo/scripts"
  cp "$REPO_ROOT/sleep-after-claude"      "$BATS_TEST_TMPDIR/fake-repo/sleep-after-claude"
  cp "$REPO_ROOT/scripts/check-parity.sh" "$BATS_TEST_TMPDIR/fake-repo/scripts/check-parity.sh"

  # Installer without __SCRIPT_START__/__SCRIPT_END__ — simulates a
  # catastrophic refactor that removed the payload boundary.
  printf '#!/usr/bin/env bash\necho hi\n' > \
    "$BATS_TEST_TMPDIR/fake-repo/install-sleep-after-claude.sh"

  run bash "$BATS_TEST_TMPDIR/fake-repo/scripts/check-parity.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "could not extract embedded payload"
}
