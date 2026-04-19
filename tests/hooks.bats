#!/usr/bin/env bats
# Tests for --install-hooks / --uninstall-hooks / smart-watch primitive.

load 'lib/common'

setup() {
  setup_sandbox
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
  export BUSY_DIR="$HOME/.local/state/goodnight/busy"
}

@test "hooks: --install-hooks creates settings.json with Stop + UserPromptSubmit entries" {
  run bash "$REPO_ROOT/sleep-after-claude" --install-hooks
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_SETTINGS_FILE" ]
  run jq '.hooks.UserPromptSubmit | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  # Commands must reference the BUSY_DIR path
  run jq -r '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  assert_contains "$output" "$BUSY_DIR"
  assert_contains "$output" "session_id"
}

@test "hooks: reinstall does not duplicate — arrays remain length 1" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  run jq '.hooks.UserPromptSubmit | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "hooks: reinstall preserves user-defined hook entries" {
  # Simulate a user's existing hook that goodnight must not clobber.
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  cat >"$CLAUDE_SETTINGS_FILE" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo user-hook" }] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo pre-tool-user-hook" }] }
    ]
  }
}
EOF
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  # User's Stop hook still there
  run jq -r '.hooks.Stop | map(select(._managed_by != "goodnight"))[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo user-hook" ]
  # PreToolUse untouched
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo pre-tool-user-hook" ]
  # goodnight's Stop hook present
  run jq '.hooks.Stop | map(select(._managed_by == "goodnight")) | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
}

@test "hooks: --uninstall-hooks removes goodnight entries but leaves user hooks" {
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")"
  cat >"$CLAUDE_SETTINGS_FILE" <<'EOF'
{
  "hooks": {
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "echo user-hook" }] }
    ]
  }
}
EOF
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks >/dev/null
  run jq '.hooks.Stop | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "1" ]
  run jq -r '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "echo user-hook" ]
}

@test "hooks: --uninstall-hooks from a goodnight-only settings.json leaves {} behind" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  bash "$REPO_ROOT/sleep-after-claude" --uninstall-hooks >/dev/null
  run jq 'keys | length' "$CLAUDE_SETTINGS_FILE"
  [ "$output" = "0" ]
}

@test "count_busy_sessions: returns 0 when directory is empty" {
  source <(sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
  mkdir -p "$BUSY_DIR"
  run count_busy_sessions
  [ "$output" = "0" ]
}

@test "count_busy_sessions: returns the number of marker files" {
  source <(sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
  mkdir -p "$BUSY_DIR"
  touch "$BUSY_DIR/session-a" "$BUSY_DIR/session-b" "$BUSY_DIR/session-c"
  run count_busy_sessions
  [ "$output" = "3" ]
}

@test "count_busy_sessions: reaps markers older than 2h" {
  source <(sed -n '/^count_busy_sessions() {$/,/^}$/p' "$REPO_ROOT/sleep-after-claude")
  mkdir -p "$BUSY_DIR"
  touch "$BUSY_DIR/fresh"
  # Backdate a marker by 3 hours
  touch -t "$(date -v-3H +%Y%m%d%H%M)" "$BUSY_DIR/stale" 2>/dev/null
  run count_busy_sessions
  [ "$output" = "1" ]
  [ ! -f "$BUSY_DIR/stale" ]
  [ -f "$BUSY_DIR/fresh" ]
}
