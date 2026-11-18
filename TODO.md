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

## Permissions

- [ ] `_team_allow` (`skills/team/scripts/team.sh`) approves Edit and Write on any path. Scope them to the
      teammate's worktree or owned files once the worktree path is known before the permission
      block.
- [ ] `git commit --no-verify` is blocked only by a rule in `skills/team/references/teammate-rules.md`. Look at a
      `--disallowedTools` entry for it, since it skips secret-scanning hooks.

## tmux backend

- [ ] `_mux_titles` (`skills/team/scripts/lib/mux.sh`) lists panes from the default tmux server
      only (or `TEAM_TMUX_SOCKET`, which only the tests set). A lead running on another socket
      (`tmux -L`) would read its teammates as gone.

## Roles

- [ ] The shared role `~/.claude/team/roles/pm.md` holds facts about one project. Roles hold
      only how to work, so move those facts to that project's `.team/facts.md`, and decide
      whether `pm.md` and the new `product-manager.md` should merge.
