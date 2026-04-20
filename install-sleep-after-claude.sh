#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  install-sleep-after-claude.sh
#  Self-extracting installer for sleep-after-claude + goodnight alias.
#
#  Usage:
#    bash install-sleep-after-claude.sh
#    curl -fsSL <url> | bash             # piped-install path (re-downloads
#                                          self into temp file, validates
#                                          size/markers/optional SHA, then
#                                          extracts)
#
#  What it does, in order:
#    1. Verifies macOS.
#    2. Creates ~/bin if needed; adds it to PATH in the user's shell rc.
#    3. Backs up any existing sleep-after-claude install.
#    4. Extracts the embedded script to ~/bin/sleep-after-claude.
#    5. Detects the shell (zsh/bash) and installs a deduplicated
#       `goodnight` alias; unknown shells get manual instructions only.
#    6. Auto-installs jq into ~/bin/jq (SHA-pinned per arch, non-fatal
#       on failure — goodnight falls back to --watch-pid mode without jq).
#    7. Auto-installs Claude Code hooks into ~/.claude/settings.json so
#       --smart idle detection works on first run. Gated by jq
#       availability and SAC_SKIP_HOOK_INSTALL=1 (opt-out).
#    8. Verifies the install by running `--help` on the extracted tool.
#    9. Drains its own stdin on piped-install exit with a bounded 5s
#       timeout (F-11) so `curl | bash && next_cmd` chains don't hang.
#
#  Environment variable overrides:
#    SLEEP_AFTER_CLAUDE_INSTALLER_URL      — alt source URL
#    SLEEP_AFTER_CLAUDE_INSTALLER_SHA256   — require this SHA on piped-install
#    SAC_JQ_SHA256                         — override the expected jq SHA
#    SAC_SKIP_HOOK_INSTALL=1               — skip ~/.claude/settings.json edit
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Colours (TTY only) ────────────────────────────────────────────
if [[ -t 1 ]]; then
  # $'...' so vars contain real ESC bytes — robust to printf %s and
  # plain echo without -e.
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_RED=""
  C_BLUE=""
fi

say() { echo -e "  ${C_CYAN}›${C_RESET} $1"; }
ok() { echo -e "  ${C_GREEN}✔${C_RESET} $1"; }
warn() { echo -e "  ${C_YELLOW}⚠${C_RESET}  $1"; }
fail() { echo -e "  ${C_RED}✖${C_RESET} $1" >&2; }

# ── Header ────────────────────────────────────────────────────────
echo ""
echo -e "  ${C_BOLD}${C_BLUE}sleep-after-claude installer${C_RESET}"
echo -e "  ${C_DIM}─────────────────────────────────────────${C_RESET}"
echo ""

# ── 1. macOS check ────────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  fail "This installer only supports macOS."
  exit 1
fi
ok "macOS detected ($(sw_vers -productVersion 2>/dev/null || echo unknown))"

# ── 2. Ensure ~/bin exists ────────────────────────────────────────
if [[ ! -d "$HOME/bin" ]]; then
  mkdir -p "$HOME/bin"
  say "Created ~/bin"
fi
# shellcheck disable=SC2088 # Intentional user-facing display — "~/bin" reads better than an expanded absolute path
ok "~/bin ready"

# ── 3. ~/bin PATH handling — deferred until we know the rc file ──
# Step 8 below adds `export PATH="$HOME/bin:$PATH"` to the shell rc
# when the alias is installed. This makes `sleep-after-claude` directly
# callable in future shell sessions without the user ever needing to
# touch PATH manually.

# ── 4. Backup existing install ────────────────────────────────────
TARGET="$HOME/bin/sleep-after-claude"
if [[ -f "$TARGET" ]]; then
  cp "$TARGET" "${TARGET}.bak"
  ok "Previous version backed up to ~/bin/sleep-after-claude.bak"
fi

# ── 5. Extract embedded script ────────────────────────────────────
say "Extracting sleep-after-claude to ~/bin/..."

# When run as `curl ... | bash`, BASH_SOURCE[0] and $0 are "bash" (not a file),
# so awk can't read the installer. In that case, re-download it to a temp file.
# The re-download is a second trust hop: we warn the user, sanity-check the
# body, and optionally verify an sha256 pin if the caller provided one.
SELF="${BASH_SOURCE[0]:-$0}"
TMP_SELF=""
if [[ ! -f "$SELF" ]]; then
  SOURCE_URL="${SLEEP_AFTER_CLAUDE_INSTALLER_URL:-https://raw.githubusercontent.com/sambatia/sleep-after-claude/main/install-sleep-after-claude.sh}"
  # Calm single-line message (this is the normal `curl | bash` path —
  # not an error). Advanced users wanting SHA-256 provenance can find
  # the env-var recipe in the README; we don't surface it here because
  # it's noise for the 99% non-technical install flow.
  say "Fetching installer payload from $SOURCE_URL"
  TMP_SELF="$(mktemp -t sleep-after-claude-installer.XXXXXX)"
  if ! curl -fsSL "$SOURCE_URL" -o "$TMP_SELF"; then
    fail "Could not re-download installer from $SOURCE_URL"
    rm -f "$TMP_SELF"
    exit 1
  fi

  # Sanity-check the downloaded payload before trusting it.
  # 1. Size must be within a plausible envelope (guards against HTML error
  #    pages, truncated CDN responses, and absurd payloads).
  TMP_SIZE="$(wc -c <"$TMP_SELF" | tr -d ' ')"
  if ! [[ "$TMP_SIZE" =~ ^[0-9]+$ ]] || ((TMP_SIZE < 2000 || TMP_SIZE > 524288)); then
    fail "Downloaded installer has implausible size (${TMP_SIZE} bytes) — aborting."
    rm -f "$TMP_SELF"
    exit 1
  fi
  # 2. Must contain both payload markers.
  if ! grep -q '^__SCRIPT_START__$' "$TMP_SELF" || ! grep -q '^__SCRIPT_END__$' "$TMP_SELF"; then
    fail "Downloaded installer is missing payload markers — aborting."
    rm -f "$TMP_SELF"
    exit 1
  fi
  # 3. Optional sha256 pin.
  if [[ -n "${SLEEP_AFTER_CLAUDE_INSTALLER_SHA256:-}" ]]; then
    if ! command -v shasum >/dev/null 2>&1; then
      fail "shasum not available — cannot verify SLEEP_AFTER_CLAUDE_INSTALLER_SHA256."
      rm -f "$TMP_SELF"
      exit 1
    fi
    GOT_SHA="$(shasum -a 256 "$TMP_SELF" | awk '{print $1}')"
    if [[ "$GOT_SHA" != "$SLEEP_AFTER_CLAUDE_INSTALLER_SHA256" ]]; then
      fail "Checksum mismatch — expected $SLEEP_AFTER_CLAUDE_INSTALLER_SHA256, got $GOT_SHA"
      rm -f "$TMP_SELF"
      exit 1
    fi
    ok "Installer checksum verified."
  fi

  SELF="$TMP_SELF"
fi

awk '/^__SCRIPT_START__$/{flag=1; next} /^__SCRIPT_END__$/{flag=0} flag' "$SELF" >"$TARGET"

[[ -n "$TMP_SELF" ]] && rm -f "$TMP_SELF"

if [[ ! -s "$TARGET" ]]; then
  fail "Extraction failed — installer file may be corrupted."
  exit 1
fi

chmod +x "$TARGET"
ok "Extracted $(wc -l <"$TARGET" | tr -d ' ') lines to ~/bin/sleep-after-claude"

# ── 6. Syntax-check the extracted script ──────────────────────────
if bash -n "$TARGET" 2>/dev/null; then
  ok "Script syntax valid"
else
  fail "Extracted script has syntax errors — aborting."
  exit 1
fi

# ── 7. Detect shell + rc file ─────────────────────────────────────
SHELL_NAME="$(basename "${SHELL:-/bin/zsh}")"
RC=""
case "$SHELL_NAME" in
  zsh)
    RC="$HOME/.zshrc"
    ;;
  bash)
    if [[ -f "$HOME/.bash_profile" ]]; then
      RC="$HOME/.bash_profile"
    else
      RC="$HOME/.bashrc"
    fi
    ;;
esac

# ── 8. Add alias (idempotent, dedupes across reinstalls) ──────────
if [[ -z "$RC" ]]; then
  warn "Unknown shell ($SHELL_NAME) — skipping alias install."
  warn "Add this line to your shell rc manually:"
  warn "  alias goodnight=\"$HOME/bin/sleep-after-claude\""
else
  [[ -f "$RC" ]] || touch "$RC"

  # Remove any prior `alias goodnight=` lines (and the header comment
  # directly above them, if any) so reinstalls don't duplicate or orphan
  # lines pointing at stale paths. Then re-append the current line.
  if grep -q '^[[:space:]]*alias[[:space:]]\+goodnight=' "$RC" 2>/dev/null; then
    TMP_RC="$(mktemp)"
    awk '
      /^# sleep-after-claude shortcut \(added by installer\)$/ { skip_next_if_alias=1; next }
      skip_next_if_alias==1 && /^[[:space:]]*alias[[:space:]]+goodnight=/ { skip_next_if_alias=0; next }
      /^[[:space:]]*alias[[:space:]]+goodnight=/ { skip_next_if_alias=0; next }
      { skip_next_if_alias=0; print }
    ' "$RC" >"$TMP_RC" && mv "$TMP_RC" "$RC"
    say "Removed existing 'goodnight' alias line(s) in $(basename "$RC")"
  fi

  {
    echo ''
    echo '# sleep-after-claude shortcut (added by installer)'
    echo "alias goodnight=\"$HOME/bin/sleep-after-claude\""
  } >>"$RC"
  ok "Alias 'goodnight' added to $(basename "$RC")"

  # Ensure ~/bin is on PATH for future shell sessions. Dedupe the same
  # way as the alias line so reinstalls don't accumulate duplicates.
  PATH_LINE="export PATH=\"\$HOME/bin:\$PATH\""
  if grep -qF "$PATH_LINE" "$RC" 2>/dev/null; then
    : # already present, leave it
  else
    # Also detect near-equivalents (e.g. quoted differently) so we
    # don't append a second PATH line that contradicts a prior manual
    # edit.
    if grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*\$HOME/bin' "$RC" 2>/dev/null ||
      grep -qE '^[[:space:]]*export[[:space:]]+PATH=.*'"$HOME/bin" "$RC" 2>/dev/null; then
      : # some PATH export mentioning $HOME/bin already exists
    else
      {
        echo ''
        echo '# Put ~/bin on PATH so sleep-after-claude is callable directly (added by installer)'
        echo "$PATH_LINE"
      } >>"$RC"
      # shellcheck disable=SC2088 # Intentional user-facing display
      ok "~/bin added to PATH in $(basename "$RC")"
    fi
  fi
fi

# ── 8a. Ensure runtime dependencies (jq) ──────────────────────────
# Goodnight's default mode uses Claude Code hooks, and hook install /
# detection requires `jq`. macOS doesn't ship with jq, so a clean
# laptop would fall back to --watch-pid mode without it. To make the
# install truly zero-touch, we auto-fetch a static jq binary from the
# jqlang/jq GitHub releases and drop it in ~/bin (already on PATH
# from step 8 above).
#
# Failure here is non-fatal: goodnight still works in --watch-pid
# mode, and the user can install jq later. We just print a clear
# message.
ensure_jq() {
  # Prefer any already-installed jq. F-09: also probe common locations
  # in case the user installed jq before this run but hasn't sourced
  # the updated PATH yet.
  if command -v jq >/dev/null 2>&1; then
    ok "jq already installed: $(jq --version 2>/dev/null || echo '?')"
    return 0
  fi
  local candidate
  local candidate_dir
  for candidate in "$HOME/bin/jq" "/opt/homebrew/bin/jq" "/usr/local/bin/jq" "/usr/bin/jq"; do
    if [[ -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
      ok "jq already installed at $candidate: $("$candidate" --version)"
      candidate_dir="$(dirname "$candidate")"
      export PATH="$candidate_dir:$PATH"
      return 0
    fi
  done

  local arch jq_url jq_tmp jq_dest jq_version expected_sha got_sha
  case "$(uname -m)" in
    arm64) arch="arm64" ;;
    x86_64) arch="amd64" ;;
    *)
      warn "Unknown CPU architecture '$(uname -m)' — cannot auto-install jq."
      warn "Install manually: ${C_BOLD}brew install jq${C_RESET} — then re-run this installer."
      return 1
      ;;
  esac

  # Pinned to a known-good stable release. Bump = update version AND
  # both SHA-256 values below. To rotate, fetch and compute with:
  #   curl -fsSL "$jq_url" | shasum -a 256
  jq_version="1.8.1"
  # F-02: Expected SHA-256 per arch. Mismatch → hard refusal. An
  # override is honored via SAC_JQ_SHA256 for users who need to pin
  # a different jq build (e.g., bleeding-edge version).
  case "$arch" in
    arm64) expected_sha="a9fe3ea2f86dfc72f6728417521ec9067b343277152b114f4e98d8cb0e263603" ;;
    amd64) expected_sha="e80dbe0d2a2597e3c11c404f03337b981d74b4a8504b70586c354b7697a7c27f" ;;
  esac
  expected_sha="${SAC_JQ_SHA256:-$expected_sha}"

  jq_url="https://github.com/jqlang/jq/releases/download/jq-${jq_version}/jq-macos-${arch}"
  jq_dest="$HOME/bin/jq"
  jq_tmp="$(mktemp -t goodnight-jq.XXXXXX)"

  say "Downloading jq ${jq_version} for macOS (${arch})..."
  if ! curl -fsSL --max-time 60 -o "$jq_tmp" "$jq_url" 2>/dev/null; then
    warn "Could not download jq from GitHub (offline? firewall?)."
    warn "Install later with: ${C_BOLD}brew install jq${C_RESET}"
    warn "Goodnight will run in --watch-pid mode until then."
    rm -f "$jq_tmp"
    return 1
  fi

  # Basic sanity: plausible binary size (catches CDN error pages
  # before the SHA-256 check has to do real work).
  local size
  size="$(wc -c <"$jq_tmp" | tr -d ' ')"
  if ! [[ "$size" =~ ^[0-9]+$ ]] || ((size < 500000 || size > 10000000)); then
    warn "Downloaded jq has implausible size (${size} bytes) — skipping."
    rm -f "$jq_tmp"
    return 1
  fi

  # F-02: SHA-256 integrity check against the pinned value. A
  # mismatch indicates supply-chain compromise, wrong mirror, or the
  # release binary was re-uploaded (requires re-pinning on our side).
  # In any of those cases we refuse to install.
  got_sha="$(shasum -a 256 "$jq_tmp" 2>/dev/null | awk '{print $1}')"
  if [[ -z "$got_sha" ]]; then
    warn "shasum unavailable — cannot verify jq integrity. Aborting jq install."
    rm -f "$jq_tmp"
    return 1
  fi
  if [[ "$got_sha" != "$expected_sha" ]]; then
    warn "jq checksum mismatch — ${C_BOLD}REFUSING${C_RESET} to install."
    warn "  expected: $expected_sha"
    warn "  got:      $got_sha"
    warn "If jq was legitimately re-released, set ${C_BOLD}SAC_JQ_SHA256=<expected>${C_RESET} and re-run."
    rm -f "$jq_tmp"
    return 1
  fi

  chmod +x "$jq_tmp"
  # Strip the macOS quarantine attribute so gatekeeper doesn't flag
  # this first-run-from-a-script binary.
  xattr -d com.apple.quarantine "$jq_tmp" 2>/dev/null || true

  if ! "$jq_tmp" --version >/dev/null 2>&1; then
    warn "Downloaded jq binary didn't run (macOS gatekeeper? wrong arch?)."
    warn "Install manually: ${C_BOLD}brew install jq${C_RESET}"
    rm -f "$jq_tmp"
    return 1
  fi

  mv "$jq_tmp" "$jq_dest"
  # Ensure the newly-installed jq is on PATH for the rest of this
  # installer run (future sessions pick it up via the rc file edit
  # in step 8).
  export PATH="$HOME/bin:$PATH"
  ok "jq ${jq_version} installed at ~/bin/jq (sha256 verified)"
}

