#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/terminal-ui"
TMP_DIR="$(mktemp -d -t goodnight-terminal-ui.XXXXXX)"
UPDATE_FIXTURES=false
RUN_FALLBACK=true
RUN_SHIMMED_GUM=true

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: scripts/check-terminal-ui.sh [options]

Options:
  --fallback-only       Compare only plain Bash fallback snapshots.
  --shimmed-gum-only    Compare only deterministic gum/glow shim snapshots.
  --update-fixtures     Rewrite terminal UI fixtures from current output.
  --help                Show this help.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --fallback-only)
      RUN_FALLBACK=true
      RUN_SHIMMED_GUM=false
      ;;
    --shimmed-gum-only)
      RUN_FALLBACK=false
      RUN_SHIMMED_GUM=true
      ;;
    --update-fixtures)
      UPDATE_FIXTURES=true
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for cmd in bash sed diff mkdir mktemp chmod cat tr awk; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  }
done

extract_runtime_ui() {
  sed -n '/^print_header() {$/,/^# Render the public CLI help/p' \
    "$REPO_ROOT/sleep-after-claude" >"$TMP_DIR/runtime-ui.bash"
}

extract_installer_ui() {
  sed -n '1,/^# ── Header/p' \
    "$REPO_ROOT/install-sleep-after-claude.sh" >"$TMP_DIR/installer-ui.bash"
}

write_shims() {
  mkdir -p "$TMP_DIR/shims"

  cat >"$TMP_DIR/shims/gum" <<'EOF'
#!/usr/bin/env bash
subcommand="${1:-}"
shift || true

escape_text() {
  awk 'BEGIN { first = 1 } {
    gsub(/\\/, "\\\\")
    if (!first) {
      printf "\\n"
    }
    printf "%s", $0
    first = 0
  }'
}

case "$subcommand" in
  style)
    printf 'GUM_STYLE'
    for arg in "$@"; do
      printf '|%s' "$arg"
    done
    printf '\n'
    if [[ "$*" == *'--'* ]]; then
      seen_sep=false
      for arg in "$@"; do
        if [[ "$seen_sep" == true ]]; then
          printf 'GUM_STYLE_TEXT|%s\n' "$(printf '%s' "$arg" | escape_text)"
        elif [[ "$arg" == "--" ]]; then
          seen_sep=true
        fi
      done
    else
      while IFS= read -r line; do
        printf 'GUM_STYLE_STDIN|%s\n' "$line"
      done
    fi
    ;;
  table)
    printf 'GUM_TABLE'
    for arg in "$@"; do
      printf '|%s' "$arg"
    done
    printf '\n'
    while IFS= read -r line; do
      printf 'GUM_TABLE_ROW|%s\n' "$line"
    done
    ;;
  spin)
    printf 'GUM_SPIN'
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --)
          shift
          printf '|--'
          break
          ;;
        *)
          printf '|%s' "$1"
          shift
          ;;
      esac
    done
    printf '\n'
    "$@"
    ;;
  confirm)
    printf 'GUM_CONFIRM'
    for arg in "$@"; do
      printf '|%s' "$arg"
    done
    printf '\n'
    exit 0
    ;;
  choose)
    printf 'GUM_CHOOSE'
    for arg in "$@"; do
      printf '|%s' "$arg"
    done
    printf '\n'
    printf '%s\n' "${@: -1}"
    ;;
  *)
    printf 'GUM_%s' "$subcommand"
    for arg in "$@"; do
      printf '|%s' "$arg"
    done
    printf '\n'
    ;;
esac
EOF
  chmod +x "$TMP_DIR/shims/gum"

  cat >"$TMP_DIR/shims/glow" <<'EOF'
#!/usr/bin/env bash
printf 'GLOW'
for arg in "$@"; do
  printf '|%s' "$arg"
done
printf '\n'
while IFS= read -r line; do
  printf 'GLOW_LINE|%s\n' "$line"
done
EOF
  chmod +x "$TMP_DIR/shims/glow"
}

capture_runtime_plain() {
  bash "$TMP_DIR/capture-runtime-plain.bash" >"$TMP_DIR/runtime-plain.actual"
}

write_runtime_plain_capture() {
  cat >"$TMP_DIR/capture-runtime-plain.bash" <<EOF
#!/usr/bin/env bash
STDIN_IS_TTY=false
STDOUT_IS_TTY=false
BOLD=''
RESET=''
DIM=''
GREEN=''
YELLOW=''
CYAN=''
RED=''
BLUE=''
MAGENTA=''
SAC_NO_GUM=1
SAC_NO_GLOW=1
source "$TMP_DIR/runtime-ui.bash"
print_header
ui_section 'Pre-flight scan' 'Sleep readiness audit before goodnight releases caffeinate.'
ui_kv 'Battery' '100% (AC Power)'
ui_kv 'System sleep' '1 min'
printf 'will release,123,caffeinate,PreventUserIdleSystemSleep\nBLOCKS SLEEP,456,zoom,PreventUserIdleSystemSleep\n' | ui_table 'State,PID,Process,Assertion'
ui_panel success 'No active sleep blockers detected' 'Releasing caffeinate will allow the Mac to sleep normally.'
EOF
  chmod +x "$TMP_DIR/capture-runtime-plain.bash"
}

