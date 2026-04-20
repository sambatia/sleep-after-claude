#!/usr/bin/env bats
# F-05 + F-06 regression tests.

load 'lib/common'

setup() {
  setup_sandbox
}

@test "F-06: SAC_SKIP_HOOK_INSTALL=1 blocks the installer's hook install" {
  SHELL=/bin/zsh SAC_SKIP_HOOK_INSTALL=1 run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "SAC_SKIP_HOOK_INSTALL=1 — skipping"
  # Settings file must NOT exist (no write happened)
  [ ! -f "$HOME/.claude/settings.json" ]
}

@test "F-06: default install announces the settings.json mutation" {
  # Without the opt-out, the installer should clearly announce it's
  # about to modify the settings file. This verifies we didn't lose
  # the announce lines in future refactors.
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Installing Claude Code hooks into"
  assert_contains "$output" "SAC_SKIP_HOOK_INSTALL=1"
}

@test "F-06: SAC_SKIP_HOOK_INSTALL=1 still installs the binary + alias" {
  SHELL=/bin/zsh SAC_SKIP_HOOK_INSTALL=1 run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  [ -x "$HOME/bin/sleep-after-claude" ]
  [ -f "$HOME/.zshrc" ]
  run grep -c '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
}

@test "F-05: source contains SAC_ORIGINAL_ARGS capture at script entry" {
  # The args must be stashed BEFORE any arg parsing so the re-exec can
  # preserve them. Source-order check.
  local stash_line parse_line
  stash_line="$(grep -n '^SAC_ORIGINAL_ARGS=' "$REPO_ROOT/sleep-after-claude" | head -1 | cut -d: -f1)"
  parse_line="$(grep -n '^# ── Argument parsing' "$REPO_ROOT/sleep-after-claude" | head -1 | cut -d: -f1)"
  [ -n "$stash_line" ]
  [ -n "$parse_line" ]
  [ "$stash_line" -lt "$parse_line" ]
}

@test "F-05: check_for_update exec's the new version on successful update" {
  # Source contract: after curl | bash succeeds, must exec into the
  # new script.
  run grep -E 'exec "\$self_path_for_exec" "\$\{SAC_ORIGINAL_ARGS\[@\]\}"' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-05: child process skips update check after re-exec (prevents loop)" {
  # After re-exec, the new binary must see SAC_SKIP_UPDATE_CHECK=1 so
  # it doesn't re-run the update check in a loop.
  run grep 'SAC_SKIP_UPDATE_CHECK=1' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}

@test "F-05: SAC_SKIP_UPDATE_CHECK env var is honored in the config block" {
  run grep -E 'SKIP_UPDATE_CHECK.*SAC_SKIP_UPDATE_CHECK' "$REPO_ROOT/sleep-after-claude"
  [ "$status" -eq 0 ]
}