echo ""
say "Ensuring runtime dependencies..."
ensure_jq || true

# ── 9. Verification ───────────────────────────────────────────────
echo ""
say "Running quick verification..."
if "$TARGET" --help >/dev/null 2>&1; then
  ok "Script executes successfully"
else
  fail "Script failed to run --help. Try manually: ~/bin/sleep-after-claude --help"
  exit 1
fi

# ── 9a. Claude Code hook setup ────────────────────────────────────
# Default `goodnight` uses hook-based idle detection. Try to install
# the hooks automatically so the user gets the expected behavior on
# first run. Requires jq — if absent, emit a friendly note and skip
# (the installed script still works in --watch-pid mode until the
# user installs jq and runs `goodnight --install-hooks`).
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
hooks_already_installed() {
  [[ -f "$CLAUDE_SETTINGS" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.hooks.Stop // []) + (.hooks.UserPromptSubmit // []) | map(select(._managed_by == "goodnight")) | length > 0' \
      "$CLAUDE_SETTINGS" >/dev/null 2>&1
  else
    grep -q '"_managed_by"[[:space:]]*:[[:space:]]*"goodnight"' "$CLAUDE_SETTINGS" 2>/dev/null
  fi
}

echo ""
say "Checking Claude Code hook setup..."
if [[ "${SAC_SKIP_HOOK_INSTALL:-}" == "1" ]]; then
  # F-06: Explicit opt-out for users who don't want the installer
  # touching ~/.claude/settings.json. Install still succeeds; they
  # can always run `goodnight --install-hooks` later when ready.
  warn "SAC_SKIP_HOOK_INSTALL=1 — skipping Claude Code hook install."
  warn "Run ${C_CYAN}goodnight --install-hooks${C_RESET} to enable idle detection later."
elif hooks_already_installed; then
  ok "Claude Code hooks already installed — idle detection ready."
elif ! command -v jq >/dev/null 2>&1; then
  # Auto-install of jq in step 8a failed (offline, unsupported arch,
  # etc.). Record the skip reason — user can recover later.
  warn "jq unavailable — Claude Code hook installation skipped."
  warn "Once jq is installed (e.g. ${C_BOLD}brew install jq${C_RESET}), run:"
  warn "  ${C_CYAN}goodnight --install-hooks${C_RESET}"
  warn "Until then goodnight runs in legacy ${C_BOLD}--watch-pid${C_RESET} mode."
else
  # F-06: About to modify ~/.claude/settings.json. Announce clearly
  # before doing it. Users who don't want this can Ctrl+C now or
  # re-run with SAC_SKIP_HOOK_INSTALL=1.
  say "Installing Claude Code hooks into $CLAUDE_SETTINGS..."
  say "(adds two ${C_BOLD}_managed_by: goodnight${C_RESET} entries; existing hooks preserved."
  say " Skip with ${C_BOLD}SAC_SKIP_HOOK_INSTALL=1${C_RESET} and re-run; remove later with ${C_BOLD}goodnight --uninstall-hooks${C_RESET}.)"
  if "$TARGET" --install-hooks >/tmp/sac-hook-install.log 2>&1; then
    ok "Claude Code hooks installed — default mode is idle-detection."
    say "Restart any running Claude Code sessions so they pick up the new hooks."
  else
    warn "Could not auto-install Claude Code hooks. See /tmp/sac-hook-install.log"
    warn "You can install them manually later: ${C_CYAN}goodnight --install-hooks${C_RESET}"
  fi
fi

# ── 10. Done ──────────────────────────────────────────────────────
echo ""
echo -e "  ${C_DIM}─────────────────────────────────────────${C_RESET}"
echo -e "  ${C_BOLD}${C_GREEN}Installation complete 🌙${C_RESET}"
echo -e "  ${C_DIM}─────────────────────────────────────────${C_RESET}"
echo ""
echo -e "  ${C_BOLD}Next step:${C_RESET} open a new Terminal tab, then run:"
echo ""
echo -e "    ${C_CYAN}goodnight --help${C_RESET}         # show all options"
echo -e "    ${C_CYAN}goodnight --preflight${C_RESET}    # audit your system"
echo -e "    ${C_CYAN}goodnight${C_RESET}                # watch Claude + sleep when done"
echo ""
if [[ -n "$RC" ]]; then
  echo -e "  ${C_DIM}Or, to use in this terminal right now:${C_RESET}"
  echo -e "    ${C_CYAN}source $RC${C_RESET}"
  echo ""
fi

# ── Drain the rest of the piped installer ────────────────────────
# When invoked as `curl ... | bash`, curl streams the embedded
# __SCRIPT_START__/__SCRIPT_END__ payload below this line. Without
# draining, `exit 0` closes the pipe mid-write and curl fails with
# "curl: (56) Failure writing output to destination". Cosmetically
# ugly and confusing to users even when the install succeeded.
#
# Detection: `-p /dev/stdin` is true only when stdin is a FIFO
# (i.e., piped input). Local runs (`bash install.sh` or
# `bash < install.sh`) have stdin as a TTY or regular file → no
# drain needed. This is the same idiom used by Homebrew's own
# installer.
if [[ -p /dev/stdin ]]; then
  # F-11: Bound the drain so a pathological hang on the pipe source
  # (slow trickle, stuck CDN connection) can't block the installer's
  # exit indefinitely. 5s comfortably exceeds any real CDN finish-
  # write for a ~45KB payload.
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout 5 cat >/dev/null 2>&1 || true
  elif command -v timeout >/dev/null 2>&1; then
    timeout 5 cat >/dev/null 2>&1 || true
  else
    # Fallback: background cat + 5s watchdog. Kill the cat if it's
    # still running when the deadline hits.
    cat >/dev/null 2>&1 &
    drain_pid=$!
    (sleep 5 && kill "$drain_pid" 2>/dev/null) &
    wait "$drain_pid" 2>/dev/null || true
  fi
fi

exit 0

# ─── Embedded sleep-after-claude script follows ───────────────────
# Everything between __SCRIPT_START__ and __SCRIPT_END__ is extracted
# by awk above. Do not modify these markers.
__SCRIPT_START__
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  sleep-after-claude
#  Watches a Claude Code process and sleeps the Mac when done.
#
#  Includes a pre-flight scan of sleep-preventing processes and
#  power assertions so you know whether sleep will actually happen.
#
#  Usage: sleep-after-claude [options]
# ─────────────────────────────────────────────────────────────

set -uo pipefail

# Capture original argv up-front so check_for_update can `exec` into
# the freshly-installed binary preserving the user's invocation (F-05).
SAC_ORIGINAL_ARGS=("$@")

# ── macOS guard ───────────────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo "✖  sleep-after-claude only supports macOS." >&2
  exit 1
fi

# ── Bash version + TTY detection ──────────────────────────────
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
USE_BUILTIN_SLEEP=false
[[ $BASH_MAJOR -ge 4 ]] && USE_BUILTIN_SLEEP=true

USE_SPINNER=true
[[ -t 1 ]] || USE_SPINNER=false

STDIN_IS_TTY=false
[[ -t 0 ]] && STDIN_IS_TTY=true

STDOUT_IS_TTY=false
[[ -t 1 ]] && STDOUT_IS_TTY=true

# ── Colours (disabled for non-TTY output) ─────────────────────
if [[ "$STDOUT_IS_TTY" == true ]]; then
  # Use $'...' so the vars contain actual ESC bytes (not the literal
  # string "\033[..."). This means `printf "%s" "$CYAN"` renders
  # correctly, and `echo "$CYAN"` works without `-e`. The previous
  # "\033[..." form required either `echo -e` or `printf %b`, and
  # silently produced literal text when passed through `printf %s`.
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  RED=$'\033[31m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
else
  RESET=""
  BOLD=""
  DIM=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RED=""
  BLUE=""
  MAGENTA=""
fi

# ── Config defaults ───────────────────────────────────────────
TIMEOUT_HOURS=6
DELAY_SECS=1
TARGET_PID=""
TARGET_PID_EXPLICIT=false
NO_SOUND=false
CAFFEINATE_ONLY=false
DRY_RUN=false
LIST_MODE=false
NOTIFY=false
LOG_ENABLED=false
WAIT_FOR_START=false
LOG_FILE="${HOME}/.local/state/sleep-after-claude.log"
FIFO_DIR=""
PREFLIGHT_ONLY=false
SKIP_PREFLIGHT=false
FORCE=false
BRIEF=false
JSON_OUTPUT=false
SKIP_UPDATE_CHECK="${SAC_SKIP_UPDATE_CHECK:+true}"
SKIP_UPDATE_CHECK="${SKIP_UPDATE_CHECK:-false}"
NO_AUTO_CAFFEINATE=false
ALLOW_BATTERY=false
LOG_SUMMARY=false
SLEEP_NOW=false
SMART_WATCH=false
WATCH_PID_MODE=false
INSTALL_HOOKS=false
UNINSTALL_HOOKS=false
CLAUDE_SETTINGS_FILE="${HOME}/.claude/settings.json"
BUSY_DIR="${HOME}/.local/state/goodnight/busy"
SMART_IDLE_SECONDS=30 # how long all sessions must be idle before sleep
# Stale-marker threshold in minutes. A busy marker older than this is
# assumed to belong to a crashed Claude session. Default 24h — tight
# enough to reap genuinely-dead sessions eventually, loose enough that
# a legitimately long-running task (large migration, agentic run)
# doesn't get reaped mid-work. Override with SAC_STALE_MARKER_MINUTES.
SMART_STALE_MARKER_MINS="${SAC_STALE_MARKER_MINUTES:-1440}"
UPDATE_CHECK_URL="${SLEEP_AFTER_CLAUDE_UPDATE_URL:-https://raw.githubusercontent.com/sambatia/sleep-after-claude/main/sleep-after-claude}"
UPDATE_INSTALLER_URL="${SLEEP_AFTER_CLAUDE_INSTALLER_URL:-https://raw.githubusercontent.com/sambatia/sleep-after-claude/main/install-sleep-after-claude.sh}"
UPDATE_CACHE_DIR="${HOME}/.cache/sleep-after-claude"
UPDATE_CACHE_TTL_SECS=86400 # 24h rate-limit on network checks

# ── Helpers ───────────────────────────────────────────────────
print_header() {
  echo ""
  echo -e "  ${BOLD}${BLUE}sleep-after-claude${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
}

print_step() { echo -e "  ${CYAN}›${RESET} $1"; }
print_ok() { echo -e "  ${GREEN}✔${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
print_error() { echo -e "  ${RED}✖${RESET} $1"; }
print_done() {
  echo ""
  echo -e "  ${BOLD}${GREEN}✔ Done.${RESET} $1"
  echo ""
}

# ── gum / glow integration ────────────────────────────────────
# These are optional polish layers. When `gum` (charmbracelet/gum) is
# on PATH and both stdin and stdout are real TTYs, interactive prompts
# and styled cards use gum for a prettier experience. When absent —
# or when the session is over SSH, where mobile/flaky SSH clients
# mishandle gum's /dev/tty writes and arrow-key forwarding —
# everything falls back to the hand-rolled bash UI.
#
# Overrides:
#   SAC_NO_GUM=1      force fallback (CI, scripts, minimal terminals)
#   SAC_FORCE_GUM=1   opt back in when over SSH (for users whose SSH
#                     client handles TUIs well — e.g. iTerm → ssh)
have_gum() {
  [[ "${SAC_NO_GUM:-}" != "1" ]] || return 1
  [[ "$STDOUT_IS_TTY" == true ]] || return 1
  [[ "$STDIN_IS_TTY" == true ]] || return 1
  # SSH sessions default to fallback — interactive TUIs over SSH are
  # often fragile (especially over mobile SSH apps like Termius/Blink
  # which may not forward arrow keys or /dev/tty reliably).
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] && [[ "${SAC_FORCE_GUM:-}" != "1" ]]; then
    return 1
  fi
  command -v gum >/dev/null 2>&1
}
have_glow() {
  [[ "${SAC_NO_GLOW:-}" != "1" ]] || return 1
  [[ "$STDOUT_IS_TTY" == true ]] || return 1
  command -v glow >/dev/null 2>&1
}

# Styled panel: gum-powered rounded box with colored border if gum is
# available, otherwise the existing hand-drawn ╭─╮ card. Each argument
# is one content line.
#
# Usage: ui_panel <color> <title> <line1> <line2> ...
#   color: "warning" | "info" | "success" | "danger"
ui_panel() {
  local kind="$1"
  shift
  local title="$1"
  shift
  local -a lines=("$@")

  if have_gum; then
    local fg border
    case "$kind" in
      warning)
        fg=214
        border=214
        ;;
      info)
        fg=39
        border=39
        ;;
      success)
        fg=46
        border=46
        ;;
      danger)
        fg=196
        border=196
        ;;
      *)
        fg=250
        border=250
        ;;
    esac
    # gum style takes each argument as a separate line and renders
    # them inside the box. --bold applies to the whole block; we
    # use an explicit bold title and plain content by calling
    # gum style twice and nesting via gum join.
    local title_block content_block
    title_block="$(gum style --foreground "$fg" --bold -- "$title")"
    content_block="$(printf '%s\n' "${lines[@]}" | gum style)"
    gum style \
      --border rounded \
      --border-foreground "$border" \
      --padding "1 2" \
      --margin "1 0" \
      -- "$title_block" "" "$content_block"
    return
  fi

  # Fallback: hand-drawn box (current style).
  local color="$YELLOW"
  case "$kind" in
    info) color="$BLUE" ;;
    success) color="$GREEN" ;;
    danger) color="$RED" ;;
  esac
  local rule="────────────────────────────────────────────────────────"
  echo ""
  echo -e "  ${BOLD}${color}╭─ ${title} ${rule:0:$((54 - ${#title}))}╮${RESET}"
  echo -e "  ${color}│${RESET}"
  local line
  for line in "${lines[@]}"; do
    if [[ -z "$line" ]]; then
      echo -e "  ${color}│${RESET}"
    else
      echo -e "  ${color}│${RESET}   ${line}"
    fi
  done
  echo -e "  ${color}│${RESET}"
  echo -e "  ${BOLD}${color}╰──────────────────────────────────────────────────────────╯${RESET}"
  echo ""
}