capture_installer_plain() {
  bash "$TMP_DIR/capture-installer-plain.bash" >"$TMP_DIR/installer-plain.actual"
}

write_installer_plain_capture() {
  cat >"$TMP_DIR/capture-installer-plain.bash" <<EOF
#!/usr/bin/env bash
SAC_NO_GUM=1
SAC_NO_GLOW=1
source "$TMP_DIR/installer-ui.bash"
INSTALLER_STDOUT_IS_TTY=false
C_RESET=''
C_BOLD=''
C_DIM=''
C_GREEN=''
C_YELLOW=''
C_CYAN=''
C_RED=''
C_BLUE=''
ui_header
ui_panel warning 'Claude Code hooks skipped' 'Run goodnight --install-hooks later.' 'Existing hooks are preserved.'
{
  echo '# Installation complete 🌙'
  echo ''
  echo 'goodnight is installed at \`~/bin/sleep-after-claude\`.'
} | ui_markdown
EOF
  chmod +x "$TMP_DIR/capture-installer-plain.bash"
}

capture_runtime_gum() {
  PATH="$TMP_DIR/shims:$PATH" bash "$TMP_DIR/capture-runtime-gum.bash" >"$TMP_DIR/runtime-gum.actual"
}

write_runtime_gum_capture() {
  cat >"$TMP_DIR/capture-runtime-gum.bash" <<EOF
#!/usr/bin/env bash
STDIN_IS_TTY=true
STDOUT_IS_TTY=true
COLUMNS=120
BOLD=''
RESET=''
DIM=''
GREEN=''
YELLOW=''
CYAN=''
RED=''
BLUE=''
MAGENTA=''
unset SSH_CONNECTION
unset SSH_TTY
source "$TMP_DIR/runtime-ui.bash"
print_header
ui_section 'Sleep assertions' 'Detected with pmset -g assertions.'
printf 'will release,123,caffeinate,PreventUserIdleSystemSleep\nBLOCKS SLEEP,456,zoom,PreventUserIdleSystemSleep\n' | ui_table 'State,PID,Process,Assertion'
ui_panel danger '1 active system-sleep blocker' 'Zoom is preventing system sleep.'
printf '# Help\n\nUse goodnight.\n' | ui_markdown
EOF
  chmod +x "$TMP_DIR/capture-runtime-gum.bash"
}

capture_installer_gum() {
  PATH="$TMP_DIR/shims:$PATH" bash "$TMP_DIR/capture-installer-gum.bash" >"$TMP_DIR/installer-gum.actual"
}

write_installer_gum_capture() {
  cat >"$TMP_DIR/capture-installer-gum.bash" <<EOF
#!/usr/bin/env bash
unset SSH_CONNECTION
unset SSH_TTY
source "$TMP_DIR/installer-ui.bash"
INSTALLER_STDOUT_IS_TTY=true
ui_header
ui_panel success 'Installer ready' 'goodnight is installed.'
ui_spin 'Running quick verification' -- bash -c 'printf "verified\n"'
printf '# Installation complete 🌙\n\nRun \`goodnight --help\`.\n' | ui_markdown
EOF
  chmod +x "$TMP_DIR/capture-installer-gum.bash"
}

compare_or_update() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  mkdir -p "$FIXTURE_DIR"
  if [[ "$UPDATE_FIXTURES" == true ]]; then
    cp "$actual" "$expected"
    echo "terminal-ui: updated $label fixture"
    return 0
  fi

  if diff -u "$expected" "$actual"; then
    echo "terminal-ui: $label fixture OK"
  else
    echo "terminal-ui: $label fixture mismatch" >&2
    return 1
  fi
}

main() {
  extract_runtime_ui
  extract_installer_ui
  write_runtime_plain_capture
  write_installer_plain_capture
  write_shims
  write_runtime_gum_capture
  write_installer_gum_capture

  local failures=0

  if [[ "$RUN_FALLBACK" == true ]]; then
    capture_runtime_plain
    compare_or_update "$FIXTURE_DIR/runtime-plain.txt" "$TMP_DIR/runtime-plain.actual" "runtime plain" || failures=$((failures + 1))

    capture_installer_plain
    compare_or_update "$FIXTURE_DIR/installer-plain.txt" "$TMP_DIR/installer-plain.actual" "installer plain" || failures=$((failures + 1))
  fi

  if [[ "$RUN_SHIMMED_GUM" == true ]]; then
    capture_runtime_gum
    compare_or_update "$FIXTURE_DIR/runtime-gum-glow-shim.txt" "$TMP_DIR/runtime-gum.actual" "runtime gum/glow shim" || failures=$((failures + 1))

    capture_installer_gum
    compare_or_update "$FIXTURE_DIR/installer-gum-glow-shim.txt" "$TMP_DIR/installer-gum.actual" "installer gum/glow shim" || failures=$((failures + 1))
  fi

  [[ "$failures" -eq 0 ]]
}

main
