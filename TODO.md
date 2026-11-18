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

- [ ] Outside a build run, non-haiku teammates still get bare Edit and Write (any path); scope them
      to the teammate's owned files.

## Security

The registry dir is now a private per-user dir (`${TMPDIR:-/tmp}/team-<uid>`, 0700, refused unless
we own it), so the `.tabs` registry and its sidecars are no longer in a shared dir. What is left:

- [ ] No test uses a second user, so "a registry dir owned by someone else is refused" is checked
      only by reading `_reg_dir` (`[ -O ]`), not by running it. Needs a second account or root.
- [ ] Registries and sidecars an older version left in `/tmp/team-*.tabs` are ignored, not
      migrated: `reap` and `status` look only in the new dir. Close such a team with the old copy,
      or move its files into the new dir by hand.

## tmux backend

- [ ] `_mux_titles` (`skills/team/scripts/lib/mux.sh`) lists panes from the default tmux server
      only (or `TEAM_TMUX_SOCKET`, which only the tests set). A lead running on another socket
      (`tmux -L`) would read its teammates as gone.

## Roles

- [ ] The shared role `~/.claude/team/roles/pm.md` holds facts about one project. Roles hold
      only how to work, so move those facts to that project's `.team/facts.md`, and decide
      whether `pm.md` and the new `product-manager.md` should merge.
