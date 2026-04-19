# CLAUDE.md

<!-- Last updated: 2026-04-19 | Audit cycle: 2026-04-19 (audit → remediation → test expansion → docs) -->

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository layout

macOS Bash utility `sleep-after-claude` (aliased to `goodnight`) that watches a Claude Code process and sleeps the Mac when it finishes. Distributed via a self-extracting installer over `curl | bash`.

- `sleep-after-claude` — the tool. Standalone Bash script.
- `install-sleep-after-claude.sh` — self-extracting installer. Embeds a byte-identical copy of `sleep-after-claude` between `__SCRIPT_START__` / `__SCRIPT_END__` markers and extracts it to `~/bin` at install time.
- `scripts/check-parity.sh` — verifies the embedded payload matches the standalone script. See "Parity invariant" below.
- `.githooks/pre-commit` — opt-in hook that runs the parity check when either script is staged. Enable with `git config core.hooksPath .githooks`.
- `tests/` — bats-core regression suite covering every fix from the 2026-04-19 audit cycle. See "Testing" below.
- `README.md` — user-facing install/usage blurb + documented escape hatches for CDN cache staleness and checksum pinning.

## Parity invariant (critical)

`install-sleep-after-claude.sh` embeds a byte-for-byte copy of `sleep-after-claude` between its `__SCRIPT_START__` and `__SCRIPT_END__` markers. Any edit to `sleep-after-claude` **must** be mirrored into the embedded region of the installer (or vice versa), otherwise `curl | bash` users get a stale tool while local users remain fine — a silent split-brain that shipped undetected in prior cycles.

Enforcement:

```bash
bash scripts/check-parity.sh
```

Exits 0 when identical, non-zero with a diff excerpt on drift.

The preferred way to enforce this (and every other lint) is the
`pre-commit` framework — install once per clone:

```bash
pre-commit install
```

This wires `.pre-commit-config.yaml` into `.git/hooks/pre-commit` and
runs parity + shellcheck + shfmt + hygiene hooks on every commit. A
standalone legacy hook at `.githooks/pre-commit` still exists for
users who prefer `git config core.hooksPath .githooks`.

Regression test: `tests/parity.bats` (3 cases — passes on tree, fails on induced drift, fails on missing markers).

## Installer trust chain

The installer may run in two modes:

1. **Local file execution** — `$0` is a real file path; payload is extracted directly via `awk`.
2. **Piped execution** — invoked as `curl ... | bash`, where `$0` is literally `"bash"` and no installer file exists on disk. In this case the installer re-downloads itself from `$SLEEP_AFTER_CLAUDE_INSTALLER_URL` (default: the `main` branch raw URL) into a temp file, sanity-checks it, then extracts.

The re-download path enforces:

- **Size envelope** — payload must be 2KB–512KB (guards against HTML error pages and truncated CDN responses).
- **Marker presence** — payload must contain both `__SCRIPT_START__` and `__SCRIPT_END__` literal lines.
- **Optional SHA-256 pin** — if `$SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` is set, the downloaded body's `shasum -a 256` must match before extraction proceeds.

Regression tests: `tests/installer-trust-chain.bats` (7 cases including size/marker rejection and SHA256 match + mismatch).

## Preflight fail-closed contract

The `--preflight` scan parses `pmset -g assertions` to predict whether `pmset sleepnow` will actually succeed. The function `scan_assertions` sets a global `PREFLIGHT_SCAN_OK` that is **true only when** pmset exited 0 AND produced the expected `Listed by owning process` header. A failing scan must never render as a green "clear" verdict.

Rendering contract (both JSON and human-readable):

| Scan state | Brief verdict | JSON `scan_ok` | JSON `can_sleep` |
|---|---|---|---|
| Scan failed | "Sleep-blocker scan unavailable" | `false` | `null` |
| Scan clear | "No sleep blockers detected" | `true` | `true` |
| Scan found blockers | "N sleep blocker(s): ..." | `true` | `false` |

Pre-watch gate: when `PREFLIGHT_SCAN_OK != true`, the tool requires TTY confirmation or `--force` — same behavior as when actual blockers are present.

Regression tests: `tests/preflight-fail-closed.bats` (6 cases including shimmed pmset failure).

## Testing

Tests use bats-core and PATH-shim mocks (fake `pmset` binaries in per-test TMPDIRs). They run fully offline and are deterministic (verified by double-run).

```bash
bats tests/                   # full suite
bats tests/parity.bats        # single file
bash -n sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
bash scripts/check-parity.sh
```

Check the live test count with `bats tests/ --count`.

### What's covered

Every finding fixed in the 2026-04-19 audit cycle has a regression test that would fail if its fix were reverted. See `tests/*.bats` — each file's header comment names the findings it protects.

### What's not covered

- The actual watch loop (polling + `kill -0`) and the `pmset sleepnow` invocation — would require putting the test machine to sleep or a Mach-level sleep mock that doesn't exist.
- The broad Claude-process-detection heuristic fallback (audit finding F-09, deferred).
- Network behavior of real `curl` against GitHub — tests use `file://` URLs only.

## Architecture of `sleep-after-claude`

Linear top-to-bottom flow with labeled section banners (`# ── Section ──`). Navigate by banners rather than line numbers — line numbers drift with edits. Major sections, in source order:

