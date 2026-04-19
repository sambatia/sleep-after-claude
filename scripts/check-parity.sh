#!/usr/bin/env bash
# Verifies the embedded sleep-after-claude payload inside
# install-sleep-after-claude.sh is byte-identical to the standalone
# sleep-after-claude script. Used as a pre-commit hook and a manual
# `make`-style check.

set -eu

cd "$(dirname "$0")/.."

if [[ ! -f sleep-after-claude || ! -f install-sleep-after-claude.sh ]]; then
  echo "check-parity: expected sleep-after-claude and install-sleep-after-claude.sh in repo root" >&2
  exit 2
fi

embedded="$(mktemp)"
trap 'rm -f "$embedded"' EXIT

awk '/^__SCRIPT_START__$/{flag=1; next} /^__SCRIPT_END__$/{flag=0} flag' \
  install-sleep-after-claude.sh > "$embedded"

if [[ ! -s "$embedded" ]]; then
  echo "check-parity: could not extract embedded payload (missing markers?)" >&2
  exit 1
fi

if ! diff -q "$embedded" sleep-after-claude >/dev/null; then
  echo "check-parity: FAILED — embedded installer payload drifted from sleep-after-claude" >&2
  echo "check-parity: first divergence:" >&2
  diff "$embedded" sleep-after-claude | head -20 >&2
  exit 1
fi

echo "check-parity: OK"
