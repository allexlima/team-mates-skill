# /team startup redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make /team run like a fast startup team: Chrome DevTools MCP for browser work, a tmux fallback, a truthful monitor with overall % and ETA, a reused-teammate backlog, TL/PM roles, broad command allowlists, and a shipped git guide.

**Architecture:** Bash (`team.sh` + `lib/*.sh`) with embedded python3 for parsing and frame rendering, as today. The mux layer becomes a small `lib/mux.sh` that both `team.sh` and `lib/status.sh` call; cmux stays the default backend. Monitor gains one summary record computed from `tasks.md`.

**Tech Stack:** bash 3.2+ (macOS), python3 stdlib, cmux ≥ 0.65.0, tmux ≥ 3.0, Claude Code CLI flags (`--allowedTools`, `--permission-mode`).

**Spec:** `docs/superpowers/specs/2026-11-17-team-startup-redesign-design.md`

## Global Constraints

- One owner per fact (`CLAUDE.md` table). HELP.md owns flags/defaults and the monitor paragraph; SKILL.md owns the lead procedure; the `team.sh` header owns the script interface.
- Every task ends with these gates green, from the main checkout, `TEAM_MEMBER` unset:
  `bash -n team.sh lib/*.sh && bash team.sh doccheck && bash tests/roles.sh && bash tests/team-build.sh && bash tests/team-cli.sh && bash tests/status-render.sh && bash tests/team-finish.sh` (plus `bash tests/tmux.sh` from Task 6 on).
- Commits: Conventional Commits, imperative subject ≤ 50 chars, body says why, one logical change each, ending with `Co-authored-by: Isaac <no-reply@databricks.com>`.
- Percentages are self-reported; never describe them as measured.
- No new runtime dependencies.
- Never commit `.claude-flow/`, `.isaac/`, `.swarm/`, `ruvector.db`, `.team/`.

## Review Focus

1. **Old `tasks.md` (one line per role, no `T<n>` ids)** must still render, still satisfy `finish`, and still give a sensible overall % — test in Task 4 and Task 5.
2. **A teammate's status line without a `T<n>:` prefix** must credit its % to its first open task, not drop it — test in Task 5.
3. **Narrow panes (20–40 cols)** must still show the headline % and ETA in full width — test in Task 5.
4. **Mixed registry: cmux rows and tmux rows in one file** (an old run plus a new one) must not crash `status`/`reap`/`close` — test in Task 6.
5. **No tasks at all / 0 % reported** must not divide by zero or show an ETA — test in Task 5.

---

### Task 1: Commit pending work and ignore tool state

**Files:**
- Modify: `.gitignore`
- Commit as-is: `SKILL.md`, `team.sh` (existing `--branch` diff), `docs/superpowers/`

- [ ] **Step 1:** Append to `.gitignore`: `.claude-flow/`, `.isaac/`, `.swarm/`, `ruvector.db`.
- [ ] **Step 2:** Add a `team-build.sh` case `branch-1`: `spawn --worktree --branch feat/x n1 a <prompt> <model>` (stub cmux) creates `.team/worktrees/n1-a` on branch `feat/x`; `--branch 'bad..name'` exits 2. Run it; expect PASS (the code exists).
- [ ] **Step 3:** Document `--branch <name>` in HELP.md under spawn behaviour (one line: project branch convention; default `team/<team>-<role>`). Run gates.
- [ ] **Step 4:** Commit in two commits: `feat(spawn): add --branch for project branch names` (team.sh, SKILL.md, HELP.md, test) and `docs: add startup redesign spec and plan; ignore tool state` (.gitignore, docs/).

### Task 2: Browser work goes through Chrome DevTools MCP

**Files:**
- Modify: `teammate-rules.md` (replace the "cmux integrated browser" bullet and all sub-bullets)
- Modify: `team.sh` (delete `_close_browsers`, its three call sites at the `reap`, `close`, `finish` paths, and header lines 28–29; extend the `doccheck` phrase list)
- Modify: `tests/team-finish.sh` (delete F20/F20b; add F20c)
- Modify: `HELP.md`, `README.md` (any browser mention)