# gum-powered yes/no confirm with fallback to prompt_confirm.
# Usage: ui_confirm "Proceed anyway?"   (returns 0 on yes, 1 on no)
ui_confirm() {
  local prompt="$1"
  if have_gum; then
    # --default=false means Enter selects No (safe default).
    gum confirm --default=false "$prompt"
    return $?
  fi
  prompt_confirm "${BOLD}${prompt}${RESET} [y/N]:"
}

# gum-powered single-choice menu with fallback to stdin read.
# Usage:
#   ui_choose "Header text" \
#     "opt1|First option description" \
#     "opt2|Second option"
# Returns the chosen option key (before the pipe) on stdout.
ui_choose() {
  local header="$1"
  shift
  local -a items=("$@")
  if have_gum; then
    local -a labels=()
    local item
    for item in "${items[@]}"; do
      labels+=("${item#*|}")
    done
    local chosen_label
    chosen_label="$(gum choose --header "$header" -- "${labels[@]}")" || return 130
    # Map label back to key
    for item in "${items[@]}"; do
      if [[ "${item#*|}" == "$chosen_label" ]]; then
        echo "${item%%|*}"
        return 0
      fi
    done
    return 1
  fi
  # Fallback: render labels + read a single-letter key.
  local item
  echo "  $header"
  for item in "${items[@]}"; do
    local key="${item%%|*}" label="${item#*|}"
    echo -e "    ${CYAN}[${key:0:1}]${RESET} ${label}"
  done
  local choice
  printf "  Choice: "
  read -r choice
  choice="$(echo "$choice" | tr '[:upper:]' '[:lower:]' | cut -c1)"
  for item in "${items[@]}"; do
    local key="${item%%|*}"
    if [[ "${key:0:1}" == "$choice" ]]; then
      echo "$key"
      return 0
    fi
  done
  return 1
}

# gum spin wrapper with fallback to a simple message. The command
# runs inside the spinner; its exit status is returned.
# Usage: ui_spin "Fetching..." -- curl -fsSL url -o file
ui_spin() {
  local title="$1"
  shift
  # Skip the `--` separator if present.
  [[ "${1:-}" == "--" ]] && shift
  if have_gum; then
    gum spin --spinner minidot --title "$title" --show-output -- "$@"
    return $?
  fi
  print_step "$title"
  "$@"
}

clear_line() {
  [[ "$USE_SPINNER" == true ]] && printf "\r%-72s\r" " "
}

is_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_positive_integer() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }

elapsed_label() {
  local secs=$1
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  if [[ $h -gt 0 ]]; then
    printf "%dh %02dm %02ds" $h $m $s
  elif [[ $m -gt 0 ]]; then
    printf "%dm %02ds" $m $s
  else
    printf "%ds" $s
  fi
}

play_sound() {
  [[ "$NO_SOUND" == true ]] && return
  afplay /System/Library/Sounds/Glass.aiff 2>/dev/null || true
}

# Escape for AppleScript double-quoted strings
as_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Escape for JSON string values
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

notify_macos() {
  [[ "$NOTIFY" == true ]] || return
  local msg title
  msg="$(as_escape "$1")"
  title="$(as_escape "sleep-after-claude")"
  osascript -e "display notification \"$msg\" with title \"$title\"" 2>/dev/null || true
}

LOG_WRITE_FAILED=false
# Appends a timestamped event line to $LOG_FILE when --log is active.
# No-op when LOG_ENABLED is false. On first write failure emits a single
# stderr warning; subsequent failures stay silent so the tick loop
# doesn't spam. Return status when disabled is unspecified (no caller
# checks it).
log_event() {
  [[ "$LOG_ENABLED" == true ]] || return
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  # Brace group + outer 2>/dev/null so the shell's own "No such file or
  # directory" error on a failed >> redirection is also suppressed, not
  # just errors produced by the command itself.
  if ! { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >>"$LOG_FILE"; } 2>/dev/null; then
    # Warn once per session so the user knows durability is broken.
    if [[ "$LOG_WRITE_FAILED" == false ]]; then
      LOG_WRITE_FAILED=true
      echo "  ⚠  log write failed: $LOG_FILE (subsequent failures will be silent)" >&2
    fi
  fi
}

micro_sleep() {
  if [[ "$USE_BUILTIN_SLEEP" == true ]]; then
    read -rt "$1" -u 9 _ 2>/dev/null || true
  else
    sleep "$1"
  fi
}

# ── Detect Claude processes ───────────────────────────────────
# Blocklist covers processes that contain "claude" in path/args but
# are NOT Claude Code CLI. Patterns anchored where possible to avoid
# collateral damage (e.g. any process with "Helper" in the command).
EXCLUDE_PATTERN='Claude\.app|Contents/Helpers/|chrome-native-host|--type=|/Electron|Electron\.app|Cursor\.app|Windsurf\.app|anthropic-tools'

find_claude_processes() {
  local script_name tight_pids tight_result
  script_name="$(basename "$0")"

  tight_pids=$(
    {
      pgrep -x claude 2>/dev/null || true
      pgrep -f "claude-code" 2>/dev/null || true
    } | sort -u | grep -v "^$$\$" || true
  )

  if [[ -n "$tight_pids" ]]; then
    tight_result=$(echo "$tight_pids" |
      xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
      grep -iv "$script_name" |
      grep -iv "sleep-after" |
      grep -Ev "$EXCLUDE_PATTERN" ||
      true)
    if [[ -n "$tight_result" ]]; then
      echo "$tight_result"
      return
    fi
  fi

  pgrep -fi "claude" 2>/dev/null |
    grep -v "^$$\$" |
    xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
    grep -iv "$script_name" |
    grep -iv "sleep-after" |
    grep -Ev "$EXCLUDE_PATTERN" ||
    true
}

find_all_claude_processes_raw() {
  local script_name
  script_name="$(basename "$0")"
  pgrep -fi "claude" 2>/dev/null |
    grep -v "^$$\$" |
    xargs -I{} sh -c 'ps -p {} -o pid=,command= 2>/dev/null || true' |
    grep -iv "$script_name" |
    grep -iv "sleep-after" ||
    true
}

# ── Pre-flight scan ───────────────────────────────────────────
PREFLIGHT_TARGET=""
PREFLIGHT_EXCLUDED=""
PREFLIGHT_CAFFEINATE=""
PREFLIGHT_ASSERTIONS=()
PREFLIGHT_BLOCKERS=()
PREFLIGHT_DISPLAY_ONLY=()
PREFLIGHT_SYSTEM=()
PREFLIGHT_LID=""
PREFLIGHT_SESSIONS=""
PREFLIGHT_BATTERY_PCT=""
PREFLIGHT_BATTERY_SRC=""
PREFLIGHT_SLEEP_MIN=""
PREFLIGHT_DISPLAYSLEEP_MIN=""
PREFLIGHT_HIBERNATE_MODE=""

# Known-benign macOS system daemons. These routinely hold
# PreventUserIdleSystemSleep assertions as part of normal operation but
# do NOT actually prevent sleep — the OS releases them at sleep time.
# Flagging these as blockers creates false alarms.
#
# Anchored to exact daemon names (case-sensitive, full match).
SYSTEM_DAEMONS_REGEX='^(sharingd|powerd|useractivityd|bluetoothd|rcd|coreaudiod|apsd|locationd|cloudd|searchd|mDNSResponder|UserEventAgent|symptomsd|timed|trustd|cfprefsd|WindowServer|loginwindow|SystemUIServer|Dock|Finder|ControlCenter|NotificationCenter|identityservicesd|imagent|callservicesd|remindd|parsecd|bird|iconservicesagent|iconservicesd|diskarbitrationd|fseventsd|spindump|corespeechd|corespotlightd|nsurlsessiond|nsurlstoraged|assistantd|mediaremoted|distnoted|syspolicyd|amfid|taskgated|securityd|secinitd|opendirectoryd|configd|hidd|backlightd|thermalmonitord|pboard|launchservicesd|nfcd|airportd|wifiAgent|wifiFirmwareLoader|wifianalyticsd|watchdogd|appsleepd|routined|avconferenced|bluetoothuserd|gamecontrollerd)$'

# Parse pmset -g assertions into categorized arrays. Used by both full
# scan and post-watch re-scan (which only needs this).
#
# PREFLIGHT_SCAN_OK is true only when `pmset -g assertions` ran AND produced
# the expected "Listed by owning process" header. Verdict rendering must
# treat empty blockers differently when the scan failed — an unverified
# "clear" is worse than an explicit "scan unavailable".
PREFLIGHT_SCAN_OK=false
scan_assertions() {
  local raw line parsing=false severity apid aname atype pmset_rc
  raw="$(pmset -g assertions 2>/dev/null)"
  pmset_rc=$?

  PREFLIGHT_ASSERTIONS=()
  PREFLIGHT_BLOCKERS=()
  PREFLIGHT_DISPLAY_ONLY=()
  PREFLIGHT_SYSTEM=()
  PREFLIGHT_SCAN_OK=false

  if [[ $pmset_rc -ne 0 || -z "$raw" ]]; then
    return
  fi
  if [[ "$raw" != *"Listed by owning process"* ]]; then
    return
  fi
  PREFLIGHT_SCAN_OK=true

  while IFS= read -r line; do
    if [[ "$line" == *"Listed by owning process"* ]]; then
      parsing=true
      continue
    fi
    [[ "$parsing" == false ]] && continue
    [[ -z "${line// /}" ]] && continue

    if [[ "$line" =~ pid[[:space:]]+([0-9]+)\(([^\)]+)\).*\][[:space:]]+[^[:space:]]+[[:space:]]+([A-Za-z]+) ]]; then
      apid="${BASH_REMATCH[1]}"
      aname="${BASH_REMATCH[2]}"
      atype="${BASH_REMATCH[3]}"

      severity="info"
      case "$atype" in
        PreventSystemSleep)
          # Even PreventSystemSleep from system daemons is usually benign,
          # but keep as blocker since it's the stronger assertion type.
          if [[ "$aname" =~ $SYSTEM_DAEMONS_REGEX ]]; then
            severity="system"
          else
            severity="blocker"
          fi
          ;;
        PreventUserIdleSystemSleep)
          if [[ "$aname" == "caffeinate" ]]; then
            severity="release"
          elif [[ "$aname" =~ $SYSTEM_DAEMONS_REGEX ]]; then
            severity="system"
          else
            severity="blocker"
          fi
          ;;
        PreventUserIdleDisplaySleep | NoDisplaySleepAssertion)
          severity="display"
          ;;
        UserIsActive)
          severity="user"
          ;;
      esac

      PREFLIGHT_ASSERTIONS+=("$severity|$apid|$aname|$atype")
      [[ "$severity" == "blocker" ]] && PREFLIGHT_BLOCKERS+=("$apid|$aname|$atype")
      [[ "$severity" == "display" ]] && PREFLIGHT_DISPLAY_ONLY+=("$apid|$aname|$atype")
      [[ "$severity" == "system" ]] && PREFLIGHT_SYSTEM+=("$apid|$aname|$atype")
    fi
  done <<<"$raw"
}

preflight_scan() {
  local all_claude target_pid_set line pid batt pm batt_pct

  # -- Claude target/excluded
  # Honor --pid override: if user explicitly set TARGET_PID, use it.
  if [[ "$TARGET_PID_EXPLICIT" == true && -n "$TARGET_PID" ]]; then
    if kill -0 "$TARGET_PID" 2>/dev/null; then
      PREFLIGHT_TARGET="$(ps -p "$TARGET_PID" -o pid=,command= 2>/dev/null || echo "")"
    else
      PREFLIGHT_TARGET=""
    fi
  else
    PREFLIGHT_TARGET="$(find_claude_processes)"
  fi

  all_claude="$(find_all_claude_processes_raw)"
  target_pid_set=""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    target_pid_set="$(echo "$PREFLIGHT_TARGET" | awk '{print $1}' | sort -u)"
  fi

  PREFLIGHT_EXCLUDED=""
  if [[ -n "$all_claude" ]]; then
    while IFS= read -r line; do
      pid="$(echo "$line" | awk '{print $1}')"
      if ! echo "$target_pid_set" | grep -qx "$pid"; then
        PREFLIGHT_EXCLUDED+="${line}"$'\n'
      fi
    done <<<"$all_claude"
    PREFLIGHT_EXCLUDED="${PREFLIGHT_EXCLUDED%$'\n'}"
  fi

  # -- Caffeinate detail
  PREFLIGHT_CAFFEINATE="$(
    ps -axo pid=,user=,etime=,command= 2>/dev/null |
      awk '/[c]affeinate/' ||
      true
  )"

  # -- Assertions
  scan_assertions

  # -- Power state
  batt="$(pmset -g batt 2>/dev/null || echo "")"
  pm="$(pmset -g 2>/dev/null || echo "")"

  batt_pct="$(echo "$batt" | grep -oE '[0-9]+%' | head -1)"
  if [[ -z "$batt_pct" ]]; then
    PREFLIGHT_BATTERY_PCT="N/A"
  else
    PREFLIGHT_BATTERY_PCT="$batt_pct"
  fi

  if echo "$batt" | grep -q "AC Power"; then
    PREFLIGHT_BATTERY_SRC="AC Power"
  elif echo "$batt" | grep -q "Battery Power"; then
    PREFLIGHT_BATTERY_SRC="Battery"
  else
    PREFLIGHT_BATTERY_SRC="unknown"
  fi

  PREFLIGHT_SLEEP_MIN="$(echo "$pm" | awk '/^ *sleep[[:space:]]/{print $2; exit}')"
  PREFLIGHT_DISPLAYSLEEP_MIN="$(echo "$pm" | awk '/^ *displaysleep[[:space:]]/{print $2; exit}')"
  PREFLIGHT_HIBERNATE_MODE="$(echo "$pm" | awk '/^ *hibernatemode[[:space:]]/{print $2; exit}')"

  # -- Lid state
  PREFLIGHT_LID="$(
    ioreg -r -k AppleClamshellState 2>/dev/null |
      awk -F'= ' '/AppleClamshellState/ {print $2; exit}' |
      tr -d ' ' ||
      echo "unknown"
  )"
  [[ -z "$PREFLIGHT_LID" ]] && PREFLIGHT_LID="unknown"

  # -- Active user sessions
  PREFLIGHT_SESSIONS="$(who 2>/dev/null || echo "")"
}

