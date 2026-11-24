# TODO

Open items. Each one names where the work lives.

## Verify in a real run

- [ ] Run a full team in cmux end to end: spawn, reuse a teammate for a second backlog task,
      monitor %/ETA, finish, close. The cmux tests (`tests/team-build.sh`,
      `tests/team-finish.sh`) use a stub.
- [ ] Run a full team in tmux with real `claude` sessions. The real-tmux test in
      `tests/tmux.sh` (X9) starts a fake `claude` that only sleeps.

## Monitor

- [ ] `tests/status-render.sh` AC2 ("no self-close on transition") timed out once when the gate's
      test step ran it inside a no-mistakes worktree. Still not reproduced (run w12, 2026-11-24):
      7 of 7 full-suite passes, including one under a live gate's load (69 s), one with no cmux env,
      no `TERM` and stdin from `/dev/null`, one under `env -i` with `PATH=/usr/bin:/bin` (stock
      bash 3.2, perl fallback for `tmo`), and 4 suites in parallel at load average 12. The gate's
      test step has no test command configured ("no test command configured, asking agent to run
      tests..." in `no-mistakes axi logs --step test`), so an agent picks the commands and runs
      them inside its own tool-call time limit; the reported "timeout" may be that limit, not the
      test's own `tmo`. Next step: when it recurs, read that step's log for the exact command and
      its exit code (124 from `tmo` vs a tool timeout).

- [ ] `tests/status-render.sh` AQ1 ("q in the tty monitor exits 0") hung once in four runs during a
      busy full gate run (tm2-hooks): the pty driver saw no exit after 60 rounds of `q`. Not
      reproduced: 10 of 10 passes with 14 CPU-burning processes. The test now prints the last 500
      bytes of pty output and a `ps` snapshot when it hangs; read those on the next occurrence.
      Ruled out: a lone `q` typed outside a `read` window. A single `q` sent at 1, 3 and 6 s, and
      during a render slowed by 3 s of `cmux identify`, still exits 0. 8 of 8 full-suite runs and
      10 of 10 isolated runs passed here, so the cause is probably load or cmux timing on a busy
      machine.

## TUI monitor

Reported by tm2-tui (branch `feat/tui-monitor`); not re-measured here.

- [ ] Mouse clicks in the TUI monitor under cmux are unverified. cmux `send-key`/`send` cannot
      synthesize clicks, so a person has to click a card in a real cmux pane: a click should focus,
      a double-click should open details, and cmux should not take the click first.
- [ ] Check the transcript path and fields the TUI reads against a current Claude Code release
      (`~/.claude/projects/*/<session-id>.jsonl`, `message.usage`, `tool_use`/`tool_result`):
      they are not a documented interface.

## Permissions

- [ ] Outside a build run, non-haiku teammates still get bare Edit and Write (any path). Scope
      them to the teammate's owned files.
- [ ] The hook-skip denies (`--disallowedTools`) miss git global-option forms (`-C`, `-c`),
      wrappers (`sh -c`, `/usr/bin/git`) and combined flags such as `-an`. They need a PreToolUse
      fence; see "Hook fence and cleanup".

## Security

The registry dir is a private per-user dir and `TEAM_REG_DIR` gets the same checks (HELP.md,
Cleanup). What is left:

- [ ] No test uses a second user, so "a registry dir owned by someone else is refused" is checked
      only by reading `_reg_dir` (`[ -O ]`), not by running it. Needs a second account or root.

## tmux backend

- [ ] `_mux_titles` (`skills/team/scripts/lib/mux.sh`) follows `$TMUX`, so `tmux -L` and `-S` work
      when the lead runs inside tmux. It still reads teammates as gone when `$TMUX` is unset
      (a lead that runs outside tmux but opened teammates on a non-default server).

## Hook fence and cleanup

Reported by tm2-hooks (`feat/hook-spawn`, `feat/hook-fence`); the fence list was probed by tm2-hooks against its tip, not re-checked here.

- [ ] After `close`, `clean <team>` tells its worktrees from a prefixed team's (`foo`, `foo-bar`)
      only through the other team's registry, so a sibling team that was also closed can lose its
      committed worktrees (branches stay). Record team ownership somewhere that survives `close`.
- [ ] `TEAM_FENCE_ROOTS` is `:`-separated, so a worktree or run path containing `:` splits into
      wrong roots. It fails closed (writes there are denied). Fix only if someone hits it.
- [ ] The PreToolUse fence (feat/hook-fence @8018736) covers Edit/Write/MultiEdit/NotebookEdit
      paths and the git hook-skip forms, including global options, `sudo`, `doas`, `env -S "..."`
      and git inside `$(...)`. Still allowed: `eval "git commit ..."`, backticks,
      `$(echo git) commit -n` (a `$(...)` command word), `xargs git commit`,
      `env -S"..."` or `env --split-string=...`, `time --output f` or `--format f`,
      `HOME=<dir>` or `XDG_CONFIG_HOME=<dir>` pointing git at another global config, aliases in
      the user's own git config (`ci=commit -n`), git run from another interpreter
      (`python3 -c "os.system(...)"`), and every other Bash write (`echo hi > /tmp/file`). A real
      Bash sandbox is still open.
- [ ] The fence fails safe, so it also denies some harmless commands: a key-only read such as
      `git config core.hooksPath`, `git commit -m --no-verify` (the flag is only message text),
      and a heredoc whose text mentions `git commit -n`. Accepted for now.
- [ ] `TEAM_FENCE_ROOTS` holds the whole run dir, so a teammate can edit other teammates'
      reports, prompts and status files. Narrow it to the teammate's own status and report
      files plus `tasks.md`.
