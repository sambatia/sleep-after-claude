<!--
Thanks for the PR! Fill in the sections below so reviewers can move quickly.
Delete any section that doesn't apply.
-->

## What this changes

<!-- One-paragraph summary. Reference any finding IDs (F-NN) if applicable. -->

## Why

<!-- What user-facing problem does this solve, or what internal risk does it reduce? -->

## How to verify

<!-- Commands a reviewer can run locally to confirm the change. -->

```bash
# Example:
bats tests/
bash scripts/check-parity.sh
bash -n sleep-after-claude install-sleep-after-claude.sh
```

## Checklist

- [ ] Changes to `sleep-after-claude` are mirrored into the embedded payload in `install-sleep-after-claude.sh`.
- [ ] `bash scripts/check-parity.sh` reports `check-parity: OK`.
- [ ] `bats tests/` passes locally.
- [ ] New behavior is covered by a test that would fail if the fix were reverted.
- [ ] `pre-commit run --all-files` is clean (parity + shellcheck + shfmt + hygiene).
- [ ] No secrets, tokens, or private paths added to tracked files.
- [ ] If a new flag was added: `--help` text, the `case` arms, and any relevant docs in `CLAUDE.md` are all updated.

## Linked issues

<!-- Closes #N, refs #M -->