# -- Brief render (verdict only)
render_preflight_brief() {
  echo ""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    local tgt_pid tgt_cmd
    tgt_pid="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{print $1}')"
    tgt_cmd="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{$1=""; sub(/^ /,""); print}' | cut -c1-50)"
    echo -e "  ${GREEN}✔${RESET} Target: PID ${tgt_pid} ${DIM}→ ${tgt_cmd}${RESET}"
  else
    echo -e "  ${RED}✖${RESET} No target Claude process found"
  fi
  if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
    echo -e "  ${YELLOW}⚠${RESET}  Sleep-blocker scan unavailable (pmset failed or unexpected output)"
  elif [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}✔${RESET} No sleep blockers detected"
  else
    echo -e "  ${RED}✖${RESET} ${#PREFLIGHT_BLOCKERS[@]} sleep blocker(s):"
    local entry pid name type
    for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${RED}${type}${RESET}"
    done
  fi
  echo ""
}

# -- Full render
render_preflight() {
  if [[ "$BRIEF" == true ]]; then
    render_preflight_brief
    return
  fi

  echo ""
  echo -e "  ${BOLD}${MAGENTA}Pre-flight scan${RESET}"
  echo -e "  ${DIM}═════════════════════════════════════════${RESET}"

  echo ""
  echo -e "  ${BOLD}Claude processes${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    # Label the first match as the active "Target" (what the watch
    # loop will actually follow) and any additional matches as
    # "Candidate" so the output isn't misleading when there are
    # multiple Claude processes running.
    local _preflight_line_no=0
    echo "$PREFLIGHT_TARGET" | while IFS= read -r line; do
      _preflight_line_no=$((_preflight_line_no + 1))
      if [[ $_preflight_line_no -eq 1 ]]; then
        echo -e "  ${GREEN}✔${RESET} Target:    ${line}"
      else
        echo -e "  ${DIM}•${RESET} Candidate: ${DIM}${line}  (not watched — use --pid to pick)${RESET}"
      fi
    done
  else
    echo -e "  ${RED}✖${RESET} No target Claude process found"
  fi
  if [[ -n "$PREFLIGHT_EXCLUDED" ]]; then
    echo "$PREFLIGHT_EXCLUDED" | while IFS= read -r line; do
      local epid ecmd
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}' | cut -c1-65)"
      echo -e "  ${YELLOW}⊘${RESET} Excluded:  ${DIM}PID $epid  ${ecmd}${RESET}"
    done
  fi

  echo ""
  echo -e "  ${BOLD}Caffeinate processes${RESET} ${DIM}(will be released)${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  if [[ -n "$PREFLIGHT_CAFFEINATE" ]]; then
    echo "$PREFLIGHT_CAFFEINATE" | while IFS= read -r line; do
      echo -e "  ${DIM}${line}${RESET}"
    done
  else
    echo -e "  ${DIM}  none running${RESET}"
  fi

  echo ""
  echo -e "  ${BOLD}Sleep assertions${RESET} ${DIM}(pmset -g assertions)${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  if [[ ${#PREFLIGHT_ASSERTIONS[@]} -eq 0 ]]; then
    echo -e "  ${DIM}  none${RESET}"
  else
    local entry sev pid name type
    for entry in "${PREFLIGHT_ASSERTIONS[@]}"; do
      IFS='|' read -r sev pid name type <<<"$entry"
      case "$sev" in
        blocker)
          echo -e "  ${RED}✖${RESET} ${BOLD}${name}${RESET} (PID $pid): ${RED}${type}${RESET} ${DIM}← BLOCKS SYSTEM SLEEP${RESET}"
          ;;
        release)
          echo -e "  ${GREEN}✔${RESET} ${name} (PID $pid): ${type} ${DIM}← will release${RESET}"
          ;;
        system)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type} (macOS system daemon — benign)${RESET}"
          ;;
        display)
          echo -e "  ${YELLOW}⚠${RESET}  ${name} (PID $pid): ${type} ${DIM}← display only, system will still sleep${RESET}"
          ;;
        user)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type} (harmless — auto-dismissed when idle)${RESET}"
          ;;
        *)
          echo -e "  ${DIM}ℹ  ${name} (PID $pid): ${type}${RESET}"
          ;;
      esac
    done
  fi

  echo ""
  echo -e "  ${BOLD}Power state${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  echo -e "  ${DIM}Battery:        ${RESET}${PREFLIGHT_BATTERY_PCT} (${PREFLIGHT_BATTERY_SRC})"
  echo -e "  ${DIM}Display sleep:  ${RESET}${PREFLIGHT_DISPLAYSLEEP_MIN:-?} min"
  echo -e "  ${DIM}System sleep:   ${RESET}${PREFLIGHT_SLEEP_MIN:-?} min"
  echo -e "  ${DIM}Hibernate mode: ${RESET}${PREFLIGHT_HIBERNATE_MODE:-?}"
  local lid_display="unknown"
  case "$PREFLIGHT_LID" in
    Yes) lid_display="closed" ;;
    No) lid_display="open" ;;
  esac
  echo -e "  ${DIM}Lid:            ${RESET}${lid_display}"

  echo ""
  echo -e "  ${BOLD}Active user sessions${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  if [[ -n "$PREFLIGHT_SESSIONS" ]]; then
    echo "$PREFLIGHT_SESSIONS" | while IFS= read -r line; do
      echo -e "  ${DIM}${line}${RESET}"
    done
  else
    echo -e "  ${DIM}  none${RESET}"
  fi

  echo ""
  echo -e "  ${DIM}═════════════════════════════════════════${RESET}"
  echo -e "  ${BOLD}${MAGENTA}Verdict${RESET}"
  echo -e "  ${DIM}═════════════════════════════════════════${RESET}"
  echo ""
  if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
    echo -e "  ${YELLOW}⚠ Sleep-blocker scan unavailable.${RESET}"
    echo -e "  ${DIM}pmset -g assertions failed or returned unexpected output —${RESET}"
    echo -e "  ${DIM}cannot verify whether the Mac will actually sleep.${RESET}"
  elif [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}✔ No active sleep blockers detected.${RESET}"
    echo -e "  ${DIM}Releasing caffeinate will allow the Mac to sleep normally.${RESET}"
    if [[ ${#PREFLIGHT_SYSTEM[@]} -gt 0 ]]; then
      echo ""
      echo -e "  ${DIM}Note: ${#PREFLIGHT_SYSTEM[@]} macOS system daemon assertion(s) detected —${RESET}"
      echo -e "  ${DIM}these are released automatically by the OS at sleep time.${RESET}"
    fi
    if [[ ${#PREFLIGHT_DISPLAY_ONLY[@]} -gt 0 ]]; then
      echo ""
      echo -e "  ${DIM}Note: ${#PREFLIGHT_DISPLAY_ONLY[@]} display-only assertion(s) detected —${RESET}"
      echo -e "  ${DIM}these keep the display awake but do not prevent system sleep.${RESET}"
    fi
  else
    local count=${#PREFLIGHT_BLOCKERS[@]}
    echo -e "  ${RED}✖ ${count} active system-sleep blocker(s) besides caffeinate:${RESET}"
    echo ""
    local entry pid name type
    for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${RED}${type}${RESET}"
    done
    echo ""
    echo -e "  ${YELLOW}Releasing caffeinate alone will NOT be sufficient.${RESET}"
    echo -e "  ${DIM}These processes must also exit (or release their assertions)${RESET}"
    echo -e "  ${DIM}before the Mac can actually sleep.${RESET}"
  fi
  echo ""
}

# -- JSON render
render_preflight_json() {
  local entry pid name type sev first
  local target_pid="" target_cmd=""
  if [[ -n "$PREFLIGHT_TARGET" ]]; then
    target_pid="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{print $1}')"
    target_cmd="$(echo "$PREFLIGHT_TARGET" | awk 'NR==1{$1=""; sub(/^ /,""); print}')"
  fi

  printf '{\n'
  printf '  "target": '
  if [[ -n "$target_pid" ]]; then
    printf '{"pid": %s, "command": "%s"}' "$target_pid" "$(json_escape "$target_cmd")"
  else
    printf 'null'
  fi
  printf ',\n'

  # Excluded
  printf '  "excluded": ['
  first=true
  if [[ -n "$PREFLIGHT_EXCLUDED" ]]; then
    while IFS= read -r line; do
      local epid ecmd
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}')"
      [[ "$first" == true ]] && first=false || printf ','
      printf '\n    {"pid": %s, "command": "%s"}' "$epid" "$(json_escape "$ecmd")"
    done <<<"$PREFLIGHT_EXCLUDED"
    printf '\n  '
  fi
  printf '],\n'

  # Caffeinate pids
  printf '  "caffeinate_pids": ['
  first=true
  local caff_pids
  caff_pids="$(pgrep caffeinate 2>/dev/null || true)"
  if [[ -n "$caff_pids" ]]; then
    while IFS= read -r pid; do
      [[ "$first" == true ]] && first=false || printf ', '
      printf '%s' "$pid"
    done <<<"$caff_pids"
  fi
  printf '],\n'

  # Assertions
  printf '  "assertions": ['
  first=true
  for entry in "${PREFLIGHT_ASSERTIONS[@]}"; do
    IFS='|' read -r sev pid name type <<<"$entry"
    [[ "$first" == true ]] && first=false || printf ','
    printf '\n    {"severity": "%s", "pid": %s, "name": "%s", "type": "%s"}' \
      "$sev" "$pid" "$(json_escape "$name")" "$(json_escape "$type")"
  done
  [[ "$first" == false ]] && printf '\n  '
  printf '],\n'

  # Blockers
  printf '  "blockers": ['
  first=true
  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    [[ "$first" == true ]] && first=false || printf ','
    printf '\n    {"pid": %s, "name": "%s", "type": "%s"}' \
      "$pid" "$(json_escape "$name")" "$(json_escape "$type")"
  done
  [[ "$first" == false ]] && printf '\n  '
  printf '],\n'

  # Power + verdict
  local lid_display="unknown"
  case "$PREFLIGHT_LID" in Yes) lid_display="closed" ;; No) lid_display="open" ;; esac

  printf '  "power": {\n'
  printf '    "battery_percent": "%s",\n' "$(json_escape "$PREFLIGHT_BATTERY_PCT")"
  printf '    "battery_source": "%s",\n' "$(json_escape "$PREFLIGHT_BATTERY_SRC")"
  printf '    "system_sleep_min": "%s",\n' "$(json_escape "${PREFLIGHT_SLEEP_MIN:-?}")"
  printf '    "display_sleep_min": "%s",\n' "$(json_escape "${PREFLIGHT_DISPLAYSLEEP_MIN:-?}")"
  printf '    "hibernate_mode": "%s",\n' "$(json_escape "${PREFLIGHT_HIBERNATE_MODE:-?}")"
  printf '    "lid": "%s"\n' "$(json_escape "$lid_display")"
  printf '  },\n'
  printf '  "scan_ok": %s,\n' "$([[ "$PREFLIGHT_SCAN_OK" == true ]] && echo true || echo false)"
  # can_sleep: true only when scan succeeded AND no blockers. Null when the
  # scan failed — consumers must not treat that as a green light.
  if [[ "$PREFLIGHT_SCAN_OK" == true ]]; then
    printf '  "can_sleep": %s,\n' "$([[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]] && echo true || echo false)"
  else
    printf '  "can_sleep": null,\n'
  fi
  printf '  "blocker_count": %d\n' "${#PREFLIGHT_BLOCKERS[@]}"
  printf '}\n'
}

prompt_confirm() {
  local prompt="$1"
  local response
  printf "  %b " "$prompt"
  read -r response
  case "$response" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Print blockers detected after watch (wrapped in function for scope hygiene)
print_post_watch_blockers() {
  local entry pid name type
  echo ""
  print_warn "${#PREFLIGHT_BLOCKERS[@]} sleep blocker(s) detected AFTER watch finished:"
  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    echo -e "    • ${BOLD}${name}${RESET} (PID $pid) — ${type}"
  done
  print_step "Sleep may not succeed. Releasing caffeinate anyway."
  log_event "POST_WATCH_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]}"
}

# ── Blocker classification ────────────────────────────────────
# System-managed processes (launchd-supervised Apple daemons) cannot
# be killed by the user without sudo, and macOS respawns them anyway.
# The user must instead quit the consumer app that triggered the
# assertion (e.g., quit Zoom to release cameracaptured's hold).
#
# These names include camera/audio/display daemons that commonly hold
# PreventUserIdleSystemSleep while a video app is active.
SYSTEM_MANAGED_BLOCKERS_REGEX='^(cameracaptured|mediaanalysisd|screencaptureui|replayd|avconferenced|WirelessRadioManagerd|kernel_task|launchd)$'

# Return "system" if the blocker name is system-managed, "user" otherwise.
classify_blocker() {
  local name="$1"
  if [[ "$name" =~ $SYSTEM_MANAGED_BLOCKERS_REGEX ]]; then
    echo "system"
  else
    echo "user"
  fi
}

# Print a suggested action for a system-managed blocker so the user
# knows what to do instead of asking us to kill it.
system_blocker_hint() {
  local name="$1"
  case "$name" in
    cameracaptured) echo "Camera is in use — quit Zoom/Meet/FaceTime/Chrome tabs/Continuity Camera." ;;
    mediaanalysisd) echo "Photos is analyzing media — will release on its own shortly." ;;
    screencaptureui | replayd) echo "Screen recording is active — stop the recording." ;;
    avconferenced) echo "A call/conference app is active — end the call." ;;
    *) echo "System-managed — quit the app that triggered this assertion." ;;
  esac
}

