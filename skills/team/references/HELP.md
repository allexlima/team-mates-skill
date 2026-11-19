# Team-mates — /team agent teams

Runs a small team of Claude sessions on one task. Each role is a separate
interactive `claude` session in its own pane; this session is the **lead**:
it plans the roles, relays findings between teammates for challenge rounds,
and writes the final synthesis.

**Contents:** Usage · Options · Before spawning · Choosing roles · Choosing models · Run types · Team shape · Every teammate · Later rounds: resumed teammates · Project memory: .team/ · Where teammates appear · Progress (cmux sidebar) · Cleanup: team.sh reap [--yes] [--exclude <team>] · Examples · While it runs · Output · Notes

## Usage
    /team <task> [options]

## Options
    --roles N        Number of teammates, 2–8 (default ~3)
    --rounds N       Challenge rounds after the first reports (default 1)
    --autoroles      Scan the project (README, layout, tests, git diff, stack) and propose
                     roles from it; waits for your OK before spawning
    --model M        Force one model for every teammate (alias or full id); a haiku-tier id
                     puts every role in dontAsk and is refused on build runs.
                     Default: the lead picks a model per role (see Choosing models)
    --tabs           One cmux tab (tmux: window) per teammate instead of panes
    --tmux           Open teammate panes with tmux even inside cmux (tmux is used
                     automatically when you are not in cmux)
    --no-gate        Build runs: skip no-mistakes (commits stay local, no push/PR)
    --no-caveman     Teammates write normal prose instead of caveman terse style
    --autoclose      Close the team right after the final synthesis
    --inline         No panes: teammates run as in-session subagents (no cmux or tmux needed)
    --no-monitor     Skip the auto-refreshing status pane that opens by default after the
                     teammates spawn. The pane shows each teammate's state, current step and
                     flags, with anything that needs you pinned at the top. Not counted toward
                     the teammate cap; closed with the team. Never opened under --inline
                     (no registry to read).
    --help           Show this help

## Before spawning
Every run starts with the lead closing any leftover teammates from earlier runs (it
lists them for your approval first), then brainstorming the task with you: it re-reads the
earlier conversation, `.team/facts.md` and the last run's synthesis, asks whatever
questions change the work, then writes back the task, the roles, what is out of scope and
how the result gets verified. Teammates spawn only after you approve that — a wrong
assumption otherwise gets paid once per teammate.

## Choosing roles
- List them in the task (`Roles: security: …, perf: …, skeptic: …`) — used as-is.
  A bare name loads a saved role: project `.team/roles/` first, then the shared
  library `~/.claude/team/roles/`.
- Or `--autoroles` — derived from the project (reusing saved roles first),
  shown with reasons, you confirm. Approved new roles are saved for reuse.
- Otherwise the lead picks roles from the task text alone.
- Best practice: one distinct lens per role, one adversarial role, separate
  files per role when editing, 2–3 roles.

## Choosing models
The lead lists what this machine actually offers (`team.sh models` — the set is
org-managed, so it is read at run time, not hardcoded) and gives each role the
cheapest tier that still fits it: the top tier for the adversarial role and for
architecture / security / subtle debugging, the middle tier for ordinary work,
and the cheap tier only for mechanical sweeps. `team.sh pick-model <tier>` returns
the best model id for that tier on this machine (newest version within the `claude-*`
family; GLM / Kimi only by explicit full id). The set comes from `managed-settings.json` (macOS `/Library/Application Support/ClaudeCode/`, Linux/WSL `/etc/claude-code/`), then `~/.claude/settings.json`; `TEAM_MODELS_FILE` replaces both. Windows is not supported and `managed-settings.d/` drop-ins are not read. If no model of the requested tier is
available it falls back through the chain (opus → sonnet → haiku) and exits 1, so the
lead can see a lower tier was used; exit 3 means no model is available at any tier. Cheap-tier (haiku) teammates — and any model id that resolves to haiku tier (e.g. GLM /
Kimi) — always run unattended in `dontAsk` mode with a per-teammate allowlist:
Read/Glob/Grep, SendMessage, ListAgents, Bash restricted to `git status`/`ls`/`wc`/
`team.sh facts-lint`/`cmux notify --title ...`, and Edit on their own report, tasks.md,
and status file.
`TEAM_PERMISSION_MODE` never applies to haiku tier.
Denied tools show up in their report. Haiku tier is refused on build runs. Subagents
launched by teammates default to Sonnet when available, unless the teammate specifies
otherwise. The roster you approve shows each role's model, so you can change any of
them before spawning, and the run record notes what each role ran on. An unrecognised
model is refused up front rather than opening a pane on a dead session. `--model`
forces one model everywhere; a haiku-tier id puts every role in dontAsk and is refused on build runs.

