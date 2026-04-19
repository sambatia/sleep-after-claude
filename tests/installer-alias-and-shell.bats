#!/usr/bin/env bats
# F-06 / F-08 / F-11 regression tests.

load 'lib/common'

setup() {
  setup_sandbox
}

@test "F-06: fresh zsh install writes exactly one alias line with absolute path" {
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  [ -f "$HOME/.zshrc" ]
  # Exactly one alias line
  run grep -c '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
  # Absolute path, not literal $HOME
  run grep '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  assert_contains "$output" "$HOME/bin/sleep-after-claude"
  assert_not_contains "$output" '$HOME'
}

@test "F-06: reinstall does not duplicate the alias line" {
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  run grep -c '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
}

@test "F-06: reinstall replaces stale alias pointing to old path" {
  # Simulate a pre-existing install at a different path.
  cat > "$HOME/.zshrc" <<EOF

# sleep-after-claude shortcut (added by installer)
alias goodnight="/old/path/sleep-after-claude"
EOF
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  run grep -c '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
  # The stale path must be gone.
  run grep '/old/path' "$HOME/.zshrc"
  [ "$status" -ne 0 ]
  # The new path must be present.
  run grep '^[[:space:]]*alias[[:space:]]*goodnight=' "$HOME/.zshrc"
  assert_contains "$output" "$HOME/bin/sleep-after-claude"
}

@test "F-06: reinstall preserves surrounding rc content" {
  cat > "$HOME/.zshrc" <<EOF
export FOO=bar

# some user stuff
alias myls="ls -lah"

# sleep-after-claude shortcut (added by installer)
alias goodnight="/old/path/sleep-after-claude"

export BAZ=qux
EOF
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  run cat "$HOME/.zshrc"
  assert_contains "$output" "export FOO=bar"
  assert_contains "$output" "alias myls=\"ls -lah\""
  assert_contains "$output" "export BAZ=qux"
  assert_not_contains "$output" "/old/path"
}

@test "UX: fresh install adds ~/bin to PATH in the rc file" {
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  run grep -c 'export PATH="\$HOME/bin:\$PATH"' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
  assert_contains "$(cat "$HOME/.zshrc")" "~/bin on PATH"
}

@test "UX: reinstall does not duplicate the PATH export" {
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  run grep -c 'export PATH="\$HOME/bin:\$PATH"' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
}

@test "UX: existing PATH export that mentions \$HOME/bin is respected" {
  # User has their own PATH line — installer must not append a second.
  cat > "$HOME/.zshrc" <<'EOF'
export PATH="$HOME/bin:/usr/local/bin:$PATH"
EOF
  SHELL=/bin/zsh bash "$REPO_ROOT/install-sleep-after-claude.sh" >/dev/null
  run grep -c '\$HOME/bin' "$HOME/.zshrc"
  [ "$output" -eq 1 ]
}

@test "F-11: unknown shell skips alias install and writes no rc file" {
  SHELL=/usr/local/bin/fish run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Unknown shell"
  assert_contains "$output" "skipping alias install"
  assert_contains "$output" "Add this line to your shell rc manually"
  [ ! -f "$HOME/.zshrc" ]
  [ ! -f "$HOME/.bashrc" ]
  [ ! -f "$HOME/.bash_profile" ]
  # But the binary still gets installed.
  [ -x "$HOME/bin/sleep-after-claude" ]
}

@test "F-08: installer exits non-zero when verification --help fails" {
  # Patch the installer so that $TARGET --help always fails.
  sed 's|"\$TARGET" --help >/dev/null 2>&1|false|' \
    "$REPO_ROOT/install-sleep-after-claude.sh" > "$BATS_TEST_TMPDIR/broken-installer.sh"
  SHELL=/bin/zsh run bash "$BATS_TEST_TMPDIR/broken-installer.sh"
  [ "$status" -eq 1 ]
  assert_contains "$output" "Script failed to run --help"
}
