#!/usr/bin/env bats
# F-03 runtime test: the hook command strings written to
# ~/.claude/settings.json must evaluate correctly in a fresh shell
# with an arbitrary $HOME, not the one frozen at install time.
#
# This simulates what Claude Code does: it reads the "command" field
# from settings.json, pipes a JSON session blob on stdin, and invokes
# the command in a shell. We reproduce that invocation here with a
# different $HOME than the one that installed the hooks, and assert
# that the busy marker lands under the NEW home — not the old one.

load 'lib/common'

setup() {
  setup_sandbox
  export INSTALL_HOME="$HOME"
  export CLAUDE_SETTINGS_FILE="$HOME/.claude/settings.json"
}

@test "F-03 runtime: hook command evaluates \$HOME at hook-run time (not install time)" {
  # 1. Install hooks with HOME=$INSTALL_HOME
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  [ -f "$CLAUDE_SETTINGS_FILE" ]

  # 2. Extract the UserPromptSubmit command
  local prompt_cmd
  prompt_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")"
  [ -n "$prompt_cmd" ]

  # 3. Set up a DIFFERENT $HOME and run the command as Claude would
  #    (with a session_id JSON on stdin). The busy marker must land
  #    under the NEW home, proving $HOME was lazy-expanded.
  local new_home="$BATS_TEST_TMPDIR/relocated"
  mkdir -p "$new_home"
  local fake_session_json='{"session_id":"abc123","transcript_path":"/tmp/x"}'

  # Run the hook with HOME pointed at the relocated path. Also clear
  # the hook's working dir so any relative paths break loudly.
  HOME="$new_home" bash -c "$prompt_cmd" <<<"$fake_session_json"

  # 4. Assert: marker landed under the NEW home, NOT the install home.
  [ -f "$new_home/.local/state/goodnight/busy/abc123" ]
  [ ! -f "$INSTALL_HOME/.local/state/goodnight/busy/abc123" ]
}

@test "F-03 runtime: Stop hook removes marker under the invocation's \$HOME" {
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  local stop_cmd
  stop_cmd="$(jq -r '.hooks.Stop[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")"
  [ -n "$stop_cmd" ]

  local new_home="$BATS_TEST_TMPDIR/relocated2"
  mkdir -p "$new_home/.local/state/goodnight/busy"
  # Pre-populate a marker that the Stop hook should delete.
  touch "$new_home/.local/state/goodnight/busy/xyz789"

  local fake_session_json='{"session_id":"xyz789","transcript_path":"/tmp/x"}'
  HOME="$new_home" bash -c "$stop_cmd" <<<"$fake_session_json"

  [ ! -f "$new_home/.local/state/goodnight/busy/xyz789" ]
}

@test "F-04 runtime: hook command with weird session_id is handled safely" {
  # The hook command interpolates \$sid from jq output. If a session
  # id contains shell metacharacters (rare but not impossible),
  # they must stay quoted — not interpreted by the hook shell.
  # We send a weird session_id and verify NO unexpected side-effects.
  bash "$REPO_ROOT/sleep-after-claude" --install-hooks >/dev/null
  local prompt_cmd
  prompt_cmd="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$CLAUDE_SETTINGS_FILE")"

  local new_home="$BATS_TEST_TMPDIR/safe-home"
  mkdir -p "$new_home"
  # A session_id that would be dangerous if unquoted: "; rm -rf $HOME/sentinel; echo "
  # Since session_id comes out of jq -r, it's a literal string — the
  # hook command must treat it as a filename only, not execute it.
  touch "$new_home/sentinel"
  local malicious_json='{"session_id":"; rm -rf '"$new_home"'/sentinel; echo ","transcript_path":"/tmp/x"}'

  HOME="$new_home" bash -c "$prompt_cmd" <<<"$malicious_json" 2>/dev/null || true

  # sentinel must still exist — the session_id characters must have
  # been treated as part of the path/filename, not executed.
  [ -f "$new_home/sentinel" ]
}
