#!/usr/bin/env bats
# F-02 / F-03 regression tests.
# Verify the piped-install re-download path:
#   - warns the user prominently
#   - enforces size envelope (2KB–512KB)
#   - rejects payloads missing __SCRIPT_START__ / __SCRIPT_END__ markers
#   - honors SLEEP_AFTER_CLAUDE_INSTALLER_SHA256 when provided
#   - happy path still works when piped from a local file:// URL

load 'lib/common'

setup() {
  setup_sandbox
  # SHELL must be a known value so the installer proceeds through the
  # alias-install step without hitting the unknown-shell branch.
  export SHELL=/bin/zsh
}

# Feeds the installer body to bash on stdin (simulating curl | bash) with
# no $0 file, which forces the re-download branch.
run_piped_install() {
  SLEEP_AFTER_CLAUDE_INSTALLER_URL="file://$REPO_ROOT/install-sleep-after-claude.sh" \
    bash < "$REPO_ROOT/install-sleep-after-claude.sh"
}

@test "F-02: piped install warns that re-download is happening" {
  run run_piped_install
  [ "$status" -eq 0 ]
  assert_contains "$output" "Installer was piped"
  assert_contains "$output" "re-downloading from"
  assert_contains "$output" "SLEEP_AFTER_CLAUDE_INSTALLER_SHA256"
}

@test "F-02: piped install installs the binary and alias successfully" {
  run run_piped_install
  [ "$status" -eq 0 ]
  [ -x "$HOME/bin/sleep-after-claude" ]
  run grep -c '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
}

@test "F-02: piped install rejects payload smaller than size envelope" {
  printf '#!/usr/bin/env bash\necho tiny\n' > "$BATS_TEST_TMPDIR/tiny.sh"
  run env SLEEP_AFTER_CLAUDE_INSTALLER_URL="file://$BATS_TEST_TMPDIR/tiny.sh" \
    bash < "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "implausible size"
  [ ! -f "$HOME/bin/sleep-after-claude" ]
}

@test "F-02: piped install rejects payload missing markers" {
  # Large enough to pass the size check but no payload markers.
  yes "# filler line to pad past 2KB minimum" | head -200 \
    > "$BATS_TEST_TMPDIR/no-markers.sh"
  run env SLEEP_AFTER_CLAUDE_INSTALLER_URL="file://$BATS_TEST_TMPDIR/no-markers.sh" \
    bash < "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "missing payload markers"
  [ ! -f "$HOME/bin/sleep-after-claude" ]
}

@test "F-02: piped install with correct SHA256 proceeds" {
  expected_sha="$(shasum -a 256 "$REPO_ROOT/install-sleep-after-claude.sh" | awk '{print $1}')"
  run env \
    SLEEP_AFTER_CLAUDE_INSTALLER_URL="file://$REPO_ROOT/install-sleep-after-claude.sh" \
    SLEEP_AFTER_CLAUDE_INSTALLER_SHA256="$expected_sha" \
    bash < "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Installer checksum verified"
  [ -x "$HOME/bin/sleep-after-claude" ]
}

@test "F-02: piped install with wrong SHA256 aborts before extract" {
  run env \
    SLEEP_AFTER_CLAUDE_INSTALLER_URL="file://$REPO_ROOT/install-sleep-after-claude.sh" \
    SLEEP_AFTER_CLAUDE_INSTALLER_SHA256="0000000000000000000000000000000000000000000000000000000000000000" \
    bash < "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -ne 0 ]
  assert_contains "$output" "Checksum mismatch"
  [ ! -f "$HOME/bin/sleep-after-claude" ]
}

@test "F-03: README documents cache-bust and pinned-install paths" {
  run cat "$REPO_ROOT/README.md"
  [ "$status" -eq 0 ]
  assert_contains "$output" "?v=\$(date +%s)"
  assert_contains "$output" "SLEEP_AFTER_CLAUDE_INSTALLER_URL"
  assert_contains "$output" "SLEEP_AFTER_CLAUDE_INSTALLER_SHA256"
}
