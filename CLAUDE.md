# platform-examples: agent instructions

This repo is **public**. Everything you write here, including issues, commit messages and PR bodies, can be read by anyone.

## Public-repo rules

- Use generic names only: domains are `orders` and `billing`, services are `api`, `web` and `admin`, the environment is `stage`.
- Use placeholders for every account ID, domain, hostname, email and name (`000000000000`, `example.com`, `<placeholder>`).
- Never mention a real company, team, customer, partner or internal system, and never paste code or text from another repo. Write every file fresh.
- Never commit secrets, even fake ones that look real. Tests build fake secrets at runtime from fragments.

## How to work

- The `make` targets are the interface. Run, test and document the repo through them only (see `Makefile`).
- Before finishing a change, run `make check` (the same static checks the PR workflow runs).
- Pin every GitHub Action to a full commit SHA with a `# vX.Y.Z` comment. `make check-actions` enforces this.
- Write tests first for hooks and scripts, and test them through their command-line interface.
- Use the vocabulary in `CONTEXT.md`. Record lasting decisions as ADRs in `docs/adr/`.

## Guardrail hooks

`.claude/settings.json` runs two `PreToolUse` hooks from `.claude/hooks/`:

- `secret_guard.py` blocks secret-shaped values in writes and commands, and reads of well-known secret files.
- `command_guard.py` blocks cluster and cloud writes, destructive commands and data exfiltration.

If a hook blocks you, don't work around it. Explain to the human what you were trying to do and let them run it. Tests for both live in `tests/hooks/`.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues (`arsanurak/platform-examples`), handled with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: needs-triage, needs-info, ready-for-agent, ready-for-human, wontfix. See `docs/agents/triage-labels.md`. `scripts/create-labels.sh` creates them.

### Domain docs

Single-context: one root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.