**Interfaces:** Produces nothing other tasks call.

- [ ] **Step 1: Failing test F20c** in `tests/team-finish.sh`: after `finish`, `$CMUX_LOG` contains no `close-surface` call other than the teammate's own surface, even when `$RUN/browser/w.txt` exists (file left untouched).
- [ ] **Step 2:** Run `bash tests/team-finish.sh`; expect F20c FAIL.
- [ ] **Step 3:** Remove `_close_browsers` and its calls; drop the `browser` column use from `_surface_titles` comment only if nothing else reads col 3 (grep first; `_surface_titles` is also used by close/reap title matching — keep the function).
- [ ] **Step 4:** Rewrite the browser rule in `teammate-rules.md`. Required content: never `cmux browser`, Playwright or another browser; use `mcp__plugin_chrome-devtools-mcp_chrome-devtools__*` against Google Chrome; open one page with `new_page` and `isolatedContext: "<team>-<role>"`, reuse it with `navigate_page`; `wait_for` before inspecting; prefer `take_snapshot`; evidence via `take_screenshot` with `filePath: <run>/evidence/<role>-<step>.png` plus `list_console_messages` / `list_network_requests`; `close_page` every page you opened before reporting; credentials rule unchanged; haiku-tier teammates (no MCP tools on their allowlist) report UI checks as "not done: no browser tools" instead.
- [ ] **Step 5:** Add `'cmux browser'` to the `doccheck` retired-phrase list (`team.sh` ~line 629). doccheck must skip `docs/superpowers/` (it quotes old wording); confirm by reading how doccheck picks files and exclude that dir if needed.
- [ ] **Step 6:** Run gates; expect PASS.
- [ ] **Step 7:** Commit `feat(rules): use Chrome DevTools MCP for browser work` (body: cmux surfaces leaked panes; MCP pages are per-session and isolated).

### Task 3: Broad command allowlist for non-haiku teammates

**Files:**
- Modify: `team.sh` (spawn permission block ~lines 845–880; header permission paragraph)
- Modify: `HELP.md` (quote the list verbatim; state that it is a convention and auto mode may still run unlisted commands)
- Test: `tests/team-build.sh`

**Interfaces:**
- Produces: shell variable `_team_allow` (comma-joined string) defined once near the top of `team.sh`, used by spawn for every non-haiku teammate.

- [ ] **Step 1: Failing test `perm-1`:** a sonnet spawn's claude command line (from `$CLAUDE_LOG`/`$CMUX_LOG`) contains `--allowedTools` with each of: `Read`, `Glob`, `Grep`, `Edit`, `Write`, `Agent`, `SendMessage`, `ListAgents`, `Bash(git status:*)`, `Bash(git diff:*)`, `Bash(git log:*)`, `Bash(git add:*)`, `Bash(git commit:*)`, `Bash(git switch:*)`, `Bash(git stash:*)`, `Bash(bash ~/.claude/skills/team/team.sh facts-lint:*)`, `mcp__plugin_chrome-devtools-mcp_chrome-devtools__*`; and contains none of `git push`, `gh `, `npm install`, `pip install`, `rm -rf`. `perm-2`: a haiku spawn's allowlist is byte-identical to today's (snapshot it from current code before editing).
- [ ] **Step 2:** Run; expect `perm-1` FAIL, `perm-2` PASS.
- [ ] **Step 3:** Define `_team_allow` with the entries above plus read/build/test commands common to this repo's audience: `Bash(ls:*)`, `Bash(cat:*)`, `Bash(head:*)`, `Bash(tail:*)`, `Bash(wc:*)`, `Bash(find:*)`, `Bash(grep:*)`, `Bash(rg:*)`, `Bash(bash -n:*)`, `Bash(pytest:*)`, `Bash(python3 -m pytest:*)`, `Bash(make test:*)`, `Bash(npm test:*)`, `Bash(npm run:*)`, `Bash(ruff:*)`, `Bash(cmux notify:*)`, `Bash(no-mistakes axi:*)`. Pass it as `--allowedTools` for non-haiku spawns and resumes. `TEAM_PERMISSION_MODE` stays on top.
- [ ] **Step 4:** Run gates; expect PASS.
- [ ] **Step 5:** Commit `feat(spawn): pre-approve local commands for teammates`.

