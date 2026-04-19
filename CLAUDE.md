# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

This repo ships a single macOS Bash utility (published as `sleep-after-claude`, aliased to `goodnight`) via a self-extracting installer. There is no build system, package manifest, or test suite — just two shell scripts and a README.

- `sleep-after-claude` — the tool. Standalone Bash script that watches a Claude Code process and sleeps the Mac when it finishes.
- `install-sleep-after-claude.sh` — self-extracting installer. The full `sleep-after-claude` script is embedded between `__SCRIPT_START__` / `__SCRIPT_END__` markers (see install-sleep-after-claude.sh:155) and extracted at install time by the `awk` block at install-sleep-after-claude.sh:73.
- `README.md` — user-facing install/usage blurb. Points at the `curl | bash` installer URL on GitHub (`sambatia/sleep-after-claude`).

## Critical: keep the two scripts in sync

`install-sleep-after-claude.sh` embeds a byte-for-byte copy of `sleep-after-claude` between its `__SCRIPT_START__` and `__SCRIPT_END__` markers. Any edit to `sleep-after-claude` **must** be mirrored into the embedded region of the installer (or vice versa), otherwise `curl | bash` users get a stale tool.

After editing, verify they match:

```bash
awk '/^__SCRIPT_START__$/{flag=1; next} /^__SCRIPT_END__$/{flag=0} flag' install-sleep-after-claude.sh \
  | diff - sleep-after-claude
```

The diff must be empty.

## Testing changes locally

There are no automated tests. To validate changes:

```bash
bash -n sleep-after-claude                  # syntax check
bash -n install-sleep-after-claude.sh
./sleep-after-claude --help                 # smoke test
./sleep-after-claude --preflight            # exercises the pre-flight scan (macOS only)
./sleep-after-claude --list                 # show detected Claude processes
./sleep-after-claude --dry-run              # watch-and-detect without actually sleeping
```

The script guards on `uname == Darwin` at the top, so it cannot run on Linux/CI — testing happens on a Mac.

## Architecture of `sleep-after-claude`

The script has a linear top-to-bottom flow with labeled section banners (`# ── Section ──`). Navigating by those banners is the fastest way to orient:

1. **macOS guard + TTY/Bash-version detection** (lines ~14–47) — sets `USE_BUILTIN_SLEEP` (Bash ≥ 4 FIFO trick to avoid forking `sleep`), color toggles, and TTY flags that downstream output functions branch on.
2. **Config defaults + arg parsing** (lines ~49, ~623) — flag table lives inline in the `--help` block (sleep-after-claude:662) and must be kept in sync with the `case` arms just above.
3. **Claude process detection** (`find_claude_processes`, ~146) — two-tier: a "tight" pass using `pgrep -x claude` / `pgrep -f claude-code`, falling back to a broad `pgrep -fi claude` filtered by `EXCLUDE_PATTERN` to weed out Electron-based apps (Claude.app, Cursor, Windsurf, chrome-native-host, etc.). When adding a new false-positive, update `EXCLUDE_PATTERN` at sleep-after-claude:150.
4. **Pre-flight scan** (~195–620, the bulk of the script) — inventories `caffeinate` processes, `pmset -g assertions`, clamshell/lid state, battery, user sessions, then emits a verdict (clear / display-only blockers / hard blockers). Gated by `--no-preflight`, restricted by `--brief`, machine-readable via `--json`.
5. **FIFO setup + cleanup trap** (~701) — opens fd 9 on a named pipe so the watch loop can `read -t` instead of forking `/bin/sleep` every tick. Cleaned up in `cleanup_fd_and_tmp`.
6. **Early-exit modes** (`--list`, `--preflight`, then `--dry-run` / `--caffeinate-only` branches ~1013) run before the actual sleep.
7. **Watch loop** (~905) — polls the target PID until it exits or `--timeout` fires.
8. **Release caffeinate + `pmset sleepnow`** (~978, ~1030) — the actual sleep action.

When modifying behavior, note which section owns the concern; most flags touch exactly one section.

## Conventions in this codebase

- Bash, `set -uo pipefail` (no `-e` — the script relies on non-zero exits from `pgrep` being non-fatal).
- All user-facing output goes through `print_header` / `print_step` / `print_ok` / `print_warn` / `print_error` / `print_done` (sleep-after-claude:70). Don't emit raw `echo` for status lines — these helpers handle TTY/non-TTY color stripping.
- Integer validation uses `is_integer` / `is_positive_integer` helpers; reuse them rather than inlining regex.
- `--json` output is consumed by automation; any new preflight field must be added to the JSON emitter as well as the human-readable renderer.
