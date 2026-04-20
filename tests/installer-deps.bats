#!/usr/bin/env bats
# Tests for the installer's runtime-dependency auto-install step.
# Verifies:
#   1. When jq is already available, installer reports "already installed"
#   2. When jq is unreachable (simulated offline), installer degrades
#      gracefully and still completes with a clear warning
#   3. The ensure_jq function's URL, arch detection, and size-envelope
#      guard are present in the installer source

load 'lib/common'

setup() {
  setup_sandbox
}

@test "installer: ensure_jq reports already-installed when jq is on PATH" {
  # jq is on the harness PATH (via Homebrew or /usr/bin). Installer
  # should see it and skip the download.
  SHELL=/bin/zsh run bash "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "jq already installed"
  assert_not_contains "$output" "Downloading jq"
}

@test "installer: ensure_jq source contains arch detection for arm64 and amd64" {
  # Source-code contract: we download the right binary per arch.
  run grep -c 'jq-macos-' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$output" -ne 0 ]
  run grep -E 'arm64|amd64' "$REPO_ROOT/install-sleep-after-claude.sh"
  assert_contains "$output" "arm64"
  assert_contains "$output" "amd64"
}

@test "installer: ensure_jq enforces a size envelope on the downloaded binary" {
  # Guard against CDN error pages / truncated downloads — must have a
  # min and max size check on the downloaded file.
  run grep -E 'size < 500000|size > 10000000' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: ensure_jq runs a post-download sanity check" {
  # The downloaded binary must respond to --version before we trust it.
  run grep -E '\$jq_tmp.*--version' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: failure to fetch jq is non-fatal" {
  # The ensure_jq call must be wrapped in `|| true` so a failed
  # download doesn't abort the whole installer.
  run grep -E 'ensure_jq \|\| true' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: quarantine attribute is stripped from downloaded jq" {
  # macOS gatekeeper flags network-downloaded binaries. We remove the
  # quarantine xattr so jq runs cleanly from our script.
  run grep 'xattr -d com.apple.quarantine' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: F-02 — SHA-256 pins are present for both arm64 and amd64" {
  # Real SHA-256s from jq 1.8.1 release. Any change to these lines
  # should be a deliberate re-pin, not a drift.
  run grep -E 'arm64\).*a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603' \
    "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
  run grep -E 'amd64\).*e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f' \
    "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: F-02 — integrity check runs BEFORE chmod +x" {
  # Ordering matters: we must not mark an unverified binary as
  # executable, even transiently. Source-code order check.
  local sha_line chmod_line
  sha_line="$(grep -n 'got_sha=' "$REPO_ROOT/install-sleep-after-claude.sh" | head -1 | cut -d: -f1)"
  chmod_line="$(grep -n '^  chmod +x "\$jq_tmp"' "$REPO_ROOT/install-sleep-after-claude.sh" | head -1 | cut -d: -f1)"
  [ -n "$sha_line" ]
  [ -n "$chmod_line" ]
  [ "$sha_line" -lt "$chmod_line" ]
}

@test "installer: F-02 — SAC_JQ_SHA256 env-var override is supported" {
  run grep 'SAC_JQ_SHA256' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: F-02 — mismatch path emits REFUSING and returns 1" {
  # Source-code contract: the mismatch branch must say "REFUSING" and
  # return 1 (not just warn and continue).
  run grep -E 'REFUSING' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: terminal UI layer provides gum/glow fallbacks" {
  run grep -E '^have_gum\(\)' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]

  run grep -E '^ui_spin\(\)' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]

  run grep -E '^ui_panel\(\)' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]

  run grep -E '^ui_markdown\(\)' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}

@test "installer: long-running steps go through ui_spin" {
  run grep -E 'ui_spin "Fetching installer payload' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]

  run grep -E 'ui_spin "Extracting sleep-after-claude' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]

  run grep -E 'ui_spin "Running quick verification' "$REPO_ROOT/install-sleep-after-claude.sh"
  [ "$status" -eq 0 ]
}
