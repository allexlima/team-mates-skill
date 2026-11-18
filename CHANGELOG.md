# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-18

First tagged release. It covers everything since the repo began on 2026-09-30,
then this release's fixes and the new contributor flow.

### Added

- The `/team` skill: a lead session that runs a team of interactive Claude Code
  sessions, one per pane in cmux or tmux, with a shared task file, challenge
  rounds, and a git-ignored `.team/` folder for roles, run records and facts.
- A shared role library and a facts ledger that `facts-lint` checks against the
  files each fact cites.
- A live monitor with a progress column, a per-teammate bar and an ETA, built
  from each teammate's own `· NN%` status line (self-reported, not measured).
- A tmux fallback backend, so cmux is recommended and no longer required.
- `doccheck`, which fails on drifted docs, an undocumented subcommand or flag,
  and a `SKILL.md` at the repo root.
- GitHub Actions CI on macOS and Ubuntu (`gate (macos-latest)`,
  `gate (ubuntu-latest)`), the `dev` / `main` branch workflow in `CLAUDE.md`,
  and a `shellcheck` step that fails on errors.

### Changed

- The skill now ships from `skills/team/` only; `npx skills add` finds one
  skill.
- `TEAM_REG_DIR` gets the same checks as the default registry dir (a real
  directory you own, mode 0700, not a symlink). Registries written under
  `/tmp` by earlier versions are not migrated.
- The monitor flags "idle with work pending" for a teammate that holds its own
  ready task, and counts only this team's tasks.
- On a build run, a teammate's `Edit` is pre-approved for its worktree and run
  files only. Other runs keep bare `Edit` and `Write`.
- `.githooks/pre-commit` is gone; CI runs `doccheck`.
- `.gitignore` no longer lists other tools' leftovers.
- The README links to `--help` for optional dependencies instead of repeating
  them.

### Documentation

- `HELP.md`, `SKILL.md` and `teammate-rules.md` now describe the registry-dir
  checks, the scoped `Edit` as pre-approval, the hook-skip denies and the gaps
  in them, and the monitor's team-scoped task counts.
- `HELP.md` lists the optional dependencies (superpowers, humanizer,
  beautify-github-readme, diagram-design, caveman, the Chrome DevTools MCP with
  Google Chrome stable, and the no-mistakes CLI) and what a run loses without
  each.
- `TODO.md` is closed out for this release: finished items are gone, and the
  open ones (shell-lint warnings, the TUI monitor, the hook fence) are for
  v0.2.0.

### Fixed

- GNU `stat` order in `lib/status.sh` and its tests, which broke ELAPSED and
  AGE on Linux.
- The monitor exits 0 when you quit under `set -u`.
- A teammate that claims a task with a `T<n>:` status prefix no longer counts
  as unassigned.
- The status-render suite runs on macOS runners without GNU `timeout`.
- The model reader uses the Linux managed-settings path
  (`/etc/claude-code/managed-settings.json`).
- `doccheck` ignores a trailing full stop after a skill path.
- A relative `TMPDIR` no longer makes a registry dir that depends on the
  caller's cwd.

### Security

- `spawn --resume` refuses a registry session id that is not a UUID. A
  reproduced command injection came through that path.
- The registry and the launcher and system-prompt files live in a private
  per-user dir, not in shared `/tmp`.
- Teammates are denied `git commit --no-verify` and its prefixes through
  `--disallowedTools`. The rule is a text match: a combined short flag such as
  `-an`, or a commit after a git global option, still gets through.
- Tool-list flags are passed as `--flag=value`, so a variadic flag can no
  longer swallow the prompt.

[Unreleased]: https://github.com/allexlima/team-mates-skill/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/allexlima/team-mates-skill/releases/tag/v0.1.1
