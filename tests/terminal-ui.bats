#!/usr/bin/env bats
# Terminal UI presentation behavior.

load 'lib/common'

setup() {
  setup_sandbox
}

@test "terminal-ui: --help renders markdown help with a plain fallback" {
  run env SAC_NO_GLOW=1 "$REPO_ROOT/sleep-after-claude" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "# sleep-after-claude"
  assert_contains "$output" "## Watch options"
  assert_contains "$output" "default when hooks are installed"
}

@test "terminal-ui: ui_confirm fails closed without stdin TTY" {
  {
    sed -n '/^have_gum() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^prompt_confirm() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
    sed -n '/^ui_confirm() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude"
  } >"$BATS_TEST_TMPDIR/confirm.sh"

  run bash -c "
    STDIN_IS_TTY=false
    STDOUT_IS_TTY=false
    BOLD=''
    RESET=''
    print_warn() { echo \"WARN \$1\"; }
    source '$BATS_TEST_TMPDIR/confirm.sh'
    ui_confirm 'Proceed with risky operation?'
  " 2>&1

  [ "$status" -eq 1 ]
  assert_contains "$output" "Non-interactive confirmation unavailable"
  assert_contains "$output" "defaulting to no"
}
