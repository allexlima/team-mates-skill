# /team redesign: a fast startup team

Date: 2026-11-17. Status: draft for approval.

## Intent

/team should behave like a small startup tech team. The lead (the main session) digs into
the task with the user, staffs a team with the right roles, and gets the work done
accurately and as fast as possible. Speed comes from three things: nobody sits idle while
work is pending, every teammate fans its own work out to subagents, and teammates rarely
stop to wait on a permission prompt.

The user watches progress in the monitor. Today the monitor doesn't answer the question
they actually have ("how far along is the whole job, and when will it be done?"), so they
end up asking the lead. Fixing that is part of this work.

## Goals

1. Teammates never use the cmux browser. Web/UI work goes through Google Chrome via the
   Chrome DevTools MCP (`mcp__plugin_chrome-devtools-mcp_chrome-devtools__*`).
2. tmux works as a fallback when cmux is absent. cmux stays the default and the
   recommended choice.
3. The monitor shows overall workflow % and one team ETA at the top, at any width, and
   folds finished teammates into one line.
4. The lead proposes a Tech Lead (TL) and/or a Product Manager (PM) for anything but a
   very basic task.
5. Teammates are reused. `tasks.md` is a backlog; when a teammate reports, it gets the
   next pending task that fits its role instead of being closed.
6. Teammates run most commands without prompting (broad allowlist); risky commands go
   through the TL.
7. Teammates parallelize with in-session subagents (already present; keep and tighten).
8. The lead brainstorms with the user before spawning, asking every question through
   AskUserQuestion.
9. Writing rules for runs: prose goes through `humanizer:humanizer`, READMEs through
   `beautify-github-readme`, diagrams through `diagram-design`.
10. Build runs follow a shipped git/GitHub guide (Conventional Commits, atomic commits,
    small or stacked PRs, gh).
11. This repo's own README gets a full redesign.

## Non-goals

- No hook-level live state under tmux (no "waiting on a permission prompt" signal there).
- No measured per-teammate progress. Percentages stay self-reported and must be described
  that way (CLAUDE.md rule).
- No change to the `--inline` mode beyond the shared prompt/rule text.
- No new dependencies in `team.sh` beyond what cmux or tmux already provide.

## Anti-goals

- A monitor that looks nicer but is less truthful. Every number on screen must come from
  disk (tasks.md, status files, reports, registry) or cmux/tmux, never from a guess.
- A TL that adds a hop to every action and slows the team down.
- Silent merges or pushes. Publishing still needs the user's yes.

## Decisions (made with the user)

| Topic | Decision |
|---|---|
| Overall % | Share of `tasks.md` items done; each open item credited by its owner's self-reported ` · NN%`. |
| Finished rows | Folded into one line, e.g. `3 finished · 2 PRs`. |
| Reuse | Backlog + reassign: on report, the lead/TL hands the teammate the next fitting pending task in the same session. It closes only when no fitting task is left. |
| TL / PM | TL is an opus teammate that splits work, assigns backlog items, reviews and merges branches, and keeps everyone busy. PM is added when scope is fuzzy: owns acceptance criteria and checks the result against them. The main session talks to the user and owns approvals. |
| Permissions | Broad allowlist at spawn for every non-haiku teammate; pushes, installs, deploys and destructive commands go only through the TL. |
| tmux | Spawn, close, finish, resume, show, list and the monitor work; live state is lighter. |
| Git guide | Shipped in the repo as `git-practices.md`. |
| Merging | The lead asks the user every run (AskUserQuestion). Recommended default: the TL merges with `gh` after review and green checks. |
| Risky commands | Convention only: kept off the allowlist and named in the prompt as TL-only. No `--disallowedTools` hard block; auto mode's own judgment is the backstop. |
| Merge scope | One user answer per run covers every TL merge in that run. Spawn approval covers pushes and opening PRs. The lead reports each merge to the user. |
| Untracked tool state | Add `.claude-flow/`, `.isaac/`, `.swarm/`, `ruvector.db` to `.gitignore`; never commit them. |
| Uncommitted `--branch` work | Keep it; commit it first as its own atomic commit. |
| How to build | Main session plus parallel subagents, small atomic commits (no dogfooding /team on itself). |
| README | Full redesign: hero, how-it-works diagram, humanizer pass. |

## Design by area

### A. Browser: Chrome DevTools MCP only

