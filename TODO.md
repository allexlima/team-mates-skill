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

## Security

- [ ] The registry dir defaults to world-writable `/tmp` and several state files sit there at
      predictable names: the `.tabs` registry (appended to), the `.round` sidecar
      (`skills/team/scripts/team.sh` ~954-957, plain `>`), `$reg.tmp` (~730, 948, 1049) and the sync
      state file (`skills/team/scripts/lib/status.sh` ~1177). Another local user can pre-create or
      symlink any of them: a write is redirected or truncates a file of ours, and a registry they
      edit is trusted. Worst case, `--resume` reads the session id from col 10 of `.tabs`
      (`team.sh` ~936) and puts it unquoted into the launcher (~1019), so a crafted id runs a
      command (tm1-reviewer reproduced it with `x;touch ...;:`). The launcher and the system
      prompt were fixed in this run (mktemp). Proposed fix: default `_reg_dir` to a per-user
      `0700` dir (`${TMPDIR:-/tmp}/team-$(id -u)`, created with `mkdir -p -m 700`, refused unless
      `[ -O "$d" ] && [ ! -L "$d" ]`), and also `printf %q` the session id at ~1019 and validate it
      as a uuid at ~936. Docs that name the default: `skills/team/SKILL.md`, the `team.sh` header
      and `lib/status.sh`. This changes where the registry lives, so tests that set
      `TEAM_REG_DIR` are unaffected.

## tmux backend

- [ ] `_mux_titles` (`skills/team/scripts/lib/mux.sh`) lists panes from the default tmux server
      only (or `TEAM_TMUX_SOCKET`, which only the tests set). A lead running on another socket
      (`tmux -L`) would read its teammates as gone.

## Roles

- [ ] The shared role `~/.claude/team/roles/pm.md` holds facts about one project. Roles hold
      only how to work, so move those facts to that project's `.team/facts.md`, and decide
      whether `pm.md` and the new `product-manager.md` should merge.
