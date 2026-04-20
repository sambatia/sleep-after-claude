# Contributing to goodnight

Thanks for considering a contribution. This project is a small, single-purpose macOS Bash utility; the bar for changes is correctness, safety, and not breaking the `curl | bash` install path for existing users.

## Ground rules

- **Parity is non-negotiable.** `install-sleep-after-claude.sh` embeds a byte-identical copy of `sleep-after-claude` between `__SCRIPT_START__` / `__SCRIPT_END__`. Any change to one must be mirrored into the other. CI and pre-commit enforce this.
- **Tests are required for behavior changes.** If you change a behavior that a reviewer could plausibly regress six months from now, add a bats test that proves the new behavior and would fail if the fix were reverted.
- **No new runtime dependencies without discussion.** The project's value prop is "works on a clean Mac with zero prerequisites." `jq` is the single soft dependency; adding a second needs a strong argument.
- **macOS-only.** Linux or Windows patches are out of scope unless a separate, clearly-labeled port is proposed first.

## Local setup

One-time clone setup:

```bash
brew install bats-core shellcheck shfmt pre-commit
pre-commit install
```

This wires `.pre-commit-config.yaml` into `.git/hooks/pre-commit`, so every commit runs parity + shellcheck + shfmt + hygiene hooks automatically.

## Workflow

1. Fork the repo and create a feature branch off `main`.
2. Make your change in `sleep-after-claude`.
3. **Mirror the change into the embedded payload of `install-sleep-after-claude.sh`.** If you forget, `bash scripts/check-parity.sh` fails and so does the pre-commit hook.
4. Add or update a test in `tests/*.bats` for any behavior change.
5. Run the full test suite:
   ```bash
   bats tests/
   bash scripts/check-parity.sh
   bash -n sleep-after-claude install-sleep-after-claude.sh
   pre-commit run --all-files
   ```
6. Commit with a descriptive message. Reference any finding IDs (e.g., `fix(F-07): …`) in the subject line if applicable.
7. Open the PR against `main`. Fill out the PR template — it prompts for the parity + test + manual-verification boxes reviewers actually look at.

## Style

- Bash, `set -uo pipefail` (intentionally no `-e` — the script relies on non-zero exits from `pgrep` being non-fatal).
- `shfmt -i 2 -ci` formatting.
- `shellcheck -S warning` — intentional suppressions must be inline with a reason (e.g., `# shellcheck disable=SC2207 # word-splitting desired for pgrep output`).
- All user-facing output goes through the `print_*` helpers; TUI prompts go through `ui_*` helpers.
- Section banners (`# ── Section ──`) for navigation in long scripts.
- No tabs.

See `CLAUDE.md` for the full architecture map and convention list.

## Reporting bugs

Open an issue using the **Bug report** template. Include:

- macOS version (`sw_vers -productVersion`)
- Bash version (`bash --version`)
- Exact command you ran
- What you expected
- What actually happened
- Tail of `~/.local/state/sleep-after-claude.log` if you were running with `--log`

## Reporting security issues

**Please do not open a public GitHub issue for security reports.** See `SECURITY.md` for the private-disclosure process.

## Suggesting a feature

Open an issue using the **Feature request** template. Describe the problem first, then the proposed behavior, then alternatives considered. Bias against adding flags — the tool is already at the complexity ceiling for a single-file bash utility.