- `teammate-rules.md`: replace the whole cmux-browser section with a Chrome DevTools MCP
  section. Teammates open their own page with `new_page` using
  `isolatedContext: "<team>-<role>"` so teammates don't share cookies or tabs, reuse that
  one page (`navigate_page`), wait with `wait_for`, inspect with `take_snapshot` (prefer it
  over screenshots), and save evidence with `take_screenshot filePath=<run>/evidence/<role>-<step>.png`
  plus `list_console_messages`/`list_network_requests`. Close their pages with `close_page`
  before reporting. Credentials rule stays.
- State plainly: never use `cmux browser`, Playwright, or another browser.
- `team.sh`: `_close_browsers` and the `<run>/browser/<role>.txt` bookkeeping only exist
  for cmux surfaces. Remove them and their header lines, since teammates no longer open
  cmux surfaces. Chrome pages are the teammate's to close; the lead's `finish` can't reach
  them (the MCP is per session).
- Add `cmux browser` to the `doccheck` retired phrases (excluding this spec and git history).
- Open question for the builder to verify: whether several sessions' chrome-devtools MCP
  servers share one Chrome instance. If they don't, `isolatedContext` is harmless; if they
  do, it's what keeps teammates apart.

### B. tmux fallback

- Detection: cmux if `CMUX_*` env / `cmux ping` works; else tmux if `$TMUX` is set; else
  fail fast with an install hint naming cmux first ("recommended") and tmux as fallback.
  `--inline` still needs neither.
- A small backend layer in `team.sh` (or `lib/mux.sh`): open a pane/window with a title,
  send a command, close by id, focus by id, check whether an id is alive, read the screen
  (`tmux capture-pane`). Registry rows record the backend (rows already carry a type
  column; `team.sh:251` treats old tmux rows as legacy, which becomes live code again).
- `--tabs` under tmux means one tmux window per teammate.
- State under tmux: `working` while the pane's process is alive and its status file or
  pane content changed in the last 10 min; `stalled?` after that; `dead` when the pane is
  gone; `finished` from the registry. No `waiting`/`idle` distinction, and HELP.md must
  say so.
- Sidebar pill/progress (`sync`) are cmux-only; under tmux `sync` is a no-op that still
  writes the event log if one exists. The monitor runs as a tmux pane.