### Task 4: Backlog tasks and reuse-aware finish

**Files:**
- Modify: `team.sh` (`finish` tasks.md guard)
- Modify: `lib/status.sh` (`_st_row` milestone detection ~line 182)
- Test: `tests/team-finish.sh`, `tests/status-render.sh`

**Interfaces:**
- Task line format (owned by SKILL.md, quoted in HELP.md): `- [ ] T<n> <team>-<role>|any: <scope> — owns: <files> — needs: <T ids or ->`. Legacy `- [ ] <team>-<role>: …` still valid.
- Produces: python3 helper `_st_tasks_py` (string var in `lib/status.sh`) — reads a tasks.md path on argv, prints one TSV line per task: `id  owner  done(0|1)  needs`. Legacy lines get id `L<lineno>`.

- [ ] **Step 1: Failing tests** in `team-finish.sh`:
  - `F30`: tasks.md has `- [x] T1 f30-w: a` and `- [ ] T2 f30-w: b` → `finish f30 w` exits 2 with `open task T2`.
  - `F31`: both `T1`, `T2` ticked, no legacy line → finish succeeds.
  - `F32`: legacy `- [x] f32-w:` only → finish succeeds (regression).
  - `F33`: a teammate reassigned live writes a second report section with a second `PARALLELISM:` line; finish after the second tick succeeds and the baseline from spawn still applies.
