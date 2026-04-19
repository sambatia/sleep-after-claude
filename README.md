# sleep-after-claude

Sleep your Mac automatically when a Claude Code task finishes.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/sambatia/sleep-after-claude/main/install-sleep-after-claude.sh | bash
```

If the install fails with `awk: can't open file bash` or `Extraction failed`,
the GitHub raw CDN may be serving a stale copy (up to 5 min cache). Bust the
cache with a query string:

```bash
curl -fsSL "https://raw.githubusercontent.com/sambatia/sleep-after-claude/main/install-sleep-after-claude.sh?v=$(date +%s)" | bash
```

To pin to a specific commit (recommended for unattended/provisioning use):

```bash
SLEEP_AFTER_CLAUDE_INSTALLER_URL="https://raw.githubusercontent.com/sambatia/sleep-after-claude/<sha>/install-sleep-after-claude.sh" \
SLEEP_AFTER_CLAUDE_INSTALLER_SHA256="<expected-sha256>" \
  bash -c "curl -fsSL \"$SLEEP_AFTER_CLAUDE_INSTALLER_URL\" | bash"
```

## Usage

```bash
goodnight --help       # show options
goodnight --preflight  # audit your system for sleep blockers
goodnight              # watch Claude + sleep when finished
```

macOS only.

## Contributing

Project knowledge for humans and agents lives in [CLAUDE.md](CLAUDE.md) — architecture, conventions, the parity invariant between the standalone script and the installer, and the audit-cycle history.

Regression tests use [bats-core](https://github.com/bats-core/bats-core):

```bash
bats tests/                 # full suite
bash scripts/check-parity.sh # verify embedded installer payload matches standalone
```

Enable the parity pre-commit hook once per clone:

```bash
git config core.hooksPath .githooks
```