- `doccheck`: drop `--tmux`, `tmux pane`, `tmux session`, `tmux attach` from the retired
  list; the `--tmux` flag is replaced by auto-detection (keep `--tmux` refused or make it
  force the backend — builder's call, documented in HELP.md).
- Under tmux, `cmux notify` calls in teammate rules become "skip if cmux is absent" (the
  rule already says this for `--inline`).

### C. Monitor redesign (`lib/status.sh`)

Frame, top to bottom:

1. Headline, always shown at every width: `<team> ▕████████░░░░▏ 62% · ETA ~14m · 5/8 tasks · 00:23:10`.
   - `%` = (done tasks + Σ open tasks' owner-reported fraction) / total tasks. A task with
     no reported % counts 0. When no tasks.md items exist, fall back to today's teammate
     average and say so with a `~`.
   - ETA = elapsed × (100 − pct) / pct over the whole run, shown only once pct ≥ 5. Label
     it as an estimate (`~`).
2. NEEDS YOU block (unchanged meaning: waiting, dead, model gone, stalled?).
3. Live rows: `N ROLE · STATE · TASK · STEP · % · AGE`. TASK is the backlog item the
   teammate is on now. Per-row bar/ETA only when width allows (keep today's thresholds or
   better).
4. One folded line: `✓ 3 finished · 2 PRs open` (PR count from reports when present).
5. Backlog line: `backlog: 3 pending · 0 unassigned` — an unassigned pending task while a
   teammate is idle is shown under NEEDS YOU as `idle with work pending`, since that's the
   waste the user cares about.

Keys/click, auto-close, colour gate and the sidebar stay; the sidebar pill and progress
bar use the new overall %. Use `tui-design:tui-design` for the visual pass. Update
`tests/status-render.sh` golden frames; add cases for the % formula, folding, the backlog
line, and narrow widths.

### D. Backlog and reuse

- `tasks.md` format gains task lines beyond one-per-role:
  `- [ ] T3 <role-or-any>: <scope> — owns: <files> — needs: T1` (owner may be a role
  name or `any`). The existing per-role line format must keep parsing (old runs, finish
  guard `- [x] <team>-<role>:`).
- On a report the lead (or TL) checks the backlog. If a fitting pending task exists, it
  sends it (SendMessage to the live teammate) instead of running `finish`. The finish
  guards stay as they are for the final close. The builder must keep the PARALLELISM
  baseline logic correct for a teammate that reports more than once while live (today it
  assumes close-on-report; a per-task baseline is the likely fix).
- A teammate closes only when no fitting task is pending.

### E. TL and PM

- Add shared role specs `tech-lead.md` and `product-manager.md` to the shared library
  (`~/.claude/team/roles/`) using the five headings. TL tier opus, PM tier sonnet.
- SKILL.md step 2: propose a TL for anything beyond a very basic task, and a PM when
  scope or acceptance is fuzzy. The roster table says why. The user can drop them.
- TL duties in its prompt: own the backlog, assign tasks to idle teammates within a
  minute of a report, review branches, run the risky commands (push, gh, installs),
  stack/merge PRs per the user's merge choice, and report to the lead. The lead still
  relays NEEDS INPUT and owns all user-facing questions.
- Teammates SendMessage reports to the TL when one exists, with the lead copied (or the
  TL forwards) — builder's call, but the monitor and `finish` must still see the report
  on disk.

### F. Permissions

- At spawn, non-haiku teammates get `--allowedTools` with a broad, local-only set: read
  and search tools, Edit/Write in their worktree or owned files, Bash for common read,
  build, test, lint and local git (status, diff, log, add, commit, branch, switch,
  stash), the project's test/lint commands, and Chrome DevTools MCP tools. Keep
  `TEAM_PERMISSION_MODE` (default auto) on top. Haiku-tier rules stay unchanged.
- Pushes, `gh` writes, package installs, deploys and destructive commands are not on the
  list, and the prompt names them as TL-only (no TL: lead-only). This is a convention by
  the user's choice, not a hard block: under auto mode an unlisted command may still run,
  and HELP.md must say so.
- The exact list lives in one place in `team.sh` and HELP.md quotes it.

### G. Writing, diagrams, git

- SKILL.md rules and `teammate-rules.md`: any user-facing prose (reports, synthesis, PR
  descriptions, docs) goes through `humanizer:humanizer`; any README goes through
  `beautify-github-readme`; any diagram through `diagram-design`.
- New `git-practices.md` in the repo: the user's guide (trunk-based, Conventional Commits
  with the 7 rules, atomic commits, PRs under ~200 lines, stacked PRs, hooks), plus a
  short gh section: `gh pr create` with context/what/why/how-to-test, `--base` for
  stacked PRs, `gh pr checks` before asking for merge, `gh pr merge` only by the TL and
  only per the user's merge choice. Org attribution lines for commits/PRs apply.
- Build-run prompts carry a 5-line summary and a path to the full file.

### H. Brainstorm and speed focus

- SKILL.md step 1: brainstorm with `superpowers:brainstorming`, every question through
  AskUserQuestion (already the rule; make it explicit for the brainstorm).
- SKILL.md intro: one paragraph stating the mission (deep-dive the scope, staff the right
  roles, finish accurately and fast like a startup team) and the three speed levers.

### I. This repo

- README full redesign with `beautify-github-readme`, one how-it-works diagram via
  `diagram-design`, humanizer pass. README links to `--help` rather than keeping its own
  flag table (CLAUDE.md ownership rule).
- Every doc change follows the ownership table in `CLAUDE.md`.

## Constraints

- One owner per fact (CLAUDE.md table). Run `bash team.sh doccheck` after doc edits.
- All gates in CLAUDE.md must pass before done, from the main checkout with `TEAM_MEMBER`
  unset. New tests go into the listed suites (or a new suite added to that list).
- Atomic Conventional Commits, small and reviewable. Suggested order: `--branch` WIP,
  browser, permissions, backlog/reuse, TL/PM, tmux backend, monitor, git guide + writing
  rules, README.

## Calls made during review (main session's, not the user's)

- Haiku-tier teammates do no UI QA. Their allowlist stays as is; the browser section of
  `teammate-rules.md` tells a haiku-tier teammate to report UI checks as not done.
- Once a TL exists it is the single authority for assigning and for deciding a teammate
  has no fitting work left. The lead still runs `team.sh finish` (one writer for the
  registry) when the TL says so, and clears `idle with work pending` by acting on it.
- tmux tests use a real tmux server on a private socket (`tmux -L team-test-$$`), killed
  at the end, and skip with a notice when tmux is absent. tmux 3.7c is installed here.
- `docs/superpowers/specs/` is committed with the work.

## Left to the builder

- Internal structure of the mux backend layer and file placement.
- Exact allowlist entries, as long as nothing that publishes or destroys is on it.
- Monitor glyphs and colours, within the frame order above.
- Whether `--tmux` becomes a force flag or stays refused.
- How reports route when a TL exists, as long as disk records stay the source of truth.