- [ ] **Step 2:** Run; expect F30, F31 FAIL.
- [ ] **Step 3:** Replace the single `grep -qF "- [x] $title:"` guard with: pass if a legacy ticked line exists, or if ≥1 `- [x] T<n> $title:` exists and no `- [ ] T<n> $title:` exists; else refuse naming the first open task id.
- [ ] **Step 4:** In `_st_row`, treat `ms=reported` the same way (all of the teammate's tasks ticked), so a reused teammate between tasks does not read as reported.
- [ ] **Step 5:** Add status-render case `B1`: a record whose tasks.md has one ticked and one open `T` task for it renders STATE WORKING, not reported.
- [ ] **Step 6:** Run gates; PASS. Commit `feat(finish): support multi-task backlog per teammate`.

### Task 5: Monitor redesign

**Files:**
- Modify: `lib/status.sh` (`_st_collect`, `_ST_FRAME_PY`, `_st_sync_apply`)
- Modify: `teammate-rules.md` (status line rule: prefix with the task id, `T3: drafting report · 40%`)
- Modify: `HELP.md` (monitor paragraph — rewrite to describe the new frame)
- Test: `tests/status-render.sh`

**Interfaces:**
- Consumes: `_st_tasks_py` (Task 4).
- Produces: a summary record emitted by `_st_collect` before teammate records: `@summary\t<done>\t<total>\t<credit_permille>\t<run_elapsed_min>\t<pending_unassigned>\t<prs>`; all fields non-empty, numbers as integers.
  - `credit_permille` = Σ over open tasks of the owner's reported pct ×10, where the owner's pct goes to the task named by its status-line `T<n>:` prefix, else its first open task. One teammate credits one task.
  - `run_elapsed_min` = max teammate `elapsed`.
  - `pending_unassigned` = open tasks with owner `any` or whose owner has no live (non-finished) row, whose `needs` are all done.
  - `prs` = count of distinct `https://github.com/.+/pull/\d+` URLs across reports.
- Overall % (frame) = `round((done*1000 + credit_permille) / (total*10))`. With `total=0`: fall back to today's teammate average, prefixed `~`.
- ETA = `run_elapsed × (100 − pct) / pct`, shown as `ETA ~<age>` only when `5 ≤ pct < 100`.

- [ ] **Step 1: Failing tests** (use the `frame` helper; feed `@summary` lines plus `rec` lines):
  - `M1` headline at width 100: `n1 ` + bar + ` 62% · ETA ~14m · 5/8 tasks` present for `@summary 5 8 0 23 0 0` ((5000+0)/80 = 62.5 → 62, floor; ETA = 23×38/62 → 14m).
  - `M2` same summary at width 24: line 1 still contains `62%` and `ETA ~14m`; no line exceeds 24 cols (use `dwidth`).
  - `M3` two FINISHED + one WORKING record: exactly one line matches `✓ 2 finished`, and no row line for the finished roles.
  - `M4` `@summary 0 0 0 0 0 0` with no pcts: no `ETA`, no division error, headline shows `0/0 tasks`.
  - `M5` `pending_unassigned=1` with one IDLE record: NEEDS YOU block contains `idle with work pending`.
  - `M6` `prs=2`: folded line reads `✓ 2 finished · 2 PRs`.
  - `M7` (Review Focus 2) `_st_collect` on a fixture whose status file is `drafting · 40%` (no prefix) and tasks `T1` open, `T2` open for that teammate: summary `credit_permille` = 400, credited to T1.
  - `M8` (Review Focus 1) legacy tasks.md with 3 role lines, 1 ticked: summary `1 3 …`.
- [ ] **Step 2:** Run; expect M1–M8 FAIL.
- [ ] **Step 3:** Implement summary emission in `_st_collect` (python via `_st_tasks_py`; reads status files the records already point at).
- [ ] **Step 4:** Rework `_ST_FRAME_PY` layout, top to bottom: headline (always full; bar shrinks first, then `· N/M tasks`, never `%`/ETA) → NEEDS YOU → live rows `N ROLE · STATE · TASK · STEP · % · AGE` (TASK = the `T<n>` from the status prefix or `-`) → folded `✓ N finished[ · K PRs]` → `backlog: P pending · U unassigned` (omit when P=0). Keep keys, click map, colour/ascii gates and auto-close. Use the `tui-design:tui-design` skill for glyph/colour choices within this order.
- [ ] **Step 5:** `_st_sync_apply`: sidebar pill and progress bar use the new overall %.
- [ ] **Step 6:** Update existing golden cases that the new layout legitimately changes (each change justified in the commit body); run gates; PASS.
- [ ] **Step 7:** Commit `feat(monitor): show overall task % and team ETA`.

### Task 6: tmux backend

**Files:**
- Create: `lib/mux.sh`
- Modify: `team.sh` (spawn pane open/rename, close, finish close, reap, show, list, monitor, lead-title, `_alive`, `_require_cmux` call sites, header, doccheck phrase list)
- Modify: `lib/status.sh` (`_st_state` tmux branch, `sub_monitor`, `sub_sync` no-op under tmux)
- Create: `tests/tmux.sh`; Modify: `CLAUDE.md` gate list (add `bash tests/tmux.sh`)
- Modify: `HELP.md`, `SKILL.md` intro sentence about cmux being required

**Interfaces (all in `lib/mux.sh`, sourced by team.sh before lib/status.sh):**
- `_mux` → prints `cmux` | `tmux` | `none`. Order: `TEAM_MUX` env if set; cmux when `CMUX_WORKSPACE_ID` is set and `cmux ping` = PONG; tmux when `$TMUX` is set; else `none`.
- `_tmux ARGS…` → `tmux ${TEAM_TMUX_SOCKET:+-L "$TEAM_TMUX_SOCKET"} ARGS…` (tests use a private socket).
- `_mux_require [ws]` → replaces `_require_cmux` at every pane-command site; on `none` exits 3 with: cmux recommended (install hint), tmux supported as fallback. Keeps cmux version check.
- `_mux_open <layout:pane|tab|dash> <anchor-ref|-> <cmd> <title>` → prints the new ref. cmux: today's new-split/new-surface logic moved verbatim. tmux: pane → `split-window -d -h|-v -t <anchor> -P -F '#{pane_id}'` (same two-column grid rule), tab → `new-window -d -n <title> -P -F '#{pane_id}'`, then `select-pane -t <id> -T <title>`.
- `_mux_close <backend> <ref>` → 0 ok or already gone; 1 failure. tmux: `kill-pane -t`.
- `_mux_focus <backend> <ref>` → tmux: `select-window -t` then `select-pane -t`.
- `_alive tmux <ref>` → 1 only when `_tmux display -p -t <ref> '#{pane_id}'` fails with "can't find pane"; else 0.
- Registry: tmux rows use col 1 `tmux`, col 2 `%<n>`; format otherwise unchanged.

- [ ] **Step 1: Failing tests** in new `tests/tmux.sh` (stub `tmux` on PATH logging args, like the cmux stub in team-build.sh, `TEAM_MUX=tmux`):
  - `X1` spawn writes a `tmux %N pane n1-a …` row and logs `split-window -d -h`.
  - `X2` second and third spawns follow the grid (`-h` then `-v` anchored two back).
  - `X3` `--tabs` logs `new-window -d -n n1-a`.
  - `X4` `finish` and `close` log `kill-pane -t %N`.
  - `X5` `show` logs `select-window` and `select-pane`.
  - `X6` `status` on a tmux row: alive + fresh status file → `working`; stub says gone → `dead`; status file 11 min old → `stalled?`.
  - `X7` (Review Focus 4) one registry with a cmux row and a tmux row: `status`, `reap`, `close` exit 0 and handle each row with its own backend.
  - `X8` `_mux` returns `none` with no cmux and no `$TMUX`; `spawn` exits 3 and the message names cmux first.
  - `X9` real smoke test when `tmux` exists: `tmux -L team-test-$$ new-session -d`, `TEAM_TMUX_SOCKET=team-test-$$ TMUX=1`, spawn with a fake `claude` on PATH that sleeps, assert the pane exists, `close`, assert gone, `kill-server`. Skip with `SKIP X9` when tmux is absent.
- [ ] **Step 2:** Run; expect FAIL.
- [ ] **Step 3:** Create `lib/mux.sh` with the interface above; move cmux open/close/focus code into it unchanged; route call sites through it.
- [ ] **Step 4:** `_st_state`: tmux rows → `alive` from `_alive`; no waiting/idle signals; stalled from status-file age (existing 10 min rule). `sub_monitor` opens with `_mux_open dash`. `sub_sync` returns 0 silently under tmux. `lead-title` under tmux: `rename-window`.
- [ ] **Step 5:** `--tmux` flag: make it set `TEAM_MUX=tmux` (force backend) instead of refusing. Remove `--tmux`, `tmux pane`, `tmux session`, `tmux attach` from doccheck's retired list; keep `'2–5'`, `'stacked'`, etc.
- [ ] **Step 6:** HELP.md: backend paragraph (cmux default and recommended; tmux fallback; what tmux lacks: waiting/idle states, sidebar pill, click-to-focus) and the `--tmux` flag. SKILL.md: replace "cmux is required for pane modes" with the detection rule in one sentence.
- [ ] **Step 7:** Add `bash tests/tmux.sh` to the CLAUDE.md gate list. Run all gates; PASS.
- [ ] **Step 8:** Commit `feat(mux): add tmux fallback backend`.

### Task 7: TL/PM, reuse loop, speed focus in the lead procedure

**Files:**
- Modify: `SKILL.md` (intro mission paragraph; step 1 brainstorm via AskUserQuestion; step 2 TL/PM proposal and task-line format; step 3 report routing and risky-command rule; new reuse loop in step 3; merge question; Rules: writing skills)
- Modify: `teammate-rules.md` (TL routing, risky commands, writing skills, status prefix already done in Task 5)
- Create (shared library, not committed): `~/.claude/team/roles/tech-lead.md`, `~/.claude/team/roles/product-manager.md`
- Modify: `HELP.md` (outcome-level summary only), `team.sh doccheck` if a new retired phrase is introduced

Content requirements (the implementer writes the prose; run `humanizer:humanizer` on every changed paragraph):
- [ ] **Step 1: Mission paragraph** at the top of SKILL.md: deep-dive the scope, staff the right roles, finish accurately and fast like a startup tech team; the three speed levers (no idle teammate while work is pending, every teammate fans out to subagents, few permission stops).
- [ ] **Step 2: Step 1 brainstorm:** every brainstorm question goes through AskUserQuestion (recommended first), never prose.
- [ ] **Step 3: Step 2 roster:** propose a `tech-lead` (opus) for anything beyond a very basic task, and a `product-manager` (sonnet) when scope or acceptance is fuzzy; the roster says why or why not. Write `tasks.md` as a backlog in the Task 4 format, usually more tasks than teammates, with `needs:` dependencies.
- [ ] **Step 4: Merge question** (build runs with gate): AskUserQuestion with first option "TL merges with gh after review and green checks (Recommended)", second "I merge"; one answer covers the run; the lead reports each merge.
- [ ] **Step 5: Reuse loop** (new subsection in step 3): on a report, if a fitting pending task exists, SendMessage it to the same live teammate (with the task id) instead of `finish`; TL is the single authority for assignment and "no fitting work left" once it exists; the lead runs `finish` when told; target: reassign within a minute of the report; `idle with work pending` in the monitor is a lead action item.
- [ ] **Step 6: Risky commands:** pushes, `gh` writes, installs, deploys, destructive commands are TL-only (lead-only without a TL); teammates SendMessage the TL the exact command and why. State it is a convention.
- [ ] **Step 7: Writing rules** (SKILL.md Rules + teammate-rules.md): user-facing prose through `humanizer:humanizer`; READMEs through `beautify-github-readme`; diagrams through `diagram-design`.
- [ ] **Step 8: Role specs** `tech-lead.md` and `product-manager.md` under the five headings (Lens · Typical scope · Constraints · Preferred tier · Lessons), no project facts. TL: owns backlog, assignment, reviews, risky commands, PR stacking/merging per the run's merge answer, reports to the lead. PM: owns acceptance criteria and checks results against them; no product code.
- [ ] **Step 9:** `bash team.sh doccheck` and gates; PASS. Commit `feat(skill): add TL/PM roles and teammate reuse loop`.

### Task 8: Git and GitHub guide

**Files:**
- Create: `git-practices.md` (repo root, next to `teammate-rules.md`)
- Modify: `SKILL.md` step 3 build-run prompt bullet (5-line summary + absolute path to the file)
- Modify: `README.md` file list if it has one

- [ ] **Step 1:** `git-practices.md` = the user's git-best-practices guide (verbatim body, frontmatter dropped) plus a "Using gh" section: `gh pr create --base <parent> --title <conventional subject> --body` with context / what / why / how to test and the org attribution line; stacked PRs target the previous branch; `gh pr checks <n> --watch` before asking to merge; `gh pr merge` only by the TL and only under the run's merge answer; never `--admin`.
- [ ] **Step 2:** Build-run prompt summary (5 lines): Conventional Commits with imperative ≤50-char subjects; one logical change per commit; PRs under ~200 changed lines, stack when larger; no PR with failing checks; full guide at `<abs>/git-practices.md`.
- [ ] **Step 3:** Gates; commit `docs: ship git and gh guide for build runs`.

### Task 9: README redesign

**Files:**
- Modify: `README.md`; Create: `assets/` (hero, diagram) only if the skill output needs files

- [ ] **Step 1:** Invoke `beautify-github-readme` (whole-README scope); confirm the hero implementation choice with the user as that skill requires.
- [ ] **Step 2:** One how-it-works diagram via `diagram-design` (lead → TL/PM → teammates → backlog → monitor → PRs).
- [ ] **Step 3:** Link to `/team --help` instead of any flag table (CLAUDE.md rule). Run `humanizer:humanizer` on all prose.
- [ ] **Step 4:** `bash team.sh doccheck`; commit `docs(readme): redesign README`.

---

## Execution order and parallelism

Tasks 1 → 2 → 3 → 4 → 5 → 6 touch `team.sh`/`lib/status.sh` and run sequentially. Task 8 can run in parallel with Tasks 2–6 (docs only). Task 7 after Task 5 (it references the status prefix and backlog format). Task 9 last (it describes the finished product).