## Run types
    Review run   Read-only task, or not a git repo. Teammates share the working tree;
                 editing roles get exclusive files.
    Build run    Task edits code in a git repo. Each teammate works like a separate
                 person: own worktree (.team/worktrees/<team>-<role>), own branch
                 (team/<team>-<role>, or the project's own convention when its
                 CLAUDE.md defines one, e.g. feat/<topic>), own commits, and its own no-mistakes gate —
                 review → test → docs → lint → push → PR. The lead asks your OK first
                 because this publishes branches/PRs. Judgment calls are forwarded
                 to the lead via NEEDS INPUT; you answer them in the lead pane.
                 Summary lists every PR and flags overlapping files.
    Needs: no-mistakes (https://github.com/kunchenguid/no-mistakes) and an `origin`
    remote; without them the gate is skipped and commits stay local.

## Team shape
For anything beyond a very basic task the lead proposes a tech-lead (opus), who owns the
backlog, assigns tasks, reviews and merges; and a product-manager (sonnet) when scope or
acceptance is fuzzy. You approve or drop them with the roster. `tasks.md` is a backlog with
more tasks than teammates, and a teammate that reports gets the next fitting task in the same
session instead of closing. On build runs the lead asks once per run who merges the PRs (the
TL with `gh`, or you).

## Every teammate
- Opens in a two-column grid right of the lead, so panes stay readable as the team grows.
- Its pane closes when it has reported, the lead has verified the report and no fitting
  task is left for it in the backlog, so the grid
  shows only who is working and the finished session frees its memory. Nothing is lost: the
  report is on disk, and the lead resumes the session (or starts a fresh one that reads the
  report) if a later round needs that teammate. Finishing is refused unless the report is
  complete and, on a build run, the worktree has no uncommitted changes.
- Pane/tab title is fixed to <team>-<role> (Claude's auto-titling is disabled).
- Starts in auto permission mode (TEAM_PERMISSION_MODE overrides for non-haiku tiers; haiku tier always → dontAsk + per-teammate allowlist, regardless of TEAM_PERMISSION_MODE).
- Splits its own work across subagents: anything independent (separate files, checks or
  drafts) is dispatched in one message so it runs concurrently, and its report says what
  it parallelised. It still verifies what the subagents hand back before reporting it.
- Writes in caveman style (https://github.com/JuliusBrussee/caveman) to save tokens;
  code, paths and errors unchanged. The lead's summary to you stays normal prose.

## Later rounds: resumed teammates
A teammate is finished as soon as its report is verified, and every later round resumes it
(one resume spin-up per teammate per round, so a teammate exists only while it works). Its
session id is recorded, so a later round resumes that session
(`team.sh spawn --resume`; it keeps its full context) and falls back to a fresh teammate that
reads its earlier report when no session is recorded or its directory is gone. Shutting the
team down (`close`) drops finished rows, so nothing can be resumed afterwards.
Known behaviour to expect:
- **Edits to `teammate-rules.md` do not reach a resumed teammate.** Claude records the system
  prompt on the first request and replays it on resume; a changed prompt file is ignored with
  no error or warning. Anything a resumed teammate must be told differently goes in the lead's
  message to it. A fresh teammate does read the current rules.
- The permission mode is re-applied on resume (verified for `--permission-mode`; that the
  haiku-tier `--allowedTools` allowlist also re-applies is inferred, not observed).
- Resuming a build-run teammate after `team.sh clean` removed its worktree is refused (its
  directory is gone), so the lead starts a fresh teammate from its report.

## Project memory: .team/
Created at the project root on first run (git-ignored, along with CLAUDE.local.md;
a one-time pointer note is added to CLAUDE.local.md — never to CLAUDE.md):
    .team/facts.md             Consensus findings with evidence + date + run id;
                               every teammate reads it first and flags stale entries
    .team/roles/<role>.md      Roles saved in this project (override shared roles)
    .team/runs/<date>-<team>/  tasks.md · prompts/ · reports/ · status/ · events/ · synthesis.md
    .team/worktrees/           build-run worktrees (removed on shutdown if clean)
Only conclusions and pointers are stored — never secrets, PII, or raw data.

Shared role library: `~/.claude/team/roles/` (outside any repo; make it a private git
repo to sync machines). `team.sh role-pull <name>` brings a shared role into this
project; `team.sh role-promote <name>` publishes a project role to the shared library
(shows a diff and scans for secrets/PII before copying). `team.sh roles` lists all
available roles with a status column:
    in-sync          Project and library copies are identical
    local-ahead      Project copy has changes not in the library (promote candidate)
    global-ahead     Library is newer — run role-pull before promoting
    diverged         Both differ from the saved base — show both diffs before deciding
    diverged (no base)  Both differ but no saved base for comparison
    project-only     Role exists in the project but not in the library (promote to add it)
    library-only     Role exists in the library but not in this project (pull to add it)
On a new machine the shared library starts empty until you sync it.

## Where teammates appear
    In cmux (default)   Your tab splits: you on the left, teammates in a two-column
                        grid on the right; finished ones close.
                        cmux is the default and recommended. Install: https://cmux.dev
    cmux + --tabs       A new tab per teammate in the current workspace
    In tmux (fallback)  Used when you run /team inside tmux but not cmux (or with --tmux).
                        Same two-column grid; --tabs gives one tmux window each. tmux has
                        no notification feed, so waiting (AskUserQuestion) is not shown
                        there; permission, idle and stalled? come from the event log
                        (see the states below), there is no
                        sidebar pill, and clicking a row needs tmux's `mouse on` (the number keys always work).
    --inline            No panes: teammates run as subagents inside your session.
                        Works without cmux.

## Progress (cmux sidebar)
The lead workspace shows a live status pill and progress bar: phase (spawning /
working / done) and "N/M reported". Events are logged to the cmux event stream
(`cmux log --source team`) so you can scroll back. A badge and ring light up when
any teammate reports or sends a question — the notification fires from `cmux notify`
inside that teammate. A report's notification is best-effort quiet (no macOS banner) and
NEEDS INPUT keeps the banner; cmux says its notification hooks "can still override" that,
so treat it as a preference. A report's ring is not a durable signal either, because the
reporting teammate's pane closes once it is finished — rely on the pill's `N/M reported`.
The monitor updates the sidebar every tick; with `--no-monitor` the lead calls `team.sh sync <team>` instead; `team.sh sync --clear <team>`
removes it when the team closes. The status pane (see below) opens by default and is the
detailed view; the sidebar is the glance view.

## Cleanup: team.sh reap [--yes] [--exclude <team>]
At the start of every run the lead lists leftover teammates from earlier runs of
this project and asks you to confirm before closing them. Rows marked "(run started
today: may be live in another lead session)" require extra care — you may want to
check before closing. Registries without a project root are left alone and counted
in a summary line. You can also run `team.sh reap` at any time to see the list, or
`team.sh reap --yes` to close without prompting. `--exclude <team>` skips the named
team. Needs cmux or tmux; skipped under --inline.

The registry and its sidecar files live in a private per-user dir, `${TMPDIR:-/tmp}/team-<uid>`
(0700, owned by you, never a symlink), so where it is depends on `TMPDIR`: a lead started with a
different `TMPDIR` does not see the other lead's teams. A relative `TMPDIR` is ignored (`/tmp`
is used). `TEAM_REG_DIR` overrides the dir and gets the same checks; a relative value is made
absolute. Registries an older version left in `/tmp/team-*.tabs` are not migrated or read:
close such a team with the old copy of the skill, or move its files into the new dir by hand.
A bad dir (not a real directory you own with mode 700, or a symlink) exits 3 with
"refusing registry dir"; a missing `TEAM_REG_DIR` is created 0700 if its parent exists (a nested missing path is refused).

## Examples
    /team review PR #42 for security, performance and test coverage
    /team why does the streaming job lag? --roles 4 --rounds 2 --model sonnet
    /team research vector search options for our RAG demo --tabs --autoclose
    /team review my current changes --autoroles
    /team add retry logic to the ingestion job and cover it with tests --autoroles
    /team quick sanity review of src/utils.py --roles 2 --inline

## While it runs
- Click into any teammate pane to talk to it directly or redirect it, or ask the lead to
  `show` it (brings its pane to the front and moves focus there). A finished teammate has
  no pane; ask the lead to resume it.
- Teammate *tool-permission* prompts appear in *their* pane — approve them there.
  The status pane shows such a teammate as `permission` (from its event log). Without an
  event log (the plugin did not load) a prompt produces no notification, so the teammate
  shows `working` for about 10 minutes, then `stalled?`; if a teammate has been quiet that
  long, ask the lead to `show` it (brings its pane to the front) before assuming a bug.
  (Haiku-tier teammates run in dontAsk mode and don't prompt; denied tools appear in
  their report.)
- A teammate that needs your input or a decision forwards the question to the lead via
  NEEDS INPUT with options and a recommendation; you answer it in the lead pane (with the
  recommended option presented first) and the lead relays it back — so you don't have
  to visit each pane. The lead always uses AskUserQuestion for your input.
- Build-run worktrees are pre-trusted, so they no longer prompt. A folder you have
  never opened with Claude can still show a trust prompt the first time.
- `.team/runs/<date>-<team>/tasks.md` tracks each role's status.
- Run `team.sh status <team>` to see one frame: a summary line (`<team> · 5/8 tasks ·
  time`, or `N/M reported` when tasks.md has no task lines), a progress line with the
  overall % and team ETA, and a table of the live teammates: ROLE · STATE · STEP · AGE.
  Finished teammates fold into one `✓ N finished · K PRs` line below the table, followed
  by `backlog: P pending · U unassigned` while tasks remain. Each state is a symbol
  plus a word, so colour is never the only cue; colour is off when output is not a terminal,
  `NO_COLOR` is set or `TERM=dumb`, and symbols fall back to ASCII in a non-UTF-8 locale.
  A `NEEDS YOU` block is pinned above the table only when a teammate is in one of the first
  five states below; the STEP column is dropped below 60 columns.
    permission   Waiting on a tool-permission prompt (its event log's last event is a
                 permission request): approve or deny it in its pane.
    waiting      AskUserQuestion notification detected — teammates must not use this;
                 `show` its pane and SendMessage it to send NEEDS INPUT to the lead instead.
                 Not detected for haiku/dontAsk tier.
    model gone   Its model is no longer available — respawn with a different model
    dead         Session exited — respawn it (a note says when its report is safe on disk)
    stalled?     No status update for 10 minutes while mid-work. With an event log: no
                 event for 10 minutes and no tool still running, so a long tool or hook is
                 not flagged. This is "no update in a while", not "stuck": a subagent wait
                 looks the same, so look at its pane before messaging it
    working      Doing its work (a note says "report on disk" once it has reported)
    idle         Turn ended with no report yet (a Stop or idle prompt in the event log, or
                 cmux's "Completed" notification); routine while it waits on a peer or the lead,
                 so it is not pinned under NEEDS YOU (it becomes stalled? after 10 minutes).
                 Exception: it is pinned as "idle with work pending" while an unassigned
                 ready task exists (owner `any` or not live), or while the idle teammate holds
                 a ready task, on its own line or claimed by starting its status line with
                 "T<n>:". Hand it that task. A claimed task counts as assigned, not unassigned.
    unknown      Not opened in cmux, or cmux could not be queried, so its state cannot be read
    finished     Reported, verified and closed by the lead
  Live teammates' state comes from the team plugin's event log and the cmux hooks the claude
  shim injects — no screen scraping. The log is `.team/runs/<run>/events/<role>.jsonl`;
  `status --json` carries the measured state per teammate as
  `event_state`, `event_age_s` (seconds since its last event) and `open_tool` (a tool
  still running), all null without a log. A finished teammate has no surface, so its state comes from the report on disk
  and its registry row.
  The status pane opens automatically (unless `--no-monitor`) and repaints only when the
  frame changes, checking every 30 s (override with `TEAM_STATUS_INTERVAL`). It exits when
  the team is closed. Needs cmux or tmux. Under `--inline` there is no registry and no pane; track
  teammates by their returned reports and tasks.md.
  In the pane each row is numbered: press that number to focus that teammate's pane, `r` to
  repaint, `q` to quit. Clicking a row does the same. Clicking captures the mouse, so
  click-drag no longer selects text in that pane (shift+drag still does); set
  `TEAM_MONITOR_MOUSE=0` to keep the number keys and leave selection alone. Only live
  teammates get a number. One-shot `team.sh status` prints no numbers and takes no input.
  The pane closes itself a few seconds after the last teammate reaches `finished`, so a
  completed run does not leave a pane behind (`TEAM_MONITOR_AUTOCLOSE=0` keeps it open,
  `TEAM_MONITOR_CLOSE_GRACE` sets the delay). It only closes on that *transition*: opening
  the monitor on an already-finished run leaves it up.
  Only task lines owned by `<team>-*` or `any` count, so another team's lines in a shared
  tasks.md are ignored (a sibling team whose slug extends this one is not counted either).
  The headline % is **overall task progress**: done tasks in tasks.md, plus each open task's
  share as its owner reports it on its status line (`T3: drafting · 40%` credits T3; with no
  `T<n>:` prefix it credits the teammate's first open task). A `~` in front means
  self-reported percentages went into it. The team ETA next to it is a linear extrapolation
  (`run elapsed x (100 - pct) / pct`), shown from 5% on. The % and ETA never truncate; the
  bar shrinks first. When tasks.md has no task lines the bar falls back to the teammates'
  **average** self-reported progress (a reported or finished teammate counts as 100), and to
  `N/M` with no `~` when nobody reports a percentage. The sidebar pill and progress bar carry
  the same number as the pane.
  A PROGRESS bar and an `~ETA` appear per row when a teammate reports a percentage on its
  status line and the pane is wide enough to keep ROLE and STATE readable; STEP then drops
  the repeated `· NN%`. All of these are **self-reported** — the teammate's own estimate,
  since no measured per-teammate progress signal exists — so treat them as a rough
  indication, not a measurement.
- **The TUI monitor.** When the status pane is a terminal and Textual is importable by
  `python3` (or `uv` is installed, which fetches it on first use), the pane runs the
  full-screen monitor in `scripts/monitor_tui.py` instead of the frame above. It shows the
  same states, NEEDS YOU rows, overall % and team ETA (it reads `team.sh status --json` and
  shows those numbers as they are, so both monitors always agree), plus: one card per live
  teammate (state, task, step, a progress bar, its own ETA, a sparkline of its % over time,
  the tool call in flight and how long it has run, context use and output tokens), the backlog
  with an estimated finish per open task, an event log, and a detail view per teammate
  (report, recent tool calls, progress history, session info). Keys: `1`-`9` focus that teammate's pane, arrows/tab move between cards,
  `enter` or a click opens the detail view, `s` shows the selected pane, `r` refreshes,
  `t` changes the theme, `?` lists keys and states, `q` quits (the team keeps running).
  The per-task estimates are forecasts, not measurements: the backlog schedules every open
  task over the live teammates, after its `needs:`, with each running task's remaining time
  projected from its self-reported % and every other task given the typical task duration
  seen so far. They can differ from the team ETA above, which stays status.sh's. Tokens,
  context and the tool in flight are read (never written) from each teammate's Claude Code
  transcript, `~/.claude/projects/*/<session-id>.jsonl`; a tool call running for many
  minutes on a `stalled?` teammate is called out as a likely permission prompt. The
  monitor keeps what it observed in `<run>/monitor/history.jsonl`, so a reopened monitor
  keeps its sparklines and task timings. It refreshes every 5 s (`TEAM_TUI_INTERVAL`),
  closes itself like the classic pane (`TEAM_MONITOR_AUTOCLOSE`, `TEAM_MONITOR_CLOSE_GRACE`),
  and falls back to the classic pane if it cannot start. `TEAM_MONITOR_UI=classic` keeps
  the classic pane; `TEAM_MONITOR_THEME` picks a Textual theme (default `tokyo-night`);
  `TEAM_CONTEXT_WINDOW` sets the context size the % is measured against (default 200k, or
  1M for a `[1m]` model). Try it with no team: `python3 scripts/monitor_tui.py --demo` (or
  `uv run --script scripts/monitor_tui.py --demo` when only uv is installed).
- Say "shut down the team" to close all teammate panes/tabs (the run record stays;
  clean worktrees are removed, branches and PRs stay).

## Output
Consensus (findings that survived challenge, with evidence) · Disputed (each
side's best evidence) · Dropped (refuted) · Next steps.

## Optional dependencies
Everything below is used when installed and skipped when not. A run never fails for a missing
one; it loses only what the table says. `caveman` and `no-mistakes` are used every time they are
available and fit the run; `--no-caveman` and `--no-gate` are the opt-outs.

| Dependency | Used for | Without it |
|---|---|---|
| `superpowers:brainstorming` skill | The lead's step-1 brainstorm | The lead asks the same questions (outcome, audience, success) with AskUserQuestion directly |
| `humanizer:humanizer` skill | Smoothing user-facing prose (synthesis, PR text, docs) | Prose ships as drafted; read it for stock AI phrasing yourself |
| `beautify-github-readme` skill | README redesign | The README is written plainly, with no generated hero or section art |
| `diagram-design` skill | Diagrams | Use a Mermaid or ASCII diagram |
| `caveman` skill (found in `<project>/.claude/skills`, `~/.claude/skills`, `~/.agents/skills`, then any installed plugin's `skills/caveman` or `skills/caveman-mode`) | Terse teammate output, saves tokens | Teammates write normal prose, as with `--no-caveman` |
| Chrome DevTools MCP + Google Chrome stable | UI QA by teammates | The report says "UI checks not done: no browser tools"; UI claims stay unverified |
| `no-mistakes` CLI | The build-run gate that pushes and opens each PR; a `--worktree` spawn warns when it is installed but the repo has no gate (run `team.sh gate-init`) | No gate, as with `--no-gate`: commits stay local; the lead or TL pushes and opens the PRs by hand |

## Notes
- Non-haiku teammates start in auto permission mode (set TEAM_PERMISSION_MODE to override)
  with this pre-approved allowlist, so routine local work doesn't stop on a prompt (the
  `_team_allow` list in team.sh): Read, Glob, Grep, Agent, SendMessage,
  ListAgents, and Edit/Write (on a build run, scoped to the teammate's own worktree plus its
  report, status file and `tasks.md`; on other runs, any path); Bash for `git status/diff/log/show/add/commit`, `ls`, `cat`, `head`, `tail`,
  `wc`, `grep`, `rg`, `bash -n`, `pytest`, `python3 -m pytest`, `make test`, `npm test`,
  `ruff`, `cmux notify`, `no-mistakes axi`, and team.sh `facts-lint`/`status`; and the Chrome
  DevTools MCP tools (UI QA needs Google Chrome stable and the MCP enabled; see the
  Chrome rule in `teammate-rules.md`). A rule approves every flag of its command, so commands with a
  destructive form (`git stash`, `git branch`, `git switch`, `find`, `npm run`) are left off,
  as are pushes, `gh` writes, installs, deploys and `rm`; those go through the TL (or the
  lead). That is a convention, not a hard block: under auto mode an unlisted command can
  still run. Likewise under auto mode the Edit/Write scope is pre-approval, not a fence; unlisted
  paths go to the auto classifier. One partial block: `git commit --no-verify` (and `-n`) is denied for every teammate
  through `--disallowedTools`, since it skips the secret-scanning hooks. The deny
  rules miss a git command that starts with a global option
  (`git -C <dir> commit --no-verify`, `git -c core.hooksPath=/dev/null commit`), a wrapper
  (`sh -c`, `/usr/bin/git`), or a combined short flag such as `-an` (measured with live
  `claude -p` probes, CLI 2.1.306). A PreToolUse fence for the git forms is planned. The deny
  also fails safe the other way: a commit whose inline `-m` message names the flag is refused,
  so write such a message to a file and use `git commit -F <file>`.
  Haiku-tier teammates always run unattended in dontAsk mode with a per-teammate allowlist
  (Read/Glob/Grep, SendMessage/ListAgents, Bash: git status/ls/wc/facts-lint/`cmux notify
  --title ...`, Edit on own report+tasks.md+status); TEAM_PERMISSION_MODE has no effect on
  haiku tier; they are refused on build runs.
- A teammate with a run dir also loads the skill's `plugin/` folder for that session only
  (`--plugin-dir`; nothing is written to your settings, and your own hooks and cmux's still
  run).
  - Event log: one line per hook event (time, event, tool name, notification type) in
    `.team/runs/<run>/events/<role>.jsonl`. Tool input, prompts and messages are never recorded.
  - PreToolUse fence, enforced even in auto mode. It blocks Edit/Write/MultiEdit/
    NotebookEdit outside the teammate's worktree, run dir and private scratch dir
    (`$TEAM_SCRATCH`), so `/tmp` and `~/.claude` (memory, plans) are off limits; and git
    commands that skip hooks (`--no-verify`, `commit -n`, core.hooksPath, aliases or
    include files set with `-c`, `--config-env` or `git config`, and the `GIT_CONFIG*`
    variables), also after `-C <dir>`, `sudo`, `env` or inside `sh -c`.
  The fence does not make Bash safe. Every other Bash write is unfenced, and so is git run
  through `eval`, backticks, `xargs` or another interpreter (`python3 -c`), git pointed at
  another config with `HOME=` or `XDG_CONFIG_HOME=`, and aliases already in your git config.
  If the plugin's hooks never run (for example under a managed
  `allowManagedHooksOnly` policy), there is no event log and no fence. The plugin is named
  `team-mates-events`; an installed plugin of that name is replaced for the session.
- The hard cap is 8 teammates (spawn refuses beyond it).
- Cost: every teammate is a full Claude session with its own context window,
  so cost scales with team size. Prefer 2–3 sharp roles; the lead already fits a model
  to each role, so reach for `--model` only to force one model everywhere.
- Give roles separate files when the task edits code.
- This emulates Claude Code's experimental agent teams for setups where they're
  unavailable (e.g. disabled by managed settings); the lead relays challenge
  rounds instead of a native shared mailbox.
