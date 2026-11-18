# CLAUDE.md — contributor guardrails for Team-mates (the /team skill)

This repo is one skill (`skills/team/SKILL.md`), one orchestration script
(`skills/team/scripts/team.sh` + `scripts/lib/`), and user docs
(`skills/team/references/HELP.md`, `README.md`). Only `skills/team/` is installed;
tests, hooks, this file, TODO.md and the README stay at the repo root, and the root
must never hold a SKILL.md (`npx skills` stops discovery there).

Its recurring failure mode is **doc drift** —
the same fact stated three different ways across those files. The rule below keeps
one owner per fact; everything else points to it or quotes it verbatim.

## Single source of truth

Every behaviour fact has exactly **one owner file**. Other files link to it or
quote it word-for-word — they never restate it in their own words. Paths in the
table are relative to `skills/team/` (`HELP.md`, `teammate-rules.md` and
`git-practices.md` live in `references/`), except `README.md` at the repo root.

| Topic | Owner | Everyone else |
|---|---|---|
| Flags, defaults, ranges (model default, team size, layout) | `HELP.md` (what `--help` prints) | `SKILL.md` keeps only what the lead must act on; `README.md` links to `--help` instead of keeping its own flag table |
| Lead procedure (steps, gates, order) | `SKILL.md` | `HELP.md` / `README.md` describe outcomes only |
| Script interface (subcommands, args, exit codes) | `scripts/team.sh` header (the comment block above `set -euo pipefail`) | `SKILL.md` shows only the invocations it needs |
| Role resolution order | `team.sh role` (code) + `SKILL.md` S2 (one sentence) | `HELP.md` and `README.md` are word-for-word summaries |
| Role content format (the five headings) | `SKILL.md` (the save-role step) | — |
| Project facts | `.team/facts.md` only | roles never hold facts; the shared library never holds project content |
| Monitor interaction (row keys, click, PROGRESS/ETA) | `HELP.md` (the monitor paragraph) | `scripts/lib/status.sh` holds the behaviour; the teammate-side `· NN%` rule is owned by `teammate-rules.md`. The percentage is self-reported — never describe it as measured. |
| Live vs. finished teammate state | `SKILL.md` step 4 (one sentence) | `HELP.md` says the same thing in the same words. Hook-based state covers *live* teammates only; a finished one has no surface, so its state is read from disk + registry. Do not "fix" this back to hooks. |
| Role vs. knowledge | role spec = *how to work* (lens, constraints, tier, lessons); `.team/facts.md` = *what is true here* | neither stores the other |

## When you change a default, flag, or behaviour

1. Edit the **owner** file above.
2. Grep the repo for the old wording and update or delete the copies.
3. Run `bash skills/team/scripts/team.sh doccheck` — it flags retired drift phrases
   (`inherit the lead`, `stacked`, `3–5`, `2–5`, `as much as possible`, `team.sh park`,
   `cmux browser`, `cmux-only` and `cmux is required`), confirms every subcommand is documented in the `team.sh` header,
   confirms every `--flag` in `SKILL.md`'s argument-hint is explained in `HELP.md`,
   fails if the repo root holds a `SKILL.md`, and fails if a doc names a
   `~/.claude/skills/team/…` or `<abs skill dir>/…` path that is not in the skill.
   Fix what it reports.

CI runs `doccheck` on every push and PR, so there is no local hook to enable.

## Branch workflow

`main` is stable and released; `dev` is the integration branch. The
maintainer sets branch protection on both (GitHub settings, not in this repo):
PR required, green CI required, no force-push or deletion, enforced for
admins, 0 approvals.

1. Branch from `dev` as `feat/…`, `fix/…`, `docs/…`, `ci/…` or `chore/…`.
2. Commit as `git-practices.md` says, one logical change each.
3. Run the full gate set below locally with `TEAM_MEMBER` unset.
4. Open a PR into `dev` through the no-mistakes gate
   (`no-mistakes axi run --base-branch dev`). Wait for the CI checks
   `gate (macos-latest)` and `gate (ubuntu-latest)`; never merge on red.
5. Release: PR `dev` → `main`, then an annotated `vX.Y.Z` tag on `main` and a
   GitHub Release. Move `CHANGELOG.md`'s `[Unreleased]` entries under the new
   version in the PR that releases it.

CI (`.github/workflows/ci.yml`) runs the gate set below on macOS and Ubuntu,
except `facts-lint`: it reads the git-ignored `.team/facts.md`, so it is local-only. Change the list here and in the workflow in the same commit.

## The full gate set

`doccheck` is the doc guard only. Before merging a branch, run every suite
with `TEAM_MEMBER` unset (an inherited value makes
`rev4-3` fail for the wrong reason):

```
bash -n skills/team/scripts/team.sh skills/team/scripts/lib/*.sh
bash skills/team/scripts/team.sh doccheck
shellcheck -S warning skills/team/scripts/team.sh skills/team/scripts/lib/*.sh tests/*.sh
bash tests/roles.sh
bash tests/team-build.sh      # spawn/registry/close/reap
bash tests/team-cli.sh        # secret regex, facts-lint
bash tests/status-render.sh   # monitor frames, widths, colour gate
bash tests/team-finish.sh     # finish guards, --resume, round baselines
bash tests/tmux.sh            # tmux fallback backend (real-tmux smoke test skips without tmux)
bash tests/plugin-events.sh   # once the file is on dev; CI skips a missing suite
bash tests/monitor-tui.sh     # once the file is on dev; needs Textual for full coverage
bash skills/team/scripts/team.sh facts-lint # CHECK rows are expected when cited files changed
```

Add a new suite to this list in the same commit that adds the file, or the next
run's gates silently skip it.
