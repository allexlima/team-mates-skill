# TODO

Open items. Each one names where the work lives.

## Verify in a real run

- [ ] Run a full team in cmux end to end: spawn, reuse a teammate for a second backlog task,
      monitor %/ETA, finish, close. The cmux tests (`tests/team-build.sh`,
      `tests/team-finish.sh`) use a stub.
- [ ] Run a full team in tmux with real `claude` sessions. The real-tmux test in
      `tests/tmux.sh` (X9) starts a fake `claude` that only sleeps.
- [ ] Try UI QA through the Chrome DevTools MCP from a teammate. The MCP needs Google Chrome
      stable and fails with only Chrome Beta installed. Say so in `teammate-rules.md` and
      `HELP.md` (both in `skills/team/references/`), or document how to point the MCP at another channel.

## Monitor

- [ ] `_st_summary` (`skills/team/scripts/lib/status.sh`) counts every task line in the run's `tasks.md`, including
      lines owned by another team. Filter owners to `<team>-*` and `any`. This only matters
      when two teams share a run dir.
- [ ] Decide whether "idle with work pending" should also fire when an idle teammate has a ready
      task of its own (today it fires only for unassigned tasks).

## Shell lint

- [ ] v0.2.0: clean up `shellcheck -S warning`; CI gates at `-S error` for v0.1.1. Ten warnings
      (shellcheck 0.11; `.shellcheckrc` turns SC1007 off on purpose). Re-run
      `shellcheck -S warning -f gcc skills/team/scripts/team.sh skills/team/scripts/lib/*.sh tests/*.sh`
      before fixing, since line numbers move: team.sh SC2034 (unused `i`); lib/mux.sh and
      lib/status.sh SC2154 (`sub`/`here` unassigned); lib/status.sh SC1010 (missing `;` before
      `done`); tests/roles.sh SC2115 (use `${var:?}`); tests/status-render.sh SC2097/SC2098;
      tests/team-finish.sh and tests/tmux.sh SC2034 (unused `CMUX_GONE_REFS`, `o3`).

## TUI monitor

Reported by tm2-tui (branch `feat/tui-monitor`); not re-measured here.

- [ ] Mouse clicks in the TUI monitor under cmux are unverified. cmux `send-key`/`send` cannot
      synthesize clicks, so a person has to click a card in a real cmux pane: a click should focus,
      a double-click should open details, and cmux should not take the click first.
- [ ] Poll cost: `team.sh status --json --sync` with 7 live teammates under real cmux took
      4.7-6.7s before and 2.1-2.8s after the fork cuts (03933ef). That is fine at the default 5s
      interval; the 1.5s target is deferred. What is left is three python starts (list-panes,
      list-notifications, summary) plus one cmux `identify` per teammate. Next step: one python
      process doing identify, notifications and summary.
- [ ] The TUI's "Σ tok" sums input plus cache-read tokens per message, so cache re-reads dominate
      (118M for a 45-minute run). Relabel it or show output tokens only.

## Permissions

- [ ] `_team_allow` (`skills/team/scripts/team.sh`) approves Edit and Write on any path. Scope them to the
      teammate's worktree or owned files once the worktree path is known before the permission
      block.
- [ ] `git commit --no-verify` is blocked only by a rule in `skills/team/references/teammate-rules.md`. Look at a
      `--disallowedTools` entry for it, since it skips secret-scanning hooks.

## Security

The registry dir is now a private per-user dir (`${TMPDIR:-/tmp}/team-<uid>`, 0700, refused unless
we own it), so the `.tabs` registry and its sidecars are no longer in a shared dir. What is left:

- [ ] No test uses a second user, so "a registry dir owned by someone else is refused" is checked
      only by reading `_reg_dir` (`[ -O ]`), not by running it. Needs a second account or root.
- [ ] An explicit `TEAM_REG_DIR` is trusted as given. If someone points it at a shared dir
      (e.g. `/tmp`), the old predictable-name risk is back for the `.tabs`, `.round`, `.sync` and
      `$reg.tmp` files; the launcher and system prompt are safe there (mktemp).
- [ ] Registries and sidecars an older version left in `/tmp/team-*.tabs` are ignored, not
      migrated: `reap` and `status` look only in the new dir. Close such a team with the old copy,
      or move its files into the new dir by hand.

## tmux backend

- [ ] `_mux_titles` (`skills/team/scripts/lib/mux.sh`) lists panes from the default tmux server
      only (or `TEAM_TMUX_SOCKET`, which only the tests set). A lead running on another socket
      (`tmux -L`) would read its teammates as gone.

## Hook fence and cleanup

Reported by tm2-hooks (branch `feat/hook-spawn`, not yet in `dev`); not re-checked here.

- [ ] `team.sh clean` removes a team's per-teammate `.scratch` dirs and `.sysprompt.md` files from
      the registry dir (21058af). It still leaves the team's `.sync` sidecar and the launcher files.
      Decide whether `close` or `clean` owns removing `.sync`.
- [ ] `TEAM_FENCE_ROOTS` is `:`-separated, so a worktree or run path containing `:` splits into
      wrong roots. It fails closed (writes there are denied). Fix only if someone hits it.
- [ ] The PreToolUse fence covers only Edit/Write and the listed git forms. It does not cover
      `eval`, backticks, `$(...)`, `xargs`, `env -S` strings, a changed `HOME` or
      `XDG_CONFIG_HOME`, aliases already in the user's git config, GNU `time --output`, or any
      other Bash write. A real Bash sandbox is still open.

## Roles

- [ ] The shared role `~/.claude/team/roles/pm.md` holds facts about one project. Roles hold
      only how to work, so move those facts to that project's `.team/facts.md`, and decide
      whether `pm.md` and the new `product-manager.md` should merge.
