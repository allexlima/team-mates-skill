# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A `gating` monitor state for a teammate inside a no-mistakes gate: its
  status line ends in `gating <sha>`, `status --json` carries `gate_sha`, and
  it turns `stalled?` only after 45 silent minutes instead of 10.

### Changed

- The lead asks the user every question (role pulls, lessons, merges, the
  build-run OK) through AskUserQuestion.
- `team.sh status` polls are cheaper: one python process asks cmux for panes,
  notifications and every teammate's surface concurrently, and `--json --sync`
  runs the summary once for both the sidebar and the JSON. `status --json`
  output is unchanged. The median under real cmux with a live team went from
  1.50 s to 1.11 s.
- CI's `shellcheck` step now fails on warnings, not only errors, and the repo is
  clean at that level (SC1007 included).

### Fixed

- `team.sh close` removes the team's `.sync` sidecar once every row is closed,
  so a tmux team no longer leaks it, and `close` and `clean` also remove a
  dropped teammate's unrun launcher files.

## [0.2.0] - 2026-11-19

### Added

- A Textual TUI monitor (`scripts/monitor_tui.py`), fed by a new
  `team.sh status --json`. It shows one card per teammate with its
  self-reported progress, an ETA marked as a forecast, a details screen and a
  `--demo` mode. Textual is optional; without it the text monitor runs as
  before. `tests/monitor-tui.sh` is in the gate set. (#14)
- `team.sh prompt`, which renders each teammate prompt from
  `references/prompt-template.md` plus a short per-run brief, so `SKILL.md`
  keeps only the procedure. (#13)
- `plugin/`, a session-only hook plugin. Its `event.sh` appends one line per
  Claude Code event (time, event, tool name, notification type; never tool
  input) to `$TEAM_EVENTS_FILE`. Its PreToolUse `fence.py` denies edits
  outside `$TEAM_FENCE_ROOTS` and git commands that skip hooks. The fence
  narrows the hole but does not make `Bash` safe. (#7, #5)
- README GIFs of the monitor and `--help`, recorded from the `.tape` scripts in
  `assets/readme/tapes/`. (#16)
- `team.sh spawn` loads that plugin (`--plugin-dir`) for every teammate with a
  run dir and sets its events file, scratch dir and fence roots; it warns on
  stderr when there is no run dir. `team.sh clean` also removes finished
  teammates' scratch dirs and system prompts. (#18)
- `status` reads live teammates' state from the event log, under tmux too: a
  `permission` state for a teammate blocked on a tool-permission prompt, and
  idle and activity age taken from the events. `status --json` adds
  `event_state`, `event_age_s` and `open_tool`. (#20)
- Step progress: a teammate status line `T<n>: k/N · <step>` sets that
  teammate's self-reported % to k/N in `status` and the monitor (see `--help`);
  `status --json` adds `step_k` and `step_n`. (#21)

### Changed

- The README is rewritten from scratch around the pane-grid theme. (#19)
- The monitor reads the context window of 1M-token models correctly, and
  `status --json --sync` polls about twice as fast with 7 live teammates. (#14)
- The TUI's token total (`Σ … out`) counts output tokens, not cache re-reads,
  which had inflated it. (#14)

### Fixed

- `doccheck` no longer reports a documented subcommand as missing: a
  `printf | grep -q` pipeline took SIGPIPE under `pipefail`. Four other such
  pipelines in `team.sh` and `lib/status.sh` now use here-strings too. (#17)
- `tests/status-render.sh` G7 passes under the C locale. (#15)
- `team.sh clean` no longer removes another team's build-run worktrees when one
  team's name is a prefix of another's. (#18)

### Known limits

- `tests/status-render.sh` AQ1 hangs now and then on a busy machine; the cause
  is not found. The test prints the pty tail and a `ps` snapshot when it hangs.
  (#15)
- Mouse clicks in the TUI under cmux are unverified.

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

[Unreleased]: https://github.com/allexlima/team-mates-skill/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/allexlima/team-mates-skill/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/allexlima/team-mates-skill/releases/tag/v0.1.1