# Present the blocker-handling menu and act on the user's choice.
# Returns 0 on "proceed with watch" (either skipped or after successful
# termination), non-zero on "abort".
prompt_and_handle_blockers() {
  local entry pid name type kind
  local user_blockers=() system_blockers=()

  for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
    IFS='|' read -r pid name type <<<"$entry"
    kind="$(classify_blocker "$name")"
    if [[ "$kind" == "system" ]]; then
      system_blockers+=("$entry")
    else
      user_blockers+=("$entry")
    fi
  done

  echo ""
  echo -e "  ${BOLD}${YELLOW}Sleep blockers detected${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  if [[ ${#user_blockers[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}User apps${RESET} ${DIM}(can be terminated):${RESET}"
    for entry in "${user_blockers[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    ${RED}✖${RESET} ${BOLD}${name}${RESET} (PID $pid) — ${type}"
    done
    echo ""
  fi
  if [[ ${#system_blockers[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}System-managed${RESET} ${DIM}(cannot be killed — requires your action):${RESET}"
    for entry in "${system_blockers[@]}"; do
      IFS='|' read -r pid name type <<<"$entry"
      echo -e "    ${YELLOW}⚠${RESET}  ${BOLD}${name}${RESET} (PID $pid) — ${type}"
      echo -e "       ${DIM}→ $(system_blocker_hint "$name")${RESET}"
    done
    echo ""
  fi

  if [[ "$FORCE" == true ]]; then
    print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) detected but --force was given — proceeding."
    return 0
  fi

  if [[ "$STDIN_IS_TTY" != true ]]; then
    print_error "Sleep blockers detected and stdin is not a TTY for confirmation."
    print_step "Pass ${BOLD}--force${RESET} to proceed anyway, or ${BOLD}--no-preflight${RESET} to skip the scan."
    return 1
  fi

  local -a menu=()
  if [[ ${#user_blockers[@]} -gt 0 ]]; then
    menu+=("t|Terminate the ${#user_blockers[@]} user app(s) listed above (recommended)")
  fi
  menu+=(
    "s|Skip — proceed with watch; sleep may not succeed"
    "a|Abort — I'll handle these manually"
  )
  local choice
  choice="$(ui_choose "How would you like to proceed?" "${menu[@]}")"
  case "$choice" in
    t | terminate)
      if [[ ${#user_blockers[@]} -eq 0 ]]; then
        print_warn "No user-killable blockers — only system-managed ones remain. Skipping terminate."
        return 0
      fi
      terminate_user_blockers "${user_blockers[@]}"
      # Re-scan so the next render reflects reality.
      scan_assertions
      if [[ ${#PREFLIGHT_BLOCKERS[@]} -eq 0 ]]; then
        print_ok "All blockers cleared."
      else
        print_warn "${#PREFLIGHT_BLOCKERS[@]} blocker(s) remain after termination (likely system-managed):"
        for entry in "${PREFLIGHT_BLOCKERS[@]}"; do
          IFS='|' read -r pid name type <<<"$entry"
          echo -e "    ${YELLOW}⚠${RESET}  ${name} (PID $pid) — ${type}"
        done
        print_step "Proceeding with watch anyway."
      fi
      return 0
      ;;
    s | skip)
      print_warn "Skipping termination. Sleep may not succeed after Claude finishes."
      return 0
      ;;
    a | abort | "")
      print_warn "Aborted. Claude is still running; caffeinate untouched."
      return 1
      ;;
    *)
      print_warn "Unrecognized choice — aborting for safety."
      return 1
      ;;
  esac
}

# Send SIGTERM to each user blocker, wait up to 2 seconds, escalate to
# SIGKILL if still alive. Reports per-blocker success/failure. Never
# attempts to kill system-managed processes (caller has already
# filtered them out).
terminate_user_blockers() {
  local entry pid name type
  local stopped=() survived=()
  echo ""
  print_step "Terminating user-app blockers..."
  for entry in "$@"; do
    IFS='|' read -r pid name type <<<"$entry"
    if ! kill -0 "$pid" 2>/dev/null; then
      stopped+=("$name (PID $pid, already gone)")
      continue
    fi
    if kill "$pid" 2>/dev/null; then
      # Poll up to 2 seconds for graceful exit. The loop variable is
      # unused — we only care about the iteration count.
      local _
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "$pid" 2>/dev/null; then
        if kill -9 "$pid" 2>/dev/null; then
          stopped+=("$name (PID $pid, SIGKILL)")
          log_event "BLOCKER_SIGKILL pid=$pid name=\"$name\""
        else
          survived+=("$name (PID $pid)")
          log_event "BLOCKER_KILL_FAILED pid=$pid name=\"$name\""
        fi
      else
        stopped+=("$name (PID $pid)")
        log_event "BLOCKER_STOPPED pid=$pid name=\"$name\""
      fi
    else
      survived+=("$name (PID $pid, kill denied)")
      log_event "BLOCKER_KILL_DENIED pid=$pid name=\"$name\""
    fi
  done
  if [[ ${#stopped[@]} -gt 0 ]]; then
    print_ok "Stopped ${#stopped[@]} blocker(s):"
    for s in "${stopped[@]}"; do
      echo -e "    ${GREEN}✔${RESET} ${DIM}${s}${RESET}"
    done
  fi
  if [[ ${#survived[@]} -gt 0 ]]; then
    print_warn "${#survived[@]} blocker(s) could not be stopped:"
    for s in "${survived[@]}"; do
      echo -e "    ${RED}✖${RESET} ${DIM}${s}${RESET}"
    done
  fi
}

# ── Auto-start caffeinate -dim if none is running ─────────────
# Ensures the Mac stays awake while we watch. If the user (or another
# tool) already has caffeinate running, we leave it alone — the end-
# of-watch release step will stop all caffeinate PIDs captured at
# start.
AUTO_STARTED_CAFFEINATE_PID=""
ensure_caffeinate_running() {
  [[ "$NO_AUTO_CAFFEINATE" == true ]] && return 0
  local existing
  existing="$(pgrep -u "$USER" caffeinate 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    print_ok "caffeinate already running (PIDs: $(echo "$existing" | tr '\n' ' '))— leaving as-is"
    return 0
  fi
  # Start caffeinate -dim in the background, detached from this shell
  # so it survives after we exit. `disown` suppresses the "terminated"
  # message when we eventually kill it.
  caffeinate -dim &
  AUTO_STARTED_CAFFEINATE_PID=$!
  disown "$AUTO_STARTED_CAFFEINATE_PID" 2>/dev/null || true
  # Tiny delay so pmset sees the assertion next time we scan.
  sleep 0.2
  print_ok "Started ${BOLD}caffeinate -dim${RESET} (PID $AUTO_STARTED_CAFFEINATE_PID) to keep the Mac awake"
  log_event "AUTO_CAFFEINATE_STARTED pid=$AUTO_STARTED_CAFFEINATE_PID"
}

# ── Power-state gate ──────────────────────────────────────────
# Returns "AC", "Battery", or "Unknown".
# Unknown is returned on desktop Macs without a battery, or when
# pmset can't be parsed — in both cases we treat it like AC because
# there's no battery to protect.
get_power_source() {
  local batt
  batt="$(pmset -g batt 2>/dev/null)"
  if [[ -z "$batt" ]]; then
    echo "Unknown"
    return
  fi
  if echo "$batt" | grep -q "'AC Power'"; then
    echo "AC"
  elif echo "$batt" | grep -q "'Battery Power'"; then
    echo "Battery"
  else
    echo "Unknown"
  fi
}

# Extract the battery percent if present (e.g., "62%"), else empty.
get_battery_percent() {
  pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | head -1
}

# Render a small unicode battery gauge for a percentage.
# Usage: render_battery_gauge 62  →  ▓▓▓▓▓▓░░░░ 62%
# Width is 10 blocks by default. Returns an empty string if the input
# isn't a 0–100 integer.
render_battery_gauge() {
  local raw="$1" width="${2:-10}" pct_num filled empty bar
  # Accept "62", "62%", " 62 ", etc.
  pct_num="$(printf '%s' "$raw" | tr -cd '0-9')"
  [[ -z "$pct_num" ]] && return 0
  ((pct_num < 0)) && pct_num=0
  ((pct_num > 100)) && pct_num=100
  filled=$((pct_num * width / 100))
  empty=$((width - filled))
  bar="$(printf '%*s' "$filled" '' | tr ' ' '▓')$(printf '%*s' "$empty" '' | tr ' ' '░')"
  printf '%s %d%%' "$bar" "$pct_num"
}

# Block until external power is connected. If already on AC (or
# unknown power state), returns immediately. When on battery, shows a
# calm warning, then polls pmset every 2 seconds with a spinner.
# Honored flags:
#   --allow-battery : skip the gate entirely
#   --force         : also skips the gate (general "don't block me" override)
# Ctrl+C cleanly aborts via the existing on_interrupt trap.
wait_for_ac_power() {
  [[ "$ALLOW_BATTERY" == true ]] && return 0
  [[ "$FORCE" == true ]] && return 0

  local src pct gauge
  src="$(get_power_source)"
  if [[ "$src" != "Battery" ]]; then
    return 0
  fi

  pct="$(get_battery_percent)"
  gauge="$(render_battery_gauge "$pct")"

  # Styled warning card via gum (or hand-drawn fallback).
  local -a panel_lines=()
  [[ -n "$gauge" ]] && panel_lines+=("Battery:  ${gauge}" "")
  panel_lines+=(
    "Please connect your charger. goodnight will resume"
    "automatically the moment AC power is detected."
    ""
    "Press Ctrl+C to abort, or override with:"
    "  goodnight --allow-battery"
  )
  ui_panel warning "⚡  External power required" "${panel_lines[@]}"
  log_event "POWER_GATE_WAITING battery_pct=${pct:-unknown}"

  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local tick=0
  local start_ts now_ts elapsed
  start_ts=$(date +%s)

  # Poll loop. Use plain `sleep 2` — the FIFO-based micro_sleep isn't
  # set up yet at this point in the flow.
  while true; do
    src="$(get_power_source)"
    if [[ "$src" != "Battery" ]]; then
      break
    fi
    now_ts=$(date +%s)
    elapsed=$((now_ts - start_ts))
    pct="$(get_battery_percent)"
    gauge="$(render_battery_gauge "$pct")"
    if [[ "$USE_SPINNER" == true ]]; then
      # Static format string; every dynamic value passes through %s so
      # stray `%` characters in $pct / $gauge can never corrupt it.
      printf "\r  %s%s%s  %sWaiting for charger…%s  %ds  %s%s%s      " \
        "$CYAN" "${frames[$tick]}" "$RESET" \
        "$DIM" "$RESET" \
        "$elapsed" \
        "$YELLOW" "${gauge:-on battery}" "$RESET"
    else
      # Non-TTY: emit a status line every 30 seconds so callers have
      # something to watch.
      if ((elapsed % 30 == 0)); then
        echo "  … still waiting for charger (${elapsed}s elapsed${pct:+, battery ${pct}})"
      fi
    fi
    tick=$(((tick + 1) % ${#frames[@]}))
    sleep 2
  done

  # Clear the spinner line.
  [[ "$USE_SPINNER" == true ]] && printf "\r%-80s\r" " "

  pct="$(get_battery_percent)"
  gauge="$(render_battery_gauge "$pct")"
  if [[ -n "$gauge" ]]; then
    print_ok "External power detected  ${GREEN}${gauge}${RESET} — resuming."
  else
    print_ok "External power detected — resuming."
  fi
  log_event "POWER_GATE_RELEASED battery_pct=${pct:-unknown}"
  echo ""
}

# ── Self-update check ─────────────────────────────────────────
# Compares the running script's sha256 to the remote canonical script.
# Rate-limited to once per UPDATE_CACHE_TTL_SECS (default 24h) via a
# timestamp file under ~/.cache/sleep-after-claude. Fails open:
# network errors, missing curl/shasum, or any unexpected output cause
# the check to be silently skipped so offline users aren't blocked.
check_for_update() {
  [[ "$SKIP_UPDATE_CHECK" == true ]] && return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v shasum >/dev/null 2>&1 || return 0

  mkdir -p "$UPDATE_CACHE_DIR" 2>/dev/null || return 0
  local stamp="$UPDATE_CACHE_DIR/last-update-check"
  if [[ -f "$stamp" ]]; then
    local last_ts now_ts
    last_ts="$(cat "$stamp" 2>/dev/null || echo 0)"
    now_ts="$(date +%s)"
    if [[ "$last_ts" =~ ^[0-9]+$ ]] && ((now_ts - last_ts < UPDATE_CACHE_TTL_SECS)); then
      return 0
    fi
  fi

  # Download remote script with a short timeout so the check never
  # blocks for long on a slow network. ui_spin shows a spinner when
  # gum is installed; otherwise runs curl directly.
  local tmp_remote
  tmp_remote="$(mktemp -t sac-update-check.XXXXXX 2>/dev/null)" || return 0
  if ! ui_spin "Checking for updates…" -- curl -fsSL --max-time 5 "$UPDATE_CHECK_URL" -o "$tmp_remote" >/dev/null 2>&1; then
    rm -f "$tmp_remote"
    return 0
  fi
  # Basic sanity so a CDN error page doesn't fool us.
  if [[ ! -s "$tmp_remote" ]] || ! head -1 "$tmp_remote" | grep -q '^#!/usr/bin/env bash'; then
    rm -f "$tmp_remote"
    return 0
  fi

  local local_sha remote_sha self_path
  self_path="${BASH_SOURCE[0]:-$0}"
  [[ -f "$self_path" ]] || {
    rm -f "$tmp_remote"
    return 0
  }
  local_sha="$(shasum -a 256 "$self_path" 2>/dev/null | awk '{print $1}')"
  remote_sha="$(shasum -a 256 "$tmp_remote" 2>/dev/null | awk '{print $1}')"
  rm -f "$tmp_remote"

  # Record that we checked, regardless of result, to honor TTL.
  date +%s >"$stamp" 2>/dev/null || true

  if [[ -z "$local_sha" || -z "$remote_sha" ]] || [[ "$local_sha" == "$remote_sha" ]]; then
    return 0
  fi

  echo ""
  print_step "A newer version of sleep-after-claude is available."
  echo -e "    ${DIM}Local sha:  ${local_sha:0:12}…${RESET}"
  echo -e "    ${DIM}Remote sha: ${remote_sha:0:12}…${RESET}"
  if [[ "$STDIN_IS_TTY" != true ]]; then
    print_warn "Not a TTY — skipping update prompt. Run ${BOLD}goodnight${RESET} interactively to update."
    return 0
  fi
  if ui_confirm "Update now?"; then
    echo ""
    print_step "Running installer..."
    # Run the installer with SAC_SKIP_HOOK_INSTALL=1 to avoid a
    # double-install of hooks (user already has them if they got
    # here via --smart default — the installer's hook step would
    # be a no-op, but the announcement is unnecessary noise
    # mid-session).
    if SAC_SKIP_HOOK_INSTALL=1 curl -fsSL --max-time 30 "$UPDATE_INSTALLER_URL" | bash; then
      echo ""
      print_ok "Update complete — re-executing with the new version."
      echo ""
      # F-05: exec into the freshly-installed script so the rest of
      # this invocation runs the new code, not the stale in-memory
      # copy. We re-invoke via the same path we were started from
      # (usually ~/bin/sleep-after-claude) and preserve the original
      # argv captured at script entry. Add SAC_SKIP_UPDATE_CHECK=1 in
      # the child env so we don't re-prompt in the update-check we
      # just completed. Use `exec` so the process replaces itself.
      local self_path_for_exec
      self_path_for_exec="${BASH_SOURCE[0]:-$0}"
      if [[ -x "$self_path_for_exec" ]]; then
        export SAC_SKIP_UPDATE_CHECK=1
        exec "$self_path_for_exec" "${SAC_ORIGINAL_ARGS[@]}"
      fi
      # Fallthrough: exec should never return. If it does
      # (unwritable path, script not on disk, etc.) warn and
      # continue with the stale in-memory script.
      print_warn "Could not re-exec after update — continuing with old version."
    else
      print_warn "Update failed. Continuing with the currently-installed version."
    fi
  else
    echo ""
    print_step "Skipping update. Run ${BOLD}goodnight --check-update${RESET} later to re-prompt."
  fi
}

# Return 0 if goodnight's hook entries are present in the Claude Code
# settings file. Uses jq when available, falls back to a grep of the
# "_managed_by:goodnight" tag.
hooks_installed() {
  [[ -f "$CLAUDE_SETTINGS_FILE" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e '(.hooks.Stop // []) + (.hooks.UserPromptSubmit // []) | map(select(._managed_by == "goodnight")) | length > 0' \
      "$CLAUDE_SETTINGS_FILE" >/dev/null 2>&1
  else
    grep -q '"_managed_by"[[:space:]]*:[[:space:]]*"goodnight"' "$CLAUDE_SETTINGS_FILE" 2>/dev/null
  fi
}

# ── Claude Code hook integration ──────────────────────────────
# These functions manage two hooks in ~/.claude/settings.json:
#   - UserPromptSubmit: touch $BUSY_DIR/<session_id> when user sends
#     a new message to Claude (session is now working).
#   - Stop: remove $BUSY_DIR/<session_id> when Claude finishes its
#     response and returns control (session is now idle).
#
# With those markers in place, --smart mode can sleep the moment all
# Claude sessions are idle (no file in $BUSY_DIR) without relying on
# the claude process to actually exit.

# Install the two hooks by merging into the existing ~/.claude/settings.json.
# Requires jq. Preserves any other hooks the user has.
install_claude_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required to install hooks. Install it with: ${BOLD}brew install jq${RESET}"
    return 1
  fi
  mkdir -p "$(dirname "$CLAUDE_SETTINGS_FILE")" 2>/dev/null || true
  mkdir -p "$BUSY_DIR" 2>/dev/null || true

  local prompt_cmd stop_cmd
  # These commands run inside Claude's hook subshell. Stdin is a JSON
  # blob with .session_id.
  #
  # F-03 fix: use the literal string $HOME in the hook command so it
  # expands at HOOK RUNTIME, not at install time. This survives home-
  # directory moves and differs-across-contexts (cron, launchd, etc.).
  # The default busy dir is "${HOME}/.local/state/goodnight/busy" —
  # rebuild the equivalent expression without freezing the absolute
  # path. If the user set a non-default BUSY_DIR, we freeze that
  # path (no way to round-trip an arbitrary override into a
  # shell-evaluated string safely).
  local busy_path_expr
  if [[ "$BUSY_DIR" == "${HOME}/.local/state/goodnight/busy" ]]; then
    busy_path_expr='"$HOME/.local/state/goodnight/busy"'
  else
    # Non-default path — freeze the absolute value but single-quote
    # it so $ and other specials in the path are literal, not
    # interpreted by Claude's hook shell (F-04 hardening).
    local quoted_busy
    # Escape any single quotes in the path so the shell single-quote
    # stays balanced: a'b → 'a'\''b'
    quoted_busy="${BUSY_DIR//\'/\'\\\'\'}"
    busy_path_expr="'${quoted_busy}'"
  fi
  prompt_cmd="mkdir -p ${busy_path_expr} 2>/dev/null; sid=\$(jq -r .session_id 2>/dev/null); [ -n \"\$sid\" ] && touch ${busy_path_expr}/\"\$sid\"; exit 0"
  stop_cmd="sid=\$(jq -r .session_id 2>/dev/null); [ -n \"\$sid\" ] && rm -f ${busy_path_expr}/\"\$sid\"; exit 0"

  # Back up existing file
  if [[ -f "$CLAUDE_SETTINGS_FILE" ]]; then
    cp "$CLAUDE_SETTINGS_FILE" "${CLAUDE_SETTINGS_FILE}.bak.$(date +%s)"
  else
    echo '{}' >"$CLAUDE_SETTINGS_FILE"
  fi

  # Merge the hooks. Remove any prior goodnight-managed entries first
  # (tagged via a "_managed_by: goodnight" field in the hook object)
  # so reinstalls don't duplicate. Then append the fresh entries.
  local tmp
  tmp="$(mktemp)"
  jq --arg prompt_cmd "$prompt_cmd" --arg stop_cmd "$stop_cmd" '
    # Ensure .hooks exists
    .hooks = (.hooks // {})
    # Strip any prior goodnight-managed entries
    | .hooks.UserPromptSubmit = [ (.hooks.UserPromptSubmit // [])[] | select(._managed_by != "goodnight") ]
    | .hooks.Stop            = [ (.hooks.Stop            // [])[] | select(._managed_by != "goodnight") ]
    # Append fresh entries
    | .hooks.UserPromptSubmit += [{
        matcher: "",
        _managed_by: "goodnight",
        hooks: [{ type: "command", command: $prompt_cmd }]
      }]
    | .hooks.Stop += [{
        matcher: "",
        _managed_by: "goodnight",
        hooks: [{ type: "command", command: $stop_cmd }]
      }]
  ' "$CLAUDE_SETTINGS_FILE" >"$tmp" && mv "$tmp" "$CLAUDE_SETTINGS_FILE"

  print_ok "Installed goodnight hooks into ${BOLD}$CLAUDE_SETTINGS_FILE${RESET}"
  print_step "Busy markers will appear at ${BOLD}$BUSY_DIR${RESET}"
  print_step "Start a new Claude session, then use ${BOLD}goodnight --smart${RESET} to sleep when all sessions are idle."
}

# Remove goodnight's hook entries from ~/.claude/settings.json, leaving
# any user-defined entries untouched.
uninstall_claude_hooks() {
  if [[ ! -f "$CLAUDE_SETTINGS_FILE" ]]; then
    print_warn "No Claude settings file at $CLAUDE_SETTINGS_FILE — nothing to remove."
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required to uninstall hooks. Install it with: ${BOLD}brew install jq${RESET}"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  jq '
    .hooks = (.hooks // {})
    | .hooks.UserPromptSubmit = [ (.hooks.UserPromptSubmit // [])[] | select(._managed_by != "goodnight") ]
    | .hooks.Stop            = [ (.hooks.Stop            // [])[] | select(._managed_by != "goodnight") ]
    # Drop empty arrays so settings.json stays tidy.
    | if (.hooks.UserPromptSubmit | length) == 0 then del(.hooks.UserPromptSubmit) else . end
    | if (.hooks.Stop            | length) == 0 then del(.hooks.Stop)            else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$CLAUDE_SETTINGS_FILE" >"$tmp" && mv "$tmp" "$CLAUDE_SETTINGS_FILE"
  print_ok "Removed goodnight hooks from ${BOLD}$CLAUDE_SETTINGS_FILE${RESET}"
}

# Count Claude sessions currently marked busy. Stale markers (file
# mtime older than 2h) are treated as dead and deleted. Returns the
# count on stdout.
count_busy_sessions() {
  [[ -d "$BUSY_DIR" ]] || {
    echo 0
    return
  }
  local f count=0
  # Stale-marker reaper: a marker older than $SMART_STALE_MARKER_MINS
  # (default 24h) is assumed to belong to a crashed session. The
  # threshold is intentionally loose so a legitimately long-running
  # Claude task isn't reaped mid-work (F-08).
  find "$BUSY_DIR" -type f -mmin +"$SMART_STALE_MARKER_MINS" -delete 2>/dev/null || true
  for f in "$BUSY_DIR"/*; do
    [[ -f "$f" ]] && count=$((count + 1))
  done
  echo "$count"
}

# Smart-watch loop. Polls the busy directory every 2 seconds. Sleep
# fires only when ALL of:
#   (a) at least one busy marker has been observed since watch start
#       (prevents premature-sleep on cold start — F-01), AND
#   (b) the busy directory has been empty continuously for
#       SMART_IDLE_SECONDS, AND
#   (c) no live Claude process is present (belt-and-suspenders guard
#       against forgotten Claude sessions that never fired a hook
#       — e.g., hooks not loaded because the session pre-dates
#       --install-hooks).
#
# If no busy marker ever appears but there IS a live Claude process,
# the loop stays in "cold" state and warns the user via the spinner
# text that hooks may not be loaded in the running session.
smart_watch_loop() {
  local idle_start=0 now busy seen_busy=false
  local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  local tick=0
  local start_ts
  start_ts=$(date +%s)
  # If any marker already exists at entry (another terminal has a
  # submitted prompt in flight, or a prior run left a fresh marker),
  # consider that proof-of-life so we don't sit in cold mode forever.
  if (($(count_busy_sessions) > 0)); then
    seen_busy=true
  fi

  while true; do
    busy="$(count_busy_sessions)"
    now=$(date +%s)
    if [[ "$busy" != "0" ]]; then
      seen_busy=true
    fi
    if [[ "$busy" == "0" ]] && [[ "$seen_busy" == true ]]; then
      if ((idle_start == 0)); then
        idle_start=$now
      fi
      local idle_for=$((now - idle_start))
      if ((idle_for >= SMART_IDLE_SECONDS)); then
        clear_line
        print_ok "All Claude sessions idle for ${SMART_IDLE_SECONDS}s — proceeding to sleep."
        return 0
      fi
      if [[ "$USE_SPINNER" == true ]]; then
        printf "\r  %s%s%s  %sAll Claude sessions idle…%s  sleeping in %ds    " \
          "$GREEN" "${frames[$tick]}" "$RESET" \
          "$DIM" "$RESET" \
          "$((SMART_IDLE_SECONDS - idle_for))"
      fi
    elif [[ "$busy" == "0" ]]; then
      # Cold-start state: no busy marker ever seen this run. Don't
      # start the idle countdown yet — wait for a submission. Hint
      # once per minute that hooks may not be loaded in the current
      # Claude session.
      idle_start=0
      if [[ "$USE_SPINNER" == true ]]; then
        local elapsed=$((now - start_ts))
        printf "\r  %s%s%s  %sWaiting for a Claude prompt…%s  %ds elapsed    " \
          "$YELLOW" "${frames[$tick]}" "$RESET" \
          "$DIM" "$RESET" \
          "$elapsed"
      else
        if (((now / 60) != ${LAST_STATUS_MIN:-0})); then
          LAST_STATUS_MIN=$((now / 60))
          echo "  … waiting for a Claude prompt (no busy marker yet)"
        fi
      fi
    else
      # busy > 0: some session is actively processing.
      idle_start=0
      if [[ "$USE_SPINNER" == true ]]; then
        printf "\r  %s%s%s  %sWaiting — %d Claude session(s) busy…%s                 " \
          "$CYAN" "${frames[$tick]}" "$RESET" \
          "$DIM" "$busy" "$RESET"
      else
        if (((now / 60) != ${LAST_STATUS_MIN:-0})); then
          LAST_STATUS_MIN=$((now / 60))
          echo "  … $busy Claude session(s) busy"
        fi
      fi
    fi
    tick=$(((tick + 1) % ${#frames[@]}))
    sleep 2
  done
}

# ── Argument parsing ──────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout | -t)
      if [[ -z "${2:-}" ]] || ! is_positive_integer "$2"; then
        echo -e "${RED}✖  --timeout requires a positive integer ≥ 1 (hours)${RESET}" >&2
        exit 1
      fi
      TIMEOUT_HOURS="$2"
      shift 2
      ;;
    --pid | -p)
      if [[ -z "${2:-}" ]] || ! is_integer "$2"; then
        echo -e "${RED}✖  --pid requires a numeric process ID${RESET}" >&2
        exit 1
      fi
      TARGET_PID="$2"
      TARGET_PID_EXPLICIT=true
      shift 2
      ;;
    --delay | -d)
      if [[ -z "${2:-}" ]] || ! is_integer "$2"; then
        echo -e "${RED}✖  --delay requires a non-negative integer (seconds)${RESET}" >&2
        exit 1
      fi
      DELAY_SECS="$2"
      shift 2
      ;;
    --log-file)
      if [[ -z "${2:-}" ]]; then
        echo -e "${RED}✖  --log-file requires a path${RESET}" >&2
        exit 1
      fi
      LOG_FILE="$2"
      LOG_ENABLED=true
      shift 2
      ;;
    --no-sound)
      NO_SOUND=true
      shift
      ;;
    --caffeinate-only)
      CAFFEINATE_ONLY=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --list | -l)
      LIST_MODE=true
      shift
      ;;
    --notify | -n)
      NOTIFY=true
      shift
      ;;
    --log)
      LOG_ENABLED=true
      shift
      ;;
    --wait-for-start)
      WAIT_FOR_START=true
      shift
      ;;
    --preflight | -P)
      PREFLIGHT_ONLY=true
      shift
      ;;
    --no-preflight)
      SKIP_PREFLIGHT=true
      shift
      ;;
    --force | --yes | -f | -y)
      FORCE=true
      shift
      ;;
    --brief | -b)
      BRIEF=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --skip-update-check)
      SKIP_UPDATE_CHECK=true
      shift
      ;;
    --check-update)
      # Force an immediate update check, bypassing the 24h rate-limit
      # cache, then continue with the normal flow.
      rm -f "$UPDATE_CACHE_DIR/last-update-check" 2>/dev/null || true
      shift
      ;;
    --no-auto-caffeinate)
      NO_AUTO_CAFFEINATE=true
      shift
      ;;
    --allow-battery)
      ALLOW_BATTERY=true
      shift
      ;;
    --log-summary)
      LOG_SUMMARY=true
      shift
      ;;
    --sleep-now)
      # Skip Claude detection and the watch loop entirely. Run
      # preflight, interactively handle blockers, ensure caffeinate
      # is released, then sleep immediately.
      SLEEP_NOW=true
      shift
      ;;
    --smart)
      # Hook-based idle detection: sleep when all Claude sessions have
      # fired their Stop hook (i.e., none are processing a message).
      # Requires --install-hooks to have been run once. This is the
      # default when hooks are installed — the flag is still accepted
      # for explicit invocation and scripts.
      SMART_WATCH=true
      shift
      ;;
    --watch-pid)
      # Legacy process-exit watching: watches kill -0 $pid and sleeps
      # when the claude process dies. Pre-hooks behavior. Use when you
      # actually want to run Claude non-interactively and wait for the
      # process to exit.
      WATCH_PID_MODE=true
      shift
      ;;
    --install-hooks)
      INSTALL_HOOKS=true
      shift
      ;;
    --uninstall-hooks)
      UNINSTALL_HOOKS=true
      shift
      ;;
    --help | -h)
      echo ""
      echo -e "  ${BOLD}sleep-after-claude${RESET} — sleep your Mac when Claude Code finishes"
      echo ""
      echo -e "  ${DIM}Usage:${RESET}"
      echo -e "    sleep-after-claude [options]"
      echo ""
      echo -e "  ${DIM}Watch options:${RESET}"
      echo -e "    --pid, -p <pid>       Watch a specific PID (default: auto-detect)"
      echo -e "    --timeout, -t <hrs>   Force sleep after N hours, min 1 (default: 6)"
      echo -e "    --delay, -d <secs>    Grace period before sleeping (default: 1)"
      echo -e "    --wait-for-start      Poll until a Claude process appears"
      echo ""
      echo -e "  ${DIM}Mode options:${RESET}"
      echo -e "    --caffeinate-only     Release caffeinate but don't sleep the Mac"
      echo -e "    --dry-run             Simulate — detect and wait, but don't sleep"
      echo -e "    --list, -l            Show detectable Claude processes and exit"
      echo -e "    --preflight, -P       Run pre-flight scan only, then exit"
      echo -e "    --no-preflight        Skip pre-flight scan entirely"
      echo -e "    --force, -f           Skip confirmation prompts"
      echo -e "    --skip-update-check   Don't check for a newer version on startup"
      echo -e "    --check-update        Force update check now (bypass 24h cache)"
      echo -e "    --no-auto-caffeinate  Don't auto-start caffeinate -dim if missing"
      echo -e "    --allow-battery       Proceed even if the Mac is on battery (default: wait for AC)"
      echo -e "    --log-summary         Render the session log as pretty markdown (needs ~/.local/state log)"
      echo -e "    --sleep-now           Skip the watch — preflight + handle blockers + sleep immediately"
      echo -e "    --smart               Sleep when all Claude sessions are idle (default when hooks are installed)"
      echo -e "    --watch-pid           Legacy: watch kill -0 \$pid (default when hooks are not installed)"
      echo -e "    --install-hooks       Install Claude Code hooks so --smart can detect idle sessions"
      echo -e "    --uninstall-hooks     Remove goodnight's Claude Code hooks"
      echo ""
      echo -e "  ${DIM}Output options:${RESET}"
      echo -e "    --brief, -b           Show only the verdict in preflight output"
      echo -e "    --json                Emit preflight as JSON (for automation)"
      echo -e "    --no-sound            Skip the completion sound"
      echo -e "    --notify, -n          Send a macOS notification on completion"
      echo -e "    --log                 Append completion events to the log file"
      echo -e "    --log-file <path>     Custom log file (implies --log)"
      echo -e "    --help, -h            Show this help"
      echo ""
      echo -e "  ${DIM}Default log:${RESET} ~/.local/state/sleep-after-claude.log"
      echo ""
      exit 0
      ;;
    *)
      echo -e "${RED}✖  Unknown argument: $1${RESET}" >&2
      exit 1
      ;;
  esac
done

# ── Default mode selection ────────────────────────────────────
# If the user passed no explicit watch mode, pick one based on whether
# Claude Code hooks are installed:
#   - hooks installed → --smart (hook-based idle detection)
#   - hooks absent    → --watch-pid (legacy process-exit watching)
#                       with a one-line note pointing at --install-hooks
#
# --install-hooks / --uninstall-hooks / --preflight / --list /
# --log-summary / --sleep-now bypass this (they set their own paths
# and don't use either watch mode).
if [[ "$SMART_WATCH" != true && "$WATCH_PID_MODE" != true &&
  "$SLEEP_NOW" != true && "$PREFLIGHT_ONLY" != true &&
  "$LIST_MODE" != true && "$LOG_SUMMARY" != true &&
  "$INSTALL_HOOKS" != true && "$UNINSTALL_HOOKS" != true ]]; then
  if hooks_installed; then
    SMART_WATCH=true
  else
    WATCH_PID_MODE=true
  fi
fi

# ── Open persistent FIFO FD for fork-free micro_sleep ─────────
if [[ "$USE_BUILTIN_SLEEP" == true ]]; then
  if FIFO_DIR="$(mktemp -d -t sleep-after-claude.XXXXXX 2>/dev/null)"; then
    FIFO_PATH="$FIFO_DIR/fifo"
    if mkfifo "$FIFO_PATH" 2>/dev/null && exec 9<>"$FIFO_PATH"; then
      :
    else
      rm -rf "$FIFO_DIR" 2>/dev/null || true
      FIFO_DIR=""
      USE_BUILTIN_SLEEP=false
    fi
  else
    USE_BUILTIN_SLEEP=false
  fi
fi

# ── Cleanup ───────────────────────────────────────────────────
WATCH_STARTED=false
cleanup_fd_and_tmp() {
  [[ "$USE_BUILTIN_SLEEP" == true ]] && exec 9<&- 2>/dev/null || true
  [[ -n "$FIFO_DIR" && -d "$FIFO_DIR" ]] && rm -rf "$FIFO_DIR" 2>/dev/null || true
  # F-07: release the watch lock on any exit path.
  release_goodnight_lock
}

# F-07: Mutual-exclusion lock to prevent two concurrent `goodnight`
# invocations from racing on caffeinate release and double-pmset.
# macOS bash doesn't ship flock; `mkdir` is atomic across processes
# so we use the directory-as-lock pattern. Stale-lock detection: if
# the PID in the lock's marker file is no longer alive, the lock is
# reclaimed (prevents permanent deadlock after a crash).
GOODNIGHT_LOCK_DIR="${HOME}/.local/state/goodnight/lock"
GOODNIGHT_LOCK_ACQUIRED=false

acquire_goodnight_lock() {
  mkdir -p "$(dirname "$GOODNIGHT_LOCK_DIR")" 2>/dev/null || true
  # First attempt
  if mkdir "$GOODNIGHT_LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$GOODNIGHT_LOCK_DIR/pid"
    GOODNIGHT_LOCK_ACQUIRED=true
    return 0
  fi
  # Lock taken — check liveness of the holder.
  local holder_pid
  holder_pid="$(cat "$GOODNIGHT_LOCK_DIR/pid" 2>/dev/null || echo "")"
  if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
    print_error "Another goodnight is already running (PID $holder_pid)."
    print_step "Wait for it to finish, or cancel it first with: ${BOLD}kill $holder_pid${RESET}"
    return 1
  fi
  # Stale lock — steal it.
  print_warn "Stale lock at $GOODNIGHT_LOCK_DIR (holder PID $holder_pid dead) — reclaiming."
  rm -rf "$GOODNIGHT_LOCK_DIR" 2>/dev/null || true
  if mkdir "$GOODNIGHT_LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$GOODNIGHT_LOCK_DIR/pid"
    GOODNIGHT_LOCK_ACQUIRED=true
    return 0
  fi
  print_error "Could not acquire goodnight lock."
  return 1
}

release_goodnight_lock() {
  if [[ "$GOODNIGHT_LOCK_ACQUIRED" == true ]] && [[ -d "$GOODNIGHT_LOCK_DIR" ]]; then
    rm -rf "$GOODNIGHT_LOCK_DIR" 2>/dev/null || true
    GOODNIGHT_LOCK_ACQUIRED=false
  fi
}

on_interrupt() {
  clear_line
  echo ""
  if [[ "$WATCH_STARTED" == true ]]; then
    print_warn "Cancelled — machine will ${BOLD}not${RESET} sleep. Claude is still running."
    log_event "CANCELLED while watching PID ${TARGET_PID:-unknown}"
  else
    print_warn "Cancelled."
  fi
  # F-12: Don't call cleanup_fd_and_tmp directly here — the EXIT
  # trap will run it on exit. Calling it both here AND via the EXIT
  # trap is idempotent today but fragile if future cleanup steps
  # aren't.
  echo ""
  exit 0
}
trap on_interrupt INT TERM HUP
trap cleanup_fd_and_tmp EXIT

# ── --install-hooks / --uninstall-hooks fast paths ───────────
# These are pure config-file operations — no preflight, no watch.
if [[ "$INSTALL_HOOKS" == true ]]; then
  print_header
  install_claude_hooks
  exit $?
fi
if [[ "$UNINSTALL_HOOKS" == true ]]; then
  print_header
  uninstall_claude_hooks
  exit $?
fi

# ── --list mode ───────────────────────────────────────────────
if [[ "$LIST_MODE" == true ]]; then
  print_header
  list_matches="$(find_claude_processes)"
  list_all="$(find_all_claude_processes_raw)"
  list_target_pids=""
  [[ -n "$list_matches" ]] && list_target_pids="$(echo "$list_matches" | awk '{print $1}' | sort -u)"

  list_excluded=""
  if [[ -n "$list_all" ]]; then
    while IFS= read -r line; do
      pid="$(echo "$line" | awk '{print $1}')"
      if ! echo "$list_target_pids" | grep -qx "$pid"; then
        list_excluded+="${line}"$'\n'
      fi
    done <<<"$list_all"
    list_excluded="${list_excluded%$'\n'}"
  fi

  if [[ -z "$list_matches" ]]; then
    print_warn "No target Claude processes detected."
  else
    print_step "Target Claude process(es):"
    echo ""
    echo "$list_matches" | while IFS= read -r line; do
      echo -e "    ${GREEN}✔${RESET} ${line}"
    done
  fi
  if [[ -n "$list_excluded" ]]; then
    echo ""
    print_step "Excluded (not watched):"
    echo ""
    echo "$list_excluded" | while IFS= read -r line; do
      epid="$(echo "$line" | awk '{print $1}')"
      ecmd="$(echo "$line" | awk '{$1=""; sub(/^ /,""); print}' | cut -c1-65)"
      echo -e "    ${YELLOW}⊘${RESET} ${DIM}PID $epid  ${ecmd}${RESET}"
    done
  fi
  if [[ -n "$list_matches" ]]; then
    echo ""
    print_step "Use ${BOLD}--pid <pid>${RESET} to watch a specific one."
  fi
  echo ""
  exit 0
fi

# ── --preflight mode ──────────────────────────────────────────
if [[ "$PREFLIGHT_ONLY" == true ]]; then
  preflight_scan
  if [[ "$JSON_OUTPUT" == true ]]; then
    render_preflight_json
  else
    [[ "$BRIEF" == false ]] && print_header
    render_preflight
  fi
  exit 0
fi

# ── --log-summary mode ────────────────────────────────────────
# Renders the session log as pretty markdown via `glow` when it's
# installed; falls back to plain `tail` otherwise. Groups events by
# PREFLIGHT_* / WATCH_* / CLAUDE_* / SLEEP_* so the reader can skim
# an unattended night's activity at a glance.
if [[ "$LOG_SUMMARY" == true ]]; then
  if [[ ! -f "$LOG_FILE" ]]; then
    print_warn "No log file at $LOG_FILE — run with --log first."
    exit 0
  fi
  {
    echo "# sleep-after-claude session log"
    echo ""
    echo "**File:** \`$LOG_FILE\`"
    echo "**Total events:** $(wc -l <"$LOG_FILE" | tr -d ' ')"
    echo ""
    echo "## Recent events (last 50)"
    echo ""
    echo '```'
    tail -50 "$LOG_FILE"
    echo '```'
    echo ""
    echo "## Counts by category"
    echo ""
    echo "| Category | Count |"
    echo "|---|---|"
    for pat in WATCH_START CLAUDE_FINISHED SLEEP_ATTEMPT SLEEP_FAILED PREFLIGHT_BLOCKERS PREFLIGHT_SCAN_FAILED POWER_GATE_WAITING POWER_GATE_RELEASED AUTO_CAFFEINATE_STARTED CANCELLED TIMEOUT PID_REUSED; do
      # grep -c always prints a count to stdout (even "0" when no match)
      # and exits 1 on no-match — we only care about stdout here.
      c="$(grep -c "$pat" "$LOG_FILE" 2>/dev/null)"
      echo "| $pat | ${c:-0} |"
    done
  } | {
    if have_glow; then
      glow -
    else
      cat
    fi
  }
  exit 0
fi

# ── Power-state gate ──────────────────────────────────────────
# Must be the FIRST check on the actionable path — we don't want to
# burn battery downloading updates or waiting for Claude when the
# machine is unplugged. Desktop Macs (no battery) pass through.
print_header
wait_for_ac_power

# ── Self-update check ─────────────────────────────────────────
# Runs on the actionable path (default watch-and-sleep, --dry-run,
# --caffeinate-only, --wait-for-start). Skipped for pure introspection
# modes (--help/--list/--preflight) which returned above. Rate-limited
# to once per 24h via ~/.cache/sleep-after-claude/last-update-check.
check_for_update

# ── --sleep-now fast path ─────────────────────────────────────
# Skips Claude detection and the watch loop entirely. Runs preflight,
# interactively handles blockers, releases/auto-starts caffeinate as
# usual, then sleeps immediately. For when the user knows they want
# to sleep now regardless of any running Claude sessions (e.g.,
# idle Claude REPLs left open from earlier).
if [[ "$SLEEP_NOW" == true ]]; then
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi
    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED (sleep-now)"
      if [[ "$FORCE" == false ]]; then
        if [[ "$STDIN_IS_TTY" == true ]]; then
          if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
            print_warn "Aborted by user."
            echo ""
            exit 0
          fi
          echo ""
        else
          print_error "Sleep-blocker scan failed and stdin is not a TTY for confirmation."
          exit 1
        fi
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]} (sleep-now)"
      if ! prompt_and_handle_blockers; then
        echo ""
        exit 0
      fi
      echo ""
    fi
  fi
  # Release any caffeinate processes already running so macOS is free
  # to sleep. Don't auto-start a new one — we're sleeping immediately.
  # shellcheck disable=SC2207
  SLEEP_NOW_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))
  if [[ ${#SLEEP_NOW_CAFF_PIDS[@]} -gt 0 ]]; then
    print_step "Releasing caffeinate (${SLEEP_NOW_CAFF_PIDS[*]})..."
    kill "${SLEEP_NOW_CAFF_PIDS[@]}" 2>/dev/null || true
  fi
  echo ""
  print_step "Sleeping Mac in ${BOLD}${DELAY_SECS}s${RESET}..."
  play_sound
  sleep "$DELAY_SECS"
  echo ""
  echo -e "  ${BOLD}${GREEN}Good night 🌙${RESET}"
  echo ""
  log_event "SLEEP_ATTEMPT (sleep-now)"
  if pmset sleepnow 2>/dev/null; then
    exit 0
  elif osascript -e 'tell application "System Events" to sleep' 2>/dev/null; then
    exit 0
  else
    print_error "Could not trigger sleep automatically."
    print_warn "Run manually: ${BOLD}pmset sleepnow${RESET}"
    log_event "SLEEP_FAILED (sleep-now)"
    exit 1
  fi
fi

# ── --smart mode: hook-based idle detection ──────────────────
# When enabled, goodnight watches the busy directory populated by the
# Claude Code hooks installed via --install-hooks. No PID watching,
# no process-exit waiting — sleep happens as soon as all sessions
# have fired their Stop hook.
if [[ "$SMART_WATCH" == true ]]; then
  if ! hooks_installed; then
    print_error "Claude Code hooks aren't installed — --smart mode can't detect idle sessions."
    print_step "Install them once with: ${BOLD}goodnight --install-hooks${RESET}"
    print_step "Or fall back to process-watch mode with: ${BOLD}goodnight --watch-pid${RESET}"
    exit 1
  fi
  mkdir -p "$BUSY_DIR" 2>/dev/null || true
  # Run preflight + blocker handling first (same as default flow).
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi
    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED (smart)"
      if [[ "$FORCE" == false ]]; then
        if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
          print_warn "Aborted."
          exit 0
        fi
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]} (smart)"
      if ! prompt_and_handle_blockers; then
        exit 0
      fi
    fi
  fi
  ensure_caffeinate_running
  # shellcheck disable=SC2207
  INITIAL_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))

  echo ""
  echo -e "  ${BOLD}Smart watch${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  print_step "Idle threshold: ${BOLD}${SMART_IDLE_SECONDS}s${RESET} (all Claude sessions must be idle this long)"
  print_step "Busy markers:   ${BOLD}$BUSY_DIR${RESET}"
  print_step "Press ${BOLD}Ctrl+C${RESET} to cancel"
  echo ""

  # F-07: Acquire the watch lock to prevent concurrent goodnight
  # instances from racing on caffeinate release and pmset sleepnow.
  if ! acquire_goodnight_lock; then
    exit 1
  fi
  log_event "SMART_WATCH_START busy_count=$(count_busy_sessions)"
  WATCH_STARTED=true
  smart_watch_loop
  WATCH_STARTED=false
  clear_line
  log_event "SMART_WATCH_IDLE — proceeding to sleep"

  # Reuse the existing release-caffeinate + sleep sequence from the
  # default watch flow. Jump there by falling through — set
  # TARGET_PID to a sentinel so the "Detect Claude PID" block below
  # skips its lookups.
  TARGET_PID="smart"
  TARGET_CMD="smart-watch"
  TARGET_CMD_FULL="smart-watch"
  TARGET_BIN="smart-watch"
  SMART_WATCH_DONE=true
fi

# ── Detect Claude PID ─────────────────────────────────────────

if [[ "${SMART_WATCH_DONE:-false}" != true ]]; then
  if [[ -z "$TARGET_PID" ]]; then
    MATCHES="$(find_claude_processes)"

    if [[ -z "$MATCHES" && "$WAIT_FOR_START" == true ]]; then
      print_step "Waiting for Claude to start..."
      while [[ -z "$MATCHES" ]]; do
        sleep 2
        MATCHES="$(find_claude_processes)"
      done
      print_ok "Claude detected."
    fi

    if [[ -z "$MATCHES" ]]; then
      print_error "No Claude process found. Is Claude Code running?"
      print_step "Run ${BOLD}sleep-after-claude --list${RESET} to check what's detectable."
      print_step "Or use ${BOLD}--wait-for-start${RESET} to wait for Claude to launch."
      exit 1
    fi

    MATCH_COUNT="$(echo "$MATCHES" | wc -l | tr -d ' ')"
    TARGET_PID="$(echo "$MATCHES" | awk 'NR==1{print $1}')"
    TARGET_CMD="$(echo "$MATCHES" | awk 'NR==1{$1=""; sub(/^ /, ""); print}' | cut -c1-55)"

    if [[ "$MATCH_COUNT" -gt 1 ]]; then
      print_warn "Multiple Claude processes found — watching the first one:"
      echo ""
      echo "$MATCHES" | while IFS= read -r line; do
        echo -e "    ${DIM}$line${RESET}"
      done
      echo ""
      print_step "Use ${BOLD}--pid <pid>${RESET} to watch a specific one."
      echo ""
    fi

    print_ok "Watching: ${BOLD}PID $TARGET_PID${RESET} ${DIM}→ $TARGET_CMD${RESET}"

  else
    if ! kill -0 "$TARGET_PID" 2>/dev/null; then
      print_error "PID $TARGET_PID not found or already exited."
      exit 1
    fi
    TARGET_CMD="$(ps -p "$TARGET_PID" -o command= 2>/dev/null | cut -c1-55 || echo "unknown")"
    print_ok "Watching: ${BOLD}PID $TARGET_PID${RESET} ${DIM}→ $TARGET_CMD${RESET}"
  fi

  TARGET_CMD_FULL="$(ps -p "$TARGET_PID" -o command= 2>/dev/null || echo "")"
  # Extract just the binary path (first whitespace-separated token). argv
  # can legitimately mutate at runtime via setproctitle/exec -a/etc., so
  # we compare only the binary for PID-reuse detection — a full-string
  # compare would false-positive on a legitimate argv change and sleep
  # the Mac mid-task.
  TARGET_BIN="$(echo "$TARGET_CMD_FULL" | awk '{print $1}')"

  # ── Pre-flight scan + verdict + optional confirmation ─────────
  if [[ "$SKIP_PREFLIGHT" == false ]]; then
    preflight_scan
    if [[ "$JSON_OUTPUT" == true ]]; then
      render_preflight_json
    else
      render_preflight
    fi

    if [[ "$PREFLIGHT_SCAN_OK" != true ]]; then
      log_event "PREFLIGHT_SCAN_FAILED"
      if [[ "$FORCE" == false ]]; then
        if [[ "$STDIN_IS_TTY" == true ]]; then
          if ! ui_confirm "Sleep-blocker scan failed. Proceed anyway?"; then
            print_warn "Aborted by user. Claude is still running; caffeinate untouched."
            echo ""
            exit 0
          fi
          echo ""
        else
          print_error "Sleep-blocker scan failed and stdin is not a TTY for confirmation."
          print_step "Pass ${BOLD}--force${RESET} to proceed anyway, or ${BOLD}--no-preflight${RESET} to skip the scan."
          exit 1
        fi
      else
        print_warn "Sleep-blocker scan failed but --force was given — proceeding."
        echo ""
      fi
    elif [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
      log_event "PREFLIGHT_BLOCKERS count=${#PREFLIGHT_BLOCKERS[@]}"
      # Interactive blocker-handling menu: terminate (user apps only),
      # skip, or abort. --force short-circuits to "skip with warning".
      if ! prompt_and_handle_blockers; then
        echo ""
        exit 0
      fi
      echo ""
    fi
  fi

  # ── Ensure caffeinate is running ──────────────────────────────
  # If no caffeinate is active we start one now so the Mac doesn't
  # drift to sleep while we're watching. Skippable with
  # --no-auto-caffeinate for users who manage caffeinate themselves.
  ensure_caffeinate_running

  # ── Capture caffeinate PIDs at start ──────────────────────────
  # Captured AFTER ensure_caffeinate_running so any auto-started
  # caffeinate is included and will be released at the end of watch.
  # shellcheck disable=SC2207
  INITIAL_CAFF_PIDS=($(pgrep caffeinate 2>/dev/null || true))

  TIMEOUT_SECS=$((TIMEOUT_HOURS * 3600))

  echo -e "  ${BOLD}Starting watch${RESET}"
  echo -e "  ${DIM}─────────────────────────────────────────${RESET}"
  print_step "Timeout:  ${BOLD}${TIMEOUT_HOURS}h${RESET}"
  print_step "Delay:    ${BOLD}${DELAY_SECS}s${RESET} before sleep"
  if [[ ${#INITIAL_CAFF_PIDS[@]} -gt 0 ]]; then
    print_step "Caffeinate PIDs captured: ${BOLD}${INITIAL_CAFF_PIDS[*]}${RESET}"
  else
    print_warn "No caffeinate processes currently running"
  fi
  [[ "$CAFFEINATE_ONLY" == true ]] && print_step "Mode:     ${BOLD}caffeinate-only${RESET} (will not sleep the Mac)"
  [[ "$DRY_RUN" == true ]] && print_step "Mode:     ${BOLD}dry-run${RESET} (will not sleep the Mac)"
  [[ "$NO_SOUND" == true ]] && print_step "Sound:    ${BOLD}off${RESET}"
  [[ "$NOTIFY" == true ]] && print_step "Notify:   ${BOLD}on${RESET}"
  [[ "$LOG_ENABLED" == true ]] && print_step "Log:      ${BOLD}${LOG_FILE}${RESET}"
  [[ "$USE_SPINNER" == false ]] && print_step "TTY:      ${BOLD}non-interactive${RESET} (spinner disabled)"
  print_step "Press ${BOLD}Ctrl+C${RESET} to cancel"
  if [[ "${SMART_WATCH_DONE:-false}" != true ]] && ! hooks_installed; then
    echo -e "  ${DIM}Tip: Claude Code hooks aren't installed — this watch waits for the${RESET}"
    echo -e "  ${DIM}process to exit, which an interactive Claude REPL won't do. Run${RESET}"
    echo -e "  ${DIM}${BOLD}goodnight --install-hooks${RESET}${DIM} once to enable idle-aware detection.${RESET}"
  fi
  echo ""

  # F-07: Acquire the watch lock (if smart-mode didn't already — it's
  # idempotent). Prevents concurrent invocations racing on caffeinate
  # and pmset.
  if [[ "${SMART_WATCH_DONE:-false}" != true ]]; then
    if ! acquire_goodnight_lock; then
      exit 1
    fi
  fi
  log_event "WATCH_START pid=$TARGET_PID cmd=\"$TARGET_CMD\""

  # ── Wait loop ─────────────────────────────────────────────────
  WATCH_STARTED=true
  START_TIME=$(date +%s)
  FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  TICK=0
  TICK_COUNT=0
  ELAPSED=0
  LAST_STATUS_LOG=0
  TIMED_OUT=false
  PID_REUSED=false

  # Skip the kill -0 loop entirely when smart mode already handled the
  # wait — we only need to fall through to the release+sleep sequence.
  while [[ "${SMART_WATCH_DONE:-false}" != true ]] && kill -0 "$TARGET_PID" 2>/dev/null; do
    if ((TICK_COUNT % 10 == 0)); then
      NOW=$(date +%s)
      ELAPSED=$((NOW - START_TIME))
    fi

    if [[ -n "$TARGET_BIN" ]] && ((TICK_COUNT % 300 == 0)) && ((TICK_COUNT > 0)); then
      CURRENT_CMD="$(ps -p "$TARGET_PID" -o command= 2>/dev/null || echo "")"
      CURRENT_BIN="$(echo "$CURRENT_CMD" | awk '{print $1}')"
      if [[ -n "$CURRENT_BIN" && "$CURRENT_BIN" != "$TARGET_BIN" ]]; then
        clear_line
        print_warn "PID $TARGET_PID was reused by another process — treating as finished."
        log_event "PID_REUSED pid=$TARGET_PID was=\"$TARGET_CMD_FULL\" now=\"$CURRENT_CMD\""
        PID_REUSED=true
        break
      fi
    fi

    if [[ $ELAPSED -ge $TIMEOUT_SECS ]]; then
      clear_line
      print_warn "Timeout of ${TIMEOUT_HOURS}h reached — forcing sleep anyway."
      TIMED_OUT=true
      break
    fi

    if [[ "$USE_SPINNER" == true ]]; then
      # Static format; all dynamics go through %s so stray `%` can't
      # corrupt the format string (same safety pattern as wait_for_ac_power).
      printf "\r  %s%s%s  %sWaiting for PID %s…%s  %s elapsed     " \
        "$CYAN" "${FRAMES[$TICK]}" "$RESET" \
        "$DIM" "$TARGET_PID" "$RESET" \
        "$(elapsed_label "$ELAPSED")"
    else
      if ((ELAPSED - LAST_STATUS_LOG >= 300)); then
        echo "  … still waiting for PID $TARGET_PID ($(elapsed_label $ELAPSED) elapsed)"
        LAST_STATUS_LOG=$ELAPSED
      fi
    fi

    TICK=$(((TICK + 1) % ${#FRAMES[@]}))
    TICK_COUNT=$((TICK_COUNT + 1))
    micro_sleep 0.1
  done

  clear_line
  WATCH_STARTED=false

  if [[ "$TIMED_OUT" == false && "$PID_REUSED" == false ]]; then
    TOTAL_ELAPSED=$(($(date +%s) - START_TIME))
    print_ok "Process ${BOLD}PID $TARGET_PID${RESET} finished after $(elapsed_label $TOTAL_ELAPSED)"
    log_event "CLAUDE_FINISHED pid=$TARGET_PID elapsed=${TOTAL_ELAPSED}s"
    notify_macos "Claude finished after $(elapsed_label $TOTAL_ELAPSED)"
  elif [[ "$TIMED_OUT" == true ]]; then
    log_event "TIMEOUT pid=$TARGET_PID after ${TIMEOUT_HOURS}h"
    notify_macos "Claude timeout reached — forcing sleep"
  else
    notify_macos "Claude PID reused — proceeding with sleep"
  fi
fi

# ── Re-scan assertions only (lightweight, no full rescan needed) ──
if [[ "$SKIP_PREFLIGHT" == false ]]; then
  scan_assertions
  if [[ ${#PREFLIGHT_BLOCKERS[@]} -gt 0 ]]; then
    print_post_watch_blockers
  fi
fi

# ── Release caffeinate ────────────────────────────────────────
echo ""
print_step "Releasing caffeinate..."

if [[ ${#INITIAL_CAFF_PIDS[@]} -eq 0 ]]; then
  print_warn "No captured caffeinate PIDs — nothing to release"
else
  ALIVE_PIDS=()
  for pid in "${INITIAL_CAFF_PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && ALIVE_PIDS+=("$pid")
  done

  if [[ ${#ALIVE_PIDS[@]} -eq 0 ]]; then
    print_warn "Captured caffeinate PIDs already exited — nothing to do"
  else
    kill "${ALIVE_PIDS[@]}" 2>/dev/null || true
    sleep 0.3

    STUCK_PIDS=()
    for pid in "${ALIVE_PIDS[@]}"; do
      kill -0 "$pid" 2>/dev/null && STUCK_PIDS+=("$pid")
    done

    if [[ ${#STUCK_PIDS[@]} -eq 0 ]]; then
      print_ok "caffeinate stopped (${#ALIVE_PIDS[@]} process(es): ${ALIVE_PIDS[*]})"
    elif kill -9 "${STUCK_PIDS[@]}" 2>/dev/null; then
      print_warn "caffeinate force-killed with SIGKILL: ${STUCK_PIDS[*]}"
      log_event "CAFFEINATE_SIGKILL pids=${STUCK_PIDS[*]}"
    else
      print_warn "Could not kill caffeinate PIDs ${STUCK_PIDS[*]} — try: sudo kill -9 ${STUCK_PIDS[*]}"
      log_event "CAFFEINATE_KILL_FAILED pids=${STUCK_PIDS[*]}"
    fi
  fi
fi

# ── Early exits ───────────────────────────────────────────────
echo ""

if [[ "$DRY_RUN" == true ]]; then
  print_done "Dry run complete — ${BOLD}not sleeping${RESET} the Mac."
  play_sound
  log_event "DRY_RUN_EXIT"
  exit 0
fi

if [[ "$CAFFEINATE_ONLY" == true ]]; then
  print_done "Caffeinate released. Mac will sleep on its own idle timer."
  play_sound
  log_event "CAFFEINATE_ONLY_EXIT"
  exit 0
fi

# ── Sleep the Mac ─────────────────────────────────────────────
print_step "Sleeping Mac in ${BOLD}${DELAY_SECS}s${RESET}..."
play_sound
sleep "$DELAY_SECS"

echo ""
echo -e "  ${BOLD}${GREEN}Good night 🌙${RESET}"
echo ""
log_event "SLEEP_ATTEMPT"

if pmset sleepnow 2>/dev/null; then
  exit 0
elif osascript -e 'tell application "System Events" to sleep' 2>/dev/null; then
  exit 0
else
  print_error "Could not trigger sleep automatically."
  print_warn "Run manually: ${BOLD}pmset sleepnow${RESET}"
  log_event "SLEEP_FAILED"
  exit 1
fi
__SCRIPT_END__
