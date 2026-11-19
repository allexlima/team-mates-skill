# TODO

Open items. Each one names where the work lives.

## Verify in a real run

- [ ] Run a full team in cmux end to end: spawn, reuse a teammate for a second backlog task,
      monitor %/ETA, finish, close. The cmux tests (`tests/team-build.sh`,
      `tests/team-finish.sh`) use a stub.
- [ ] Run a full team in tmux with real `claude` sessions. The real-tmux test in
      `tests/tmux.sh` (X9) starts a fake `claude` that only sleeps.

## Monitor

- [ ] "stalled?" fires on teammates that are waiting inside a no-mistakes gate (a test step can
      run 30 min), so the red alert becomes noise and hides a teammate that is really stuck.
      Two options: (1) `teammate-rules.md` has the teammate write `gating <sha>` to its status
      file right before `no-mistakes axi run`, and `lib/status.sh` gives that state a longer
      stall threshold; (2) before marking "stalled?", `lib/status.sh` asks
      `no-mistakes axi status` for the teammate's branch and treats a running gate as working.
      (2) needs no teammate cooperation but costs a call per teammate per poll.

- [ ] `tests/status-render.sh` AC2 ("no self-close on transition") timed out when the gate's test
      step ran it inside a no-mistakes worktree, and passed in a normal checkout. Cause not found
      (reported by tm2-tui, not reproduced here). Run the suite from a worktree the gate created.

- [ ] `tests/status-render.sh` AQ1 ("q in the tty monitor exits 0") hung once in four runs during a
      busy full gate run (tm2-hooks): the pty driver saw no exit after 60 rounds of `q`. Not
      reproduced: 10 of 10 passes with 14 CPU-burning processes. The test now prints the last 500
      bytes of pty output and a `ps` snapshot when it hangs; read those on the next occurrence.
      Ruled out: a lone `q` typed outside a `read` window. A single `q` sent at 1, 3 and 6 s, and
      during a render slowed by 3 s of `cmux identify`, still exits 0. 8 of 8 full-suite runs and
      10 of 10 isolated runs passed here, so the cause is probably load or cmux timing on a busy
      machine.

## Shell lint

- [ ] v0.2.0: clean up `shellcheck -S warning`. shellcheck 0.11 reports 12 findings at that level
      (SC1007 from `X= cmd` env assignments aside); CI gates only `-S error` once the shellcheck
      CI change lands. Re-run
      `shellcheck -S warning -f gcc skills/team/scripts/team.sh skills/team/scripts/lib/*.sh tests/*.sh`
      before fixing, since line numbers move: team.sh SC2034 (unused `i`); lib/mux.sh and
      lib/status.sh SC2154 (`sub`/`here` unassigned); lib/status.sh SC2064 (double-quoted `trap`)
      and SC1010 (missing `;` before `done`); tests/roles.sh SC2115 (use `${var:?}`);
      tests/status-render.sh SC2097/SC2098; tests/team-finish.sh and tests/tmux.sh SC2034 (unused
      `CMUX_GONE_REFS`, `o3`).

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

Reported by tm2-hooks (`feat/hook-spawn`, `feat/hook-fence`; not yet in `dev`); the fence list was probed by tm2-hooks against its tip, not re-checked here.

- [ ] `team.sh clean` removes a team's per-teammate `.scratch` dirs and `.sysprompt.md` files from
      the registry dir (21058af). It still leaves the team's `.sync` sidecar and the launcher files.
      Decide whether `close` or `clean` owns removing `.sync`.
- [ ] `TEAM_FENCE_ROOTS` is `:`-separated, so a worktree or run path containing `:` splits into
      wrong roots. It fails closed (writes there are denied). Fix only if someone hits it.
- [ ] The PreToolUse fence (feat/hook-fence @8018736) covers Edit/Write/MultiEdit/NotebookEdit
      paths and the git hook-skip forms, including global options, `sudo`, `env -S`, `$(...)`
      and `time --output`. Still allowed: `eval "git commit ..."`, backticks, `xargs git commit`,
      `HOME=<dir>` or `XDG_CONFIG_HOME=<dir>` pointing git at another global config, aliases in
      the user's own git config (`ci=commit -n`), git run from another interpreter
      (`python3 -c "os.system(...)"`), and every other Bash write (`echo hi > /tmp/file`). A real
      Bash sandbox is still open.

## Roles

- [ ] The shared role `~/.claude/team/roles/pm.md` holds facts about one project. Roles hold
      only how to work, so move those facts to that project's `.team/facts.md`, and decide
      whether `pm.md` and the new `product-manager.md` should merge.
