# Public release checklist

A living checklist for taking this repository from private/personal to cleanly public on GitHub. The **automated / local** section has already been handled in-repo by the `chore/public-release-hardening` branch — everything else requires human action in the GitHub UI (or maintainer judgment) and is listed explicitly.

---

## 1. Already handled locally ✅

These items shipped via `chore/public-release-hardening`. Nothing to do here unless you want to customize.

- [x] **`LICENSE`** — MIT, copyright Sameh Abdalla, 2026.
- [x] **`.gitignore`** — covers `.env*`, keys, OS junk, editor junk, logs, caches, `.claude/`, pre-commit cache, `node_modules/`, coverage.
- [x] **`CONTRIBUTING.md`** — setup, workflow, parity rule, style, bug-report guidance.
- [x] **`SECURITY.md`** — private-disclosure process, threat model, hardening guidance for users.
- [x] **`.github/ISSUE_TEMPLATE/bug_report.yml`** — structured bug form.
- [x] **`.github/ISSUE_TEMPLATE/feature_request.yml`** — structured feature form with scope checks.
- [x] **`.github/ISSUE_TEMPLATE/config.yml`** — disables blank issues; routes security reports privately.
- [x] **`.github/pull_request_template.md`** — PR form enforcing parity + test + hygiene checklist.
- [x] **`.github/dependabot.yml`** — weekly GitHub Actions version bumps.
- [x] **`.github/workflows/ci.yml`** — macOS runner: syntax + shellcheck + shfmt + parity + bats on every PR and push to `main`.
- [x] **Installer file-header** — documents all 9 install steps + env-var overrides (already landed in `main`).
- [x] **Sensitive-data scan** — no secrets, tokens, or hardcoded user paths found in tracked files.

No `CODE_OF_CONDUCT.md` is included. The project is small-surface; a formal code of conduct adds maintenance burden without materially improving contributor quality at this scale. Add one if / when the project grows enough community that moderation needs a written standard.

---

## 2. Manual GitHub UI configuration required

Do these **before** flipping the repo to public (or immediately after). Order matters for a few of them.

### 2a. Repo → Settings → General

- [ ] **Description** — one-liner. Suggested: *"macOS Bash utility that watches a Claude Code session and sleeps your Mac when it finishes."*
- [ ] **Website** — optional. If you don't have a landing page, leave blank.
- [ ] **Topics** — suggested: `macos`, `bash`, `cli`, `claude-code`, `developer-tools`, `power-management`, `sleep`.
- [ ] **Features:**
  - [ ] Issues — **enabled**.
  - [ ] Projects — leave off unless you actually use them.
  - [ ] Discussions — **enable** (the issue-template `config.yml` already links to the Discussions URL). Alternative: remove the Discussions link from `.github/ISSUE_TEMPLATE/config.yml`.
  - [ ] Wiki — disable (README + CLAUDE.md are the canonical docs).
- [ ] **Pull Requests:**
  - [ ] Allow squash merging — **on** (preferred default merge).
  - [ ] Allow merge commits — off (keeps history flat).
  - [ ] Allow rebase merging — off.
  - [ ] **Automatically delete head branches** after merge — **on**.
  - [ ] Default to PR title for squash-merge commit message — **on** (cleaner history).
- [ ] **Archives** — leave defaults.

### 2b. Repo → Settings → Code security and analysis

Enable all of these:

- [ ] **Dependabot alerts** — on.
- [ ] **Dependabot security updates** — on.
- [ ] **Dependency graph** — on.
- [ ] **Secret scanning** — on (GitHub will scan both current code and historical commits).
- [ ] **Secret scanning — push protection** — on.
- [ ] **Code scanning** — this project is pure Bash. GitHub's CodeQL does not support bash as a first-class language, so CodeQL is not enabled. If you later add any JavaScript, Python, Go, etc., enable CodeQL at that point. The `shellcheck` job in `.github/workflows/ci.yml` is the effective static-analysis layer for the bash code.

### 2c. Repo → Settings → Rules → Rulesets (or Branches → Branch protection)

Create one ruleset targeting `main` with:

- [ ] **Require a pull request before merging** — on.
  - [ ] Require 1 approval (even if that approval is from yourself from a different account; relax if you work solo and the friction is too high).
  - [ ] Dismiss stale approvals when new commits are pushed — on.
  - [ ] Require conversation resolution before merging — on.
- [ ] **Require status checks to pass before merging** — on. Required checks (add after the first successful CI run so GitHub knows they exist):
  - [ ] `Lint (shellcheck + shfmt + syntax)`
  - [ ] `Parity (installer payload ↔ standalone)`
  - [ ] `bats regression suite`
- [ ] **Require branches to be up to date before merging** — on.
- [ ] **Block force pushes** — on.
- [ ] **Restrict deletions** — on (prevents accidental deletion of `main`).
- [ ] **Apply to administrators / bypass list is empty** — on (no bypass unless you really need it).
- [ ] **Require linear history** — on (matches the squash-merge default above).

### 2d. Repo → Settings → Actions

- [ ] **Actions permissions → Allow all actions and reusable workflows** — or restrict to GitHub-verified + the actions actually used (`actions/checkout@v4`). The CI workflow uses only `actions/checkout@v4` today.
- [ ] **Workflow permissions → Read repository contents** — default. No write permissions needed for the current CI.
- [ ] **Fork pull request workflows from outside collaborators** — "Require approval for all outside collaborators" is the safe default.

### 2e. Repo → Security → Private vulnerability reporting

- [ ] **Enable** — so the `SECURITY.md` link `github.com/…/security/advisories/new` actually works for external reporters.

### 2f. Flip visibility

- [ ] **Settings → General → Change visibility → Make public**. Confirm the repo name and accept the warning that issues, PRs, and the full git history will become public.

---

## 3. Should be reviewed by a human before / shortly after publishing

- [ ] **README license claim.** `README.md` Section 18 currently says *"No license file is currently present… 'All rights reserved' by default."* After this cycle, a `LICENSE` file does exist (MIT). The legal LICENSE file supersedes the README note, but the README wording is now stale. Updating README is explicitly out of scope for this hardening pass per the task brief; recommend a one-line fix in a follow-up commit. *(Suggested replacement: "This project is released under the MIT License — see `LICENSE` for the full text.")*
- [ ] **Confirm the author name and year** in `LICENSE` (currently: *Sameh Abdalla, 2026*). Change if this should be attributed differently (e.g., a future company/organization).
- [ ] **Confirm the `sambatia` GitHub username / org** in raw URLs across `sleep-after-claude` and `install-sleep-after-claude.sh`. If the repo ever moves under a different org, the installer and self-update URL defaults must be updated (users can always override via `SLEEP_AFTER_CLAUDE_INSTALLER_URL` / `SLEEP_AFTER_CLAUDE_UPDATE_URL`, but the defaults should be correct).
- [ ] **Consider tagging a first release.** Once `main` is clean and CI is green, cut `v0.1.0`. Recommended: attach the SHA-256 of `install-sleep-after-claude.sh` at that tag to the release notes so security-conscious users can pin via `SLEEP_AFTER_CLAUDE_INSTALLER_SHA256` against a known-good published value.
- [ ] **Git history scan.** This cycle verified that no secrets exist in the **current** tree. A full historical scan (e.g., with `gitleaks detect --source . --log-opts=--all`) is recommended before publishing — any secret ever committed, even if later removed, remains in history and is retrievable by anyone after the repo goes public. If a secret is found in history, the right response is rotation, not rewriting history (rewrites invalidate cloned forks and break the `curl | bash` install URLs).

---

## 4. Sanity commands

Run once locally before publishing:

```bash
# Lint + syntax + parity
bash -n sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
bash scripts/check-parity.sh
shellcheck -S warning sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh
shfmt -d -i 2 -ci sleep-after-claude install-sleep-after-claude.sh scripts/check-parity.sh

# Full test suite
bats tests/

# Pre-commit sweep
pre-commit run --all-files

# Last look for anything sensitive (adjust paths / tools as available)
# gitleaks detect --source . --log-opts=--all --verbose
```

All of the above should exit clean. CI enforces the same invariants on every PR.