1. **macOS guard + TTY/Bash-version detection** — sets `USE_BUILTIN_SLEEP` (Bash ≥ 4 FIFO trick to avoid forking `sleep`), color toggles, and TTY flags that downstream output branches on.
2. **Config defaults + arg parsing** — flag table lives inline in the `--help` block. Keep the `case` arms above and the `--help` text in sync when adding flags.
3. **Claude process detection** (`find_claude_processes`) — two-tier: a "tight" pass using `pgrep -x claude` / `pgrep -f claude-code`, falling back to a broad `pgrep -fi claude` filtered by `EXCLUDE_PATTERN` to weed out Electron-based apps (Claude.app, Cursor, Windsurf, chrome-native-host, etc.). When adding a new false-positive, update `EXCLUDE_PATTERN`.
4. **Pre-flight scan** (`scan_assertions`, `preflight_scan`, `render_preflight*`) — inventories `caffeinate` processes, `pmset -g assertions`, clamshell/lid state, battery, user sessions, then emits a verdict. Gated by `--no-preflight`, restricted by `--brief`, machine-readable via `--json`. See "Preflight fail-closed contract" above.
5. **FIFO setup + cleanup trap** — opens fd 9 on a named pipe so the watch loop can `read -t` instead of forking `/bin/sleep` every tick.
6. **Early-exit modes** (`--list`, `--preflight`, then `--dry-run` / `--caffeinate-only`) run before the actual sleep.
7. **Watch loop** — polls the target PID until it exits or `--timeout` fires. PID-reuse detection compares the **binary path only** (first token of `ps -p ... -o command=`), not the full argv — argv mutation via `setproctitle` / `exec -a` must not trigger a false "reused" signal.
8. **Release caffeinate + `pmset sleepnow`** — the actual sleep action.

When modifying behavior, identify which section owns the concern; most flags touch exactly one section.

## Conventions

- Bash, `set -uo pipefail` (intentionally no `-e` — the script relies on non-zero exits from `pgrep` being non-fatal).
- All user-facing output goes through `print_header` / `print_step` / `print_ok` / `print_warn` / `print_error` / `print_done`. Don't emit raw `echo` for status lines — these helpers handle TTY/non-TTY color stripping.
- Integer validation uses `is_integer` / `is_positive_integer`; reuse rather than inlining regex.
- `--json` output is consumed by automation; any new preflight field must be added to the JSON emitter **and** the human-readable renderer **and** the JSON-shape assertions in `tests/preflight-fail-closed.bats`.
- `log_event` writes to `$LOG_FILE` only when `--log` is set. It warns to stderr **once per session** on first write failure (brace-grouped `{ echo ...; } 2>/dev/null` so bash's own redirection error is also suppressed). Subsequent failures stay silent to avoid spamming the watch loop.

### Formatting / linting

All shell scripts are formatted with `shfmt -i 2 -ci` and linted with `shellcheck -S warning`. Both run automatically via the `pre-commit` framework (`.pre-commit-config.yaml`). Run manually:

```bash
shfmt -w -i 2 -ci sleep-after-claude install-sleep-after-claude.sh scripts/*.sh .githooks/pre-commit tests/lib/common.bash
shellcheck -S warning sleep-after-claude install-sleep-after-claude.sh scripts/*.sh .githooks/pre-commit tests/lib/common.bash
pre-commit run --all-files
```

Intentional shellcheck suppressions live next to the code via `# shellcheck disable=SCxxxx` with a reason. Don't add suppressions without a reason.

For editor experience, `bash-language-server` gives real-time shellcheck diagnostics and cross-file symbol navigation — install it as your editor's LSP for bash.

## Installer conventions

- Shell rc detection: `zsh` → `~/.zshrc`; `bash` → `~/.bash_profile` if exists else `~/.bashrc`. Unknown shells (fish, nushell, etc.) **skip alias install** and print manual instructions — do not fall through to `~/.zshrc`.
- The `goodnight` alias line is written with `$HOME` **expanded at install time** to an absolute path. Reinstalls strip any prior `alias goodnight=` line (and its `# sleep-after-claude shortcut` header comment if directly above) before re-appending — this makes reinstalls at a new path idempotent.
- Verification failure (`$TARGET --help` returning non-zero) is a hard error — installer exits 1, not warn-and-continue.

## Audit cycle history

### 2026-04-19

Full audit → remediation → test expansion → docs sync cycle.

- **Audit:** 17 findings (1 Critical, 7 High, 9 Notable).
- **Remediation:** 9 findings fixed across 4 commits (F-02, F-03, F-04, F-05, F-06, F-07, F-08, F-10, F-11). 7 Notable deferred (F-09, F-12, F-13, F-14, F-15, F-16, F-17) — see per-finding rationale in commit messages.
- **Test expansion:** 31 bats tests added, deterministic, fully offline.
- **Docs:** this file rewritten to match post-remediation state.

Commits: `git log --oneline` from `737fd43..main`.

Notable decisions captured inline in this file:

- Parity enforcement via `scripts/check-parity.sh` + optional `.githooks/pre-commit` rather than auto-generating the installer from the standalone (dual-file architecture preserved; single-source-of-truth deferred to next cycle).
- Installer trust chain adopted size + marker + optional SHA-256 gating rather than pinning to a commit SHA by default (users can pin via env var; default stays on `main` for frictionless `curl | bash`).
- Preflight fails closed (not open) on unknown pmset state — a silent "clear" verdict is the worst possible failure for this tool.
