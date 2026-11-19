#!/usr/bin/env bash
# lib/status.sh — sub_status, sub_monitor, sub_sync functions for team.sh
# Sourced by team.sh after helpers are defined (set -euo pipefail is already on).
# Functions only; no top-level side effects.
#
# Requires team.sh globals/functions (bound before sourcing):
#   $here              absolute dir of team.sh
#   _root              prints main checkout root (main worktree)
#   _reg <team>        prints <registry dir>/team-<team>.tabs (team.sh _reg_dir: private 0700 per-user dir)
#   _reg_add <team> <ref> <layout> <title> <model|-> <submodel|-> <rundir|-> [<sid> <cwd>]
#                      appends a registry row (root + state=live inserted automatically)
#   _pane_of <ref>     prints cmux pane_ref or "gone" (cmux only)
#   _lead_pane         prints "<pane_ref> <surface_ref>" of caller's session
#   _model_tier <m>    prints opus|sonnet|haiku or empty
#   _model_gone <m>    returns 0 if model not in org picker (fallback defined below)
#   _alive <b> <r>     returns 0 if surface/pane exists (fallback defined below)
#   _require_cmux [ws] exits 3 if cmux absent/unhealthy; ws also checks CMUX_*IDs
#   _lock <file>       acquire lock; EXIT trap set for cleanup
#   _tasks_state <tasks.md> <title>  prints done | "open T<n>" | none
#
# Registry row format (team.sh, 11 cols):
#   backend ref layout title model submodel rundir root state session-id cwd
#   col 3 layout ∈ pane|tab|dash  (dash = monitor row, excluded from status table)
#   col 6 CLAUDE_CODE_SUBAGENT_MODEL id or "-" (absent on old rows → "")
#   col 7 absolute run dir or "-" (absent on old rows → "")
#   col 8 project root or "-" (absent on old rows → "")
#   col 9 live|finished (absent on rows before rev5 → live). `finished` = closed on
#         purpose by `team.sh finish`; its surface is gone by design, so it is never DEAD
#   col 10 session id or "-"; col 11 cwd (last, may contain spaces)
#
# Module-level state (reset by each _st_records call):
#   _ST_UUID_MAP   "surface:N=UUID\n…" built from cmux list-panes (one python3 call)
#   _ST_NOTIF_DATA "UUID|title|subtitle\n…" from cmux list-notifications --json
#
# FLAGS column note — WAITING covers AskUserQuestion only (title="Claude question").
# Tool-approval permission prompts go to `cmux hooks feed`, NOT list-notifications,
# so without the team plugin's event log a teammate blocked on a permission prompt shows no
# flag and STALLED? fires after 10 min of filesystem silence. With the log (_st_events) the
# prompt is its own PERMISSION state, under tmux too.

_ST_UUID_MAP=
_ST_NOTIF_DATA=

# Shared palette (decision 16): the sidebar pill and the monitor pane use the same
# four roles. None is "#4C8DFF" — `cmux set-status --help` documents that hex as the
# cmux accent, which the claude shim's own claude_code pill already uses.
_ST_C_ALERT='#FF453A'   # needs you / dead
_ST_C_ACTIVE='#AF52DE'  # working
_ST_C_DONE='#30D158'    # reported / finished
# Sidebar sort priority; higher appears first. The shim's claude_code pill is 0.
_ST_PILL_PRIORITY=50

# ---------------------------------------------------------------------------
# Fallback helpers — activate only when team.sh hasn't defined them
# ---------------------------------------------------------------------------

if ! declare -f _model_gone >/dev/null 2>&1; then
  _model_gone() {
    declare -f _team_models >/dev/null 2>&1 || return 1
    local m="$1"
    _team_models 2>/dev/null | awk -v m="$m" '
      $2==m || $1==m { found=1 }
      END { exit (found ? 1 : 0) }
    '
  }
fi

if ! declare -f _alive >/dev/null 2>&1; then
  _alive() {
    local backend="$1" ref="$2"
    case $backend in
      cmux)
        command -v cmux >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || return 0
        local out
        out=$(cmux identify --surface "$ref" 2>&1) \
          || { case $out in *not_found*) return 1 ;; esac; return 0; }
        ;;
      *) return 0 ;;  # non-cmux: assume alive (conservative)
    esac
  }
fi

if ! declare -f _require_cmux >/dev/null 2>&1; then
  _require_cmux() {
    command -v cmux >/dev/null 2>&1 \
      || { printf 'team.sh: cmux not found — install from https://cmux.app\n' >&2; return 3; }
    cmux ping >/dev/null 2>&1 \
      || { printf 'team.sh: cmux not responding (cmux ping failed)\n' >&2; return 3; }
    if [ "${1:-}" = ws ]; then
      [ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ] \
        || { printf 'team.sh: must run inside a cmux pane\n' >&2; return 3; }
    fi
  }
fi

if ! declare -f _reg_add >/dev/null 2>&1; then
  _reg_add() {
    local team="$1" ref="$2" lay="$3" title="$4" mdl="${5:--}" smdl="${6:--}" rdir="${7:--}"
    local sid="${8:--}" cwd="${9:-}"
    local root; root=$(_root 2>/dev/null || pwd)
    printf 'cmux %s %s %s %s %s %s %s live %s %s\n' \
      "$ref" "$lay" "$title" "$mdl" "$smdl" "$rdir" "$root" "$sid" "$cwd" \
      >> "$(_reg "$team")"
  }
fi

# ---------------------------------------------------------------------------
# _st_state <finished> <backend> <alive> <model_gone> <waiting> <idle> <stalled> [<permission>]
# Pure: prints exactly one state token from the detection facts _st_row gathers.
# Flags are 1 or empty; <alive> is 1 (surface exists), 0 (gone) or empty (unknown,
# e.g. no cmux on PATH). Decision order, first match wins:
#   FINISHED    col 9 is rev5-core's `finished` marker — the only "finished on
#               purpose" signal (surface-health omits closed surfaces, and a report on
#               disk alone is also true mid-flight and in round 2)
#   UNKNOWN     not a cmux row, or liveness unknown: never rendered as alive
#   DEAD        surface gone without the marker
#   MODEL_GONE  model (or subagent model) no longer offered
#   PERMISSION  the event log's last state-bearing event is a permission request (_st_events)
#   WAITING     an AskUserQuestion still open in the event log; without a log, the newest
#               notification is an AskUserQuestion ("Claude question")
#   STALLED     mid-work milestone, no status/report write for >=10 min; with an event log,
#               measured WORKING with no event and no open tool for >=10 min
#   IDLE        no report on disk and the event log measures IDLE or ENDED (never STALLED),
#               or without a log the newest notification is "Completed in …" (routine while
#               waiting on a peer; after 10 silent min it is STALLED)
#   WORKING     everything else (including "report on disk" while still alive)
# ---------------------------------------------------------------------------
_st_state() {
  local fin=$1 backend=$2 alive=$3 gone=$4 waiting=$5 idle=$6 stalled=$7 perm=${8:-}
  if [ -n "$fin" ]; then echo FINISHED
  elif { [ "$backend" != cmux ] && [ "$backend" != tmux ]; } || [ -z "$alive" ]; then echo UNKNOWN
  elif [ "$alive" != 1 ]; then echo DEAD
  elif [ -n "$gone" ]; then echo MODEL_GONE
  elif [ -n "$perm" ]; then echo PERMISSION
  elif [ -n "$waiting" ]; then echo WAITING
  elif [ -n "$stalled" ]; then echo STALLED
  elif [ -n "$idle" ]; then echo IDLE
  else echo WORKING
  fi
}

# ---------------------------------------------------------------------------
# _st_events <events-file> <now-epoch>: teammate state from the plugin's hook log
# (skills/team/plugin, one {"t","ev","tool","ntype"} line per event). Prints one line
#   <state> <activity_age_s> <open_tool|->
# or nothing when the file is missing or empty (no plugin hooks ran: callers keep the
# older notification/silence inference). Live teammates only: a finished one has no log
# that matters, so callers skip this once the row is finished.
# The last state-bearing event decides, first match wins:
#   PermissionRequest, Notification/permission_prompt     -> PERMISSION
#   Stop, StopFailure, Notification/idle_prompt           -> IDLE
#   SessionEnd                                             -> ENDED
#   anything else (SessionStart, UserPromptSubmit, Pre/PostToolUse, ...) -> WORKING
# SubagentStart/SubagentStop never change state: a background subagent's SubagentStop can
# land after a PermissionRequest (T27 spike) and would otherwise clear it; they still count
# as activity. <open_tool> is the tool of a PreToolUse with no later PostToolUse(Failure),
# PermissionDenied, UserPromptSubmit (a new turn: a denied tool never gets a PostToolUse),
# Stop or SessionEnd: a long tool is running, so silence is not a stall.
# A subagent's events ("sub":1) count as activity only: the main thread's state and open tool
# are what the row shows. The one exception is a subagent's PermissionRequest, a wait on the
# user too: it shows PERMISSION until the next subagent tool result or denial (subagents are
# not told apart, so any subagent's clears it), or until any main-thread event.
# Reads only the last 2000 lines; the writer's fixed format lets awk parse it.
# shortcut: about 1000 subagent tool calls after a main PermissionRequest still push it out of
# view (the row falls back to the older inference); scan backwards for the last main-thread
# line if that shows up in practice.
# ---------------------------------------------------------------------------
_st_events() {
  local f=$1 now=$2
  [ -s "$f" ] && [ ! -L "$f" ] || return 0
  tail -n 2000 "$f" 2>/dev/null | awk -v now="$now" '
    function val(k,   s) { if (!match($0, "\"" k "\": *\"?[A-Za-z0-9_.:-]+")) return ""
      s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*": *"?/, "", s); return s }
    { t = val("t") + 0; ev = val("ev"); if (ev == "" || t == 0) next
      last = t
      if (val("sub") == "1") {
        if (ev == "PermissionRequest") subperm = 1
        else if (ev == "PostToolUse" || ev == "PostToolUseFailure" || ev == "PermissionDenied") subperm = 0
        next }
      if (ev == "SubagentStart" || ev == "SubagentStop") next
      nt = val("ntype")
      # the notification raised by a subagent prompt carries no agent_id: it is that same prompt
      if (subperm && ev == "Notification" && nt == "permission_prompt") next
      subperm = 0
      tool = val("tool")
      if (ev == "PermissionRequest" || (ev == "Notification" && nt == "permission_prompt")) state = "PERMISSION"
      else if (ev == "Stop" || ev == "StopFailure" || (ev == "Notification" && nt == "idle_prompt")) { state = "IDLE"; open = "" }
      else if (ev == "SessionEnd") { state = "ENDED"; open = "" }
      else if (ev == "Notification") next
      else state = "WORKING"
      if (ev == "PreToolUse") open = (tool == "" ? "?" : tool)
      else if (ev == "PostToolUse" || ev == "PostToolUseFailure" || ev == "PermissionDenied" || ev == "UserPromptSubmit") open = ""
    }
    END { if (subperm) state = "PERMISSION"; if (state == "") exit; a = now - last; if (a < 0) a = 0
          printf "%s %d %s\n", state, a, (open == "" ? "-" : open) }'
}

# ---------------------------------------------------------------------------
# _st_row <row> <run> <leadpane> <team>: one TAB-separated record per teammate
#   role  title  state  milestone  step  age_min(-1 = none)  note  pct  elapsed
#   event_state  event_age_s  open_tool   ('-' each when the teammate has no event log)
#   step_k  step_n   (steps done / total from a "T<n>: k/N · step" status line, else '-')
# Detection only (decision 7): gathers the facts and asks _st_state for the token;
# _st_frame does all layout. Reads module globals: _ST_UUID_MAP, _ST_NOTIF_DATA
# ---------------------------------------------------------------------------
# _st_model_gone <m>: _model_gone's answer from the picker read once per refresh into
# _ST_MODELS (one python start per refresh, not two per teammate).
# _st_mtime <file>: mtime in epoch seconds. GNU stat vs BSD stat is probed once per refresh
# (_ST_GNUSTAT, set in _st_records), not by a failing fork per file on macOS.
_ST_GNUSTAT=
_st_mtime() {
  if [ -z "$_ST_GNUSTAT" ]; then stat -c %Y / >/dev/null 2>&1 && _ST_GNUSTAT=1 || _ST_GNUSTAT=0; fi
  if [ "$_ST_GNUSTAT" = 1 ]; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}

_ST_MODELS=
_st_model_gone() {
  case ${1:-} in ''|-|opus|sonnet|haiku) return 1 ;; esac
  local _a _id
  while IFS=$'\t' read -r _a _id _; do [ "$_id" = "$1" ] && return 1; done <<<"$_ST_MODELS"
  return 0
}

_st_row() {
  local row="$1" run="$2" leadpane="$3" team="$4"

  local backend ref lay title mdl submdl rundir marker
  # One read, not eight awk forks: this runs per teammate on every refresh.
  local _c8 _rest
  read -r backend ref lay title mdl submdl rundir _c8 marker _rest <<<"$row" || true

  # Strip exact team prefix to handle team slugs with hyphens
  local role="${title#"$team"-}"

  # Registry col 7 (rundir) wins over the caller-supplied run fallback
  local effective_run="$run"
  if [ -n "$rundir" ] && [ "$rundir" != "-" ] && [ -d "$rundir" ]; then
    effective_run="$rundir"
  fi

  local rpt= stf=
  if [ -n "$effective_run" ]; then
    rpt="$effective_run/reports/$role.md"
    stf="$effective_run/status/$role.txt"
    # Some teammates may use <team>-<role>.txt; accept both
    if [ ! -f "$stf" ] && [ -f "$effective_run/status/$title.txt" ]; then
      stf="$effective_run/status/$title.txt"
    fi
  fi

  # ------ MILESTONE -------------------------------------------------------
  local ms=spawned
  if [ -n "$rpt" ] && [ -f "$rpt" ]; then
    ms=reported
  elif [ -n "$stf" ] && [ -f "$stf" ]; then
    ms=investigating
    grep -qi 'draft' "$stf" 2>/dev/null && ms=drafting
  fi
  # A teammate reused for another backlog task (team.sh _tasks_state "open T<n>") is not reported
  # even with an earlier task's report on disk; a ticked line with no report still counts.
  if [ -n "$effective_run" ] && [ -f "$effective_run/tasks.md" ]; then
    case $(_tasks_state "$effective_run/tasks.md" "$title") in
      open\ *) [ "$ms" = reported ] && ms=investigating ;;
      done) ms=reported ;;
    esac
  fi

  # ------ STEP (last line of status file; _st_frame truncates by display width)
  local step='-'
  if [ -n "$stf" ] && [ -f "$stf" ]; then
    local raw; raw=$(tail -1 "$stf" 2>/dev/null | tr '\t\r' '  ') || true
    step="${raw:--}"
  fi

  # ------ PROGRESS (optional "· NN%" suffix the teammate self-reports) ----
  # Self-reported, never measured: cmux exposes no per-teammate progress signal.
  local pct=-
  if [[ "$step" =~ ([0-9]{1,3})%[[:space:]]*$ ]]; then
    pct="${BASH_REMATCH[1]}"
    [ "$pct" -gt 100 ] && pct=100
    step=$(printf '%s' "$step" | sed -E 's/[[:space:]]*(·|\xc2\xb7)?[[:space:]]*[0-9]{1,3}%[[:space:]]*$//')
    [ -n "$step" ] || step='-'
  fi
  # Step-based progress, "T<n>: k/N · step": k of N steps done gives pct = k/N and wins over a
  # "· NN%" suffix. Still the teammate's own count, never measured.
  local sk=- sn=- _sre='^[[:space:]]*(T[0-9]+:[[:space:]]*)?([0-9]{1,4})/([0-9]{1,4})[[:space:]]*(·|-)'
  if [[ "$step" =~ $_sre ]] && [ $((10#${BASH_REMATCH[3]})) -gt 0 ]; then
    sn=$((10#${BASH_REMATCH[3]})); sk=$((10#${BASH_REMATCH[2]}))
    [ "$sk" -gt "$sn" ] && sk=$sn
    pct=$((sk * 100 / sn))
  fi

  # ------ ELAPSED (since this round's spawn; sysprompt mtime is written then) --
  local elapsed=-1
  local spf; spf="$(dirname "$(_reg "$team")")/team-$team-$role.sysprompt.md"
  if [ -f "$spf" ]; then
    local st; st=$(_st_mtime "$spf") || true
    if [ -n "${st:-}" ]; then
      local n2; n2=$(date +%s); elapsed=$(( (n2 - st) / 60 ))
    fi
  fi

  # ------ LAST_ACTIVITY (age of newest {report, status} mtime) ------------
  local newest=0 age=-1
  local f t
  for f in "$rpt" "$stf"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    t=$(_st_mtime "$f") || continue
    [ "$t" -gt "$newest" ] && newest=$t
  done
  if [ "$newest" -gt 0 ]; then
    local now; now=$(date +%s)
    age=$(( (now - newest) / 60 ))
  fi

  # ------ FACTS -----------------------------------------------------------
  local fin= alive= gone= waiting= idle= stalled= parked=
  [ "$marker" = finished ] && fin=1

  # STALLED: derived signals only; fires during mid-work milestones, silent >10m
  case $ms in
    spawned|investigating|drafting)
      [ "$age" -ge 10 ] && stalled=1 ;;
  esac

  # MODEL_GONE (N3): check main model col and subagent model col
  local m
  for m in "$mdl" "$submdl"; do
    [ -z "$m" ] || [ "$m" = "-" ] && continue
    _st_model_gone "$m" && { gone=1; break; }
  done

  # tmux rows: liveness only. tmux has no hook feed, so no waiting/idle; stalled? still
  # comes from status-file silence above.
  if [ -z "$fin" ] && [ "$backend" = tmux ] && command -v tmux >/dev/null; then
    alive=0; _alive tmux "$ref" 2>/dev/null && alive=1
  fi
  # Liveness / parked-in-lead-pane / WAITING / IDLE (cmux only; skipped once finished)
  if [ -z "$fin" ] && [ "$backend" = cmux ] && command -v cmux >/dev/null; then
    # DEAD only on _alive's definite answer (not_found / null pane_ref). _alive keeps
    # the row on any cmux error, so a _pane_of failure after it is an error too: UNKNOWN.
    # One `cmux identify` answers both questions (the surface exists; which pane holds it).
    # DEAD on not_found or a null pane_ref; any other error leaves the state UNKNOWN.
    local idout idrc=0 pp=
    idout=$(cmux identify --surface "$ref" 2>&1) || idrc=$?
    if [ "$idrc" != 0 ]; then
      case $idout in *not_found*) alive=0 ;; esac
    else
      # caller object only, no python start per row. An object without a pane_ref means the
      # surface is gone; a null caller stays UNKNOWN, as _alive (reap/prune) treats it.
      if [[ $idout =~ \"caller\"[[:space:]]*:[[:space:]]*(\{[^}]*\}) ]]; then
        pp=gone
        [[ ${BASH_REMATCH[1]} =~ \"pane_ref\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && pp=${BASH_REMATCH[1]}
      fi
      case $pp in '') ;; gone) alive=0 ;; *) alive=1 ;; esac
    fi
    if [ "$alive" = 1 ]; then
      # In the lead's pane (show's failure path, a hand-dragged tab): a note, not a state
      if [ -n "$leadpane" ] && [ "$pp" = "$leadpane" ]; then
        parked=1
      fi

      # WAITING / IDLE: derive from newest cmux notification for this surface.
      # Skip WAITING for haiku/dontAsk tier (no human approval needed).
      # Probed by rev4-tests (CLI 2.1.294):
      #   AskUserQuestion  → title="Claude question", subtitle=""
      #   Completion/Stop  → title="Claude Code",     subtitle="Completed in <session>"
      #   PermissionRequest → NOT in list-notifications (uses cmux hooks feed).
      #     Permission prompts cannot be detected via notifications; a teammate
      #     blocked on one surfaces only as STALLED after 10 min of silence.
      local skip_waiting=
      case "${mdl:-}" in *haiku*|*glm*|*kimi*) skip_waiting=1 ;; esac
      if [ -z "$skip_waiting" ]; then
        local _a _id tier=
        while IFS=$'\t' read -r _a _id tier; do [ "$_id" = "${mdl:-}" ] && break; tier=; done <<<"$_ST_MODELS"
        [ "$tier" = haiku ] && skip_waiting=1
      fi
      if [ -n "$_ST_UUID_MAP" ] && [ -n "$_ST_NOTIF_DATA" ]; then
        # Line-anchored lookups (a leading newline), so surface:1 never matches surface:10.
        local uuid= um nl
        um=$'\n'"$_ST_UUID_MAP"
        case $um in *$'\n'"$ref="*) uuid=${um#*$'\n'"$ref="}; uuid=${uuid%%$'\n'*} ;; esac
        if [ -n "$uuid" ]; then
          local notif_line notif_title notif_subtitle
          nl=$'\n'"$_ST_NOTIF_DATA"
          case $nl in *$'\n'"$uuid|"*) notif_line=${nl#*$'\n'"$uuid|"}; notif_line=${notif_line%%$'\n'*} ;; *) notif_line= ;; esac
          if [ -n "$notif_line" ]; then
            notif_title=${notif_line%%|*}
            notif_subtitle=${notif_line#*|}
            if [ -z "$skip_waiting" ]; then
              grep -qi 'claude question' <<<"$notif_title" && waiting=1
            fi
            # Session completed its last turn but report not yet on disk
            if [ "$ms" != reported ]; then
              grep -qi '^completed in ' <<<"$notif_subtitle" && idle=1
            fi
          fi
        fi
      fi
    fi
  fi

  # Measured state from the plugin's event log (live rows only: a finished teammate's log is
  # history). It wins over the silence and notification inference above, under tmux too:
  # stalled? needs 10 min with no event and no tool still running (a long tool or hook is not
  # a stall), idle comes from Stop/idle_prompt/SessionEnd (a measured idle is never stalled?),
  # waiting only from an open AskUserQuestion, and a permission request is its own state.
  local evs=- eva=- evt=- perm= _ev
  if [ -z "$fin" ] && [ -n "$effective_run" ] && _ev=$(_st_events "$effective_run/events/$role.jsonl" "$(date +%s)") && [ -n "$_ev" ]; then
    read -r evs eva evt <<<"$_ev"
    idle= stalled= waiting=
    case $evs in
      PERMISSION) perm=1 ;;
      IDLE|ENDED) [ "$ms" = reported ] || idle=1 ;;
    esac
    # An open AskUserQuestion is a wait on the user even where no notification says so (tmux).
    [ "$evt" = AskUserQuestion ] && [ -z "${skip_waiting:-}" ] && waiting=1
    case $ms in spawned|investigating|drafting)
      [ "$evs" = WORKING ] && [ "$evt" = - ] && [ "$eva" -ge 600 ] && stalled=1 ;;
    esac
  fi

  local state; state=$(_st_state "$fin" "$backend" "$alive" "$gone" "$waiting" "$idle" "$stalled" "$perm")

  # Notes: context a token alone cannot carry
  local note=
  if [ -n "$parked" ] && [ "$state" = WORKING ]; then note="in the lead's pane"
  elif [ "$state" = WORKING ] && [ "$ms" = reported ]; then note="report on disk"
  elif [ "$state" = DEAD ] && [ -n "$rpt" ] && [ -f "$rpt" ]; then note="report safe; resume unavailable"
  fi

  # Record contract: 12 TAB-separated fields, NONE of them empty. Tab is IFS
  # whitespace, so a reader using `read -d $'\t'` collapses consecutive tabs and
  # silently shifts every field after an empty one. Absent values use '-'.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$role" "$title" "$state" "$ms" "$step" "$age" "${note:--}" "$pct" "$elapsed" "$evs" "$eva" "$evt" "$sk" "$sn"
}

# _st_records <reg> <run> <leadpane> <team>: one _st_row record per non-dash teammate
# (deduplicated by title, last row wins). The single record source for the pane and
# the sidebar, so N/M is counted the same way on both surfaces.
_st_records() {
  local reg="$1" run="$2" leadpane="$3" team="$4"

  # Build surface ref → UUID map (single python3 call).
  # list-panes --json has surface_refs[] + surface_ids[] in parallel arrays.
  _ST_UUID_MAP=
  if command -v cmux >/dev/null && command -v python3 >/dev/null \
      && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    _ST_UUID_MAP=$(python3 -c "
import json, subprocess, os, sys
ws = os.environ.get('CMUX_WORKSPACE_ID', '')
if not ws:
    sys.exit(0)
try:
    r = subprocess.run(['cmux', 'list-panes', '--workspace', ws, '--json'],
                      capture_output=True, text=True, timeout=5)
    data = json.loads(r.stdout)
    for pane in data.get('panes', []):
        for ref, uid in zip(pane.get('surface_refs', []),
                            pane.get('surface_ids', [])):
            print(ref + '=' + uid)
except Exception:
    pass
" 2>/dev/null || true)
  fi

  # Build team UUID set from registry refs (used to filter notification data).
  local _st_team_uuids=""
  if [ -n "$_ST_UUID_MAP" ]; then
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      local _lay _ref _uid
      _lay=$(awk '{print $3}' <<<"$row")
      [ "$_lay" = dash ] && continue
      _ref=$(awk '{print $2}' <<<"$row")
      _uid=$(awk -F'=' -v r="$_ref" '$1==r {print $2; exit}' <<<"$_ST_UUID_MAP" 2>/dev/null || true)
      [ -n "$_uid" ] && _st_team_uuids="$_st_team_uuids $_uid"
    done < "$reg"
    _st_team_uuids="${_st_team_uuids# }"
  fi

  # Fetch notifications for WAITING state detection.
  # Privacy: filter to team surface UUIDs only; never emit body.
  # Stale-state: keep NEWEST notification per surface (by created_at), regardless
  # of read state, so a stale "waiting" cleared by a newer "Completed" won't fire.
  _ST_NOTIF_DATA=
  if command -v cmux >/dev/null && command -v python3 >/dev/null; then
    _ST_NOTIF_DATA=$(export _ST_TEAM_UUIDS="$_st_team_uuids"; python3 -c "
import json, subprocess, sys, os
team_uuids = set(os.environ.get('_ST_TEAM_UUIDS', '').split())
try:
    r = subprocess.run(['cmux', 'list-notifications', '--json'],
                      capture_output=True, text=True, timeout=5)
    newest = {}  # surface_id -> newest notification dict
    for n in json.loads(r.stdout):
        sid = n.get('surface_id', '')
        if not sid:
            continue
        if team_uuids and sid not in team_uuids:
            continue  # filter to team surfaces only
        ts = n.get('created_at', '')
        if sid not in newest or ts > newest[sid].get('created_at', ''):
            newest[sid] = n
    for sid, n in newest.items():
        # Replace | in title/subtitle to keep pipe-split safe; never emit body
        title = n.get('title', '').replace('|', ' ')
        subtitle = n.get('subtitle', '').replace('|', ' ')
        print(sid + '|' + title + '|' + subtitle)
except Exception:
    pass
" 2>/dev/null || true)
  fi

  _ST_MODELS=$(_team_models 2>/dev/null || true)
  _ST_GNUSTAT=; _st_mtime / >/dev/null   # probe stat flavour here, outside the per-row subshells

  # Deduplicate by title (last row wins, first-appearance order, dash excluded)
  local deduped
  deduped=$(awk '
    $3 == "dash" { next }
    {
      rows[$4] = $0
      if (!seen[$4]++) { order[++n] = $4 }
    }
    END { for (i = 1; i <= n; i++) print rows[order[i]] }
  ' "$reg" 2>/dev/null || true)

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    _st_row "$row" "$run" "$leadpane" "$team"
  done <<<"$deduped"
}

# ---------------------------------------------------------------------------
# _st_summary <run-dir>: teammate records on stdin -> one @summary record, the single
# owner of the overall % and team ETA (the pane and the sidebar both read it):
#   @summary done total pct est elapsed_min eta_min pending unassigned prs [ready_owners]
# pct = (done tasks + each open task's owner-reported %) / total tasks; -1 when tasks.md
# has no task lines (consumers then fall back to the teammate average). est=1 when any
# self-reported % went into it. eta = elapsed x (100 - pct) / pct, only for 5 <= pct < 100.
# A teammate's % goes to the task its status line names ("T3: ..."), else its first open task.
# unassigned = open tasks whose needs are done, whose owner is `any` or not live, and that no
# live teammate has claimed by starting its status line with "T<n>:".
# ready_owners = comma-joined live teammates that hold a ready task: their own line or a claimed one.
# With a team (2nd arg) only tasks owned by <team>-* or `any` count: a tasks.md can carry
# another team's lines.
# With `json <registry>` after <run-dir> <team> it prints one JSON document instead (the
# `status --json` contract the TUI monitor reads): the same summary, plus every teammate
# joined with its registry row and every parsed task. One parser for tasks.md, two outputs.
# ---------------------------------------------------------------------------
read -r -d '' _ST_SUMMARY_PY <<'PY' || true
import glob, json, os, re, sys, time
run = sys.argv[1]
team = sys.argv[2] if len(sys.argv) > 2 else ''
mode = sys.argv[3] if len(sys.argv) > 3 else 'summary'
recs = {}
for line in sys.stdin:
    f = line.rstrip('\n').split('\t')
    if len(f) < 9 or f[0].startswith('@'):
        continue
    def num(x):
        try: return int(x)
        except ValueError: return -1
    recs[f[1]] = dict(role=f[0], state=f[2], ms=f[3], step=f[4], age=num(f[5]),
                      note='' if f[6] == '-' else f[6], pct=num(f[7]), elapsed=num(f[8]),
                      evs=f[9] if len(f) > 11 else '-', eva=num(f[10]) if len(f) > 11 else -1,
                      evt=f[11] if len(f) > 11 else '-',
                      sk=num(f[12]) if len(f) > 13 else -1, sn=num(f[13]) if len(f) > 13 else -1)
tasks = []   # [id, owner, done, needs, rest-of-line]
try:
    lines = open(os.path.join(run, 'tasks.md'), encoding='utf-8', errors='replace').read().splitlines()
except OSError:
    lines = []
for n, l in enumerate(lines, 1):
    m = re.match(r'\s*- \[([ xX])\] (T\d+) (\S+):(?:\s+(.*))?$', l)
    if m:
        nd = re.search(r'needs:\s*(.*)$', m.group(4) or '')
        tasks.append([m.group(2), m.group(3), m.group(1) != ' ',
                      re.findall(r'T\d+', nd.group(1)) if nd else [], m.group(4) or ''])
        continue
    m = re.match(r'\s*- \[([ xX])\] (\S+):', l)
    if m:
        tasks.append(['L%d' % n, m.group(2), m.group(1) != ' ', [], ''])
if team:
    # A sibling run dir <date>-<slug> with slug starting "<team>-" is another team whose
    # owners (<slug>-role) would otherwise pass the prefix test; live records still count.
    others = [m.group(1) for d in glob.glob(os.path.join(os.path.dirname(run.rstrip('/')), '*'))
              for m in [re.match(r'\d{4}-\d\d-\d\d-(.+)$', os.path.basename(d))]
              if m and m.group(1) != team and m.group(1).startswith(team + '-')]
    tasks = [t for t in tasks if t[1] == 'any' or t[1] in recs
             or (t[1].startswith(team + '-') and not any(t[1].startswith(o + '-') for o in others))]
done_ids = {t[0] for t in tasks if t[2]}
total, done = len(tasks), len(done_ids)
credit, est, used = 0, 0, set()
for title, r in recs.items():
    if r['state'] == 'FINISHED' or r['ms'] == 'reported' or r['pct'] < 0:
        continue
    mine = [t for t in tasks if not t[2] and t[1] in (title, 'any')]
    m = re.match(r'\s*(T\d+):', r['step'])
    pick = [t for t in mine if m and t[0] == m.group(1)] or [t for t in mine if t[1] == title]
    if pick and pick[0][0] not in used:
        used.add(pick[0][0]); credit += r['pct'] * 10; est = 1
pct = (done * 1000 + credit) // (total * 10) if total else -1
pct = min(pct, 100)
elapsed = max([r['elapsed'] for r in recs.values()] + [0])
eta = elapsed * (100 - pct) // pct if 5 <= pct < 100 and elapsed > 0 else -1
live = {t for t, r in recs.items() if r['state'] != 'FINISHED'}
pending = [t for t in tasks if not t[2]]
# a task a live teammate names in its status prefix ("T3: ...") is taken, whoever owns the line
claimed = {m.group(1): t for t, r in recs.items() if t in live
           for m in [re.match(r'\s*(T\d+):', r['step'])] if m}
holders = [claimed.get(t[0]) or (t[1] if t[1] in live else None)
           for t in pending if all(d in done_ids for d in t[3])]
unassigned = holders.count(None)
ready_owners = sorted({h for h in holders if h})
prs = set()
for rp in glob.glob(os.path.join(run, 'reports', '*.md')):
    try:
        prs |= set(re.findall(r'https://[^\s)>\]]+/pull/\d+', open(rp, encoding='utf-8', errors='replace').read()))
    except OSError:
        pass
if mode != 'json':
    print('\t'.join(map(str, ['@summary', done, total, pct, est, elapsed, eta, len(pending), unassigned, len(prs), ','.join(ready_owners)])))
    sys.exit(0)

# ---- json: the status --json contract (version 1). Keys are only ever added. ----
reg = sys.argv[4]
rows = {}   # title -> registry fields; last row wins, the dash monitor is not a teammate
try:
    for l in open(reg, encoding='utf-8', errors='replace'):
        c = l.rstrip('\n').split(' ', 10)
        if len(c) < 4 or c[2] == 'dash':
            continue
        c += ['-'] * (11 - len(c))
        rows[c[3]] = dict(backend=c[0], ref=c[1], layout=c[2], model=c[4], submodel=c[5],
                          session_id=c[9], cwd=c[10])
except OSError:
    pass
def dash(v):
    return None if v in ('', '-') else v
def mtime(p):
    try: return int(os.stat(p).st_mtime)
    except OSError: return None
def branch(cwd):
    # Cheap: read HEAD through the worktree's .git file; no git process per tick.
    try:
        g = os.path.join(cwd, '.git')
        if os.path.isfile(g):
            g = open(g, encoding='utf-8').read().split('gitdir:', 1)[1].strip()
            g = g if os.path.isabs(g) else os.path.join(cwd, g)
        head = open(os.path.join(g, 'HEAD'), encoding='utf-8').read().strip()
        return head[len('ref: refs/heads/'):] if head.startswith('ref: refs/heads/') else None
    except (OSError, IndexError):
        return None
def task_of(title, r):
    mine = [t for t in tasks if not t[2] and t[1] in (title, 'any')]
    m = re.match(r'\s*(T\d+):', r['step'])
    pick = [t for t in mine if m and t[0] == m.group(1)] or [t for t in mine if t[1] == title]
    return pick[0][0] if pick else (m.group(1) if m else None)
mates = []
for title, r in recs.items():
    g = rows.get(title, {})
    cwd = dash(g.get('cwd', '-'))
    rp = os.path.join(run, 'reports', r['role'] + '.md') if run != '-' else ''
    sp = os.path.join(run, 'status', r['role'] + '.txt') if run != '-' else ''
    mates.append(dict(
        role=r['role'], title=title, state=r['state'], milestone=r['ms'],
        step=None if r['step'] == '-' else r['step'], pct=None if r['pct'] < 0 else r['pct'],
        age_min=None if r['age'] < 0 else r['age'],
        elapsed_min=None if r['elapsed'] < 0 else r['elapsed'],
        note=r['note'] or None, task=task_of(title, r),
        backend=dash(g.get('backend', '-')), ref=dash(g.get('ref', '-')),
        layout=dash(g.get('layout', '-')), model=dash(g.get('model', '-')),
        submodel=dash(g.get('submodel', '-')), session_id=dash(g.get('session_id', '-')),
        cwd=cwd, branch=branch(cwd) if cwd and '/.team/worktrees/' in cwd else None,
        report=rp if rp and os.path.isfile(rp) else None, report_mtime=mtime(rp) if rp else None,
        status_mtime=mtime(sp) if sp else None,
        event_state=dash(r['evs']), event_age_s=None if r['eva'] < 0 else r['eva'],
        open_tool=dash(r['evt']),
        step_k=None if r['sk'] < 0 else r['sk'], step_n=None if r['sn'] < 0 else r['sn']))
def split_rest(rest):
    parts = re.split(r'\s+[—–-]+\s+(owns|needs):\s*', rest)
    out = dict(scope=parts[0].strip() or None, owns=None)
    for k, v in zip(parts[1::2], parts[2::2]):
        if k == 'owns':
            out['owns'] = v.strip() or None
    return out
tlist = []
for t in tasks:
    sr = split_rest(t[4])
    tlist.append(dict(id=t[0], owner=t[1], done=t[2], needs=t[3],
                      ready=(not t[2]) and all(d in done_ids for d in t[3]), **sr))
# The bar the classic frame draws (_ST_FRAME_PY keeps the same rule): overall task progress when
# tasks.md has task lines; else the average self-reported % (reported/finished = 100), else
# reported/total. bar_est marks a self-reported estimate (the `~`).
eff = [100 if (r['ms'] == 'reported' or r['state'] == 'FINISHED') else r['pct']
       for r in recs.values() if (r['ms'] == 'reported' or r['state'] == 'FINISHED' or r['pct'] >= 0)]
use_avg = any(r['pct'] >= 0 for r in recs.values()) and bool(eff)
if total > 0 and pct >= 0:
    bar_pct, bar_est = pct, bool(est)
else:
    nrep = sum(1 for r in recs.values() if r['ms'] == 'reported' or r['state'] == 'FINISHED')
    bar_pct = (sum(eff) // len(eff)) if use_avg else ((100 * nrep // len(recs)) if recs else 0)
    bar_est = use_avg
print(json.dumps(dict(
    version=1, team=team, run=None if run == '-' else run, now=int(time.time()),
    summary=dict(done=done, total=total, pct=pct, est=bool(est), elapsed_min=elapsed,
                 eta_min=eta, pending=len(pending), unassigned=unassigned, prs=len(prs),
                 ready_owners=ready_owners, bar_pct=bar_pct, bar_est=bar_est),
    prs=sorted(prs), teammates=mates, tasks=tlist), ensure_ascii=False))
PY
_st_summary() { python3 -I -c "$_ST_SUMMARY_PY" "${1:--}" "${2:-}"; }
# _st_json <run-dir> <registry> <team>: teammate records on stdin -> the status --json document
_st_json() { python3 -I -c "$_ST_SUMMARY_PY" "${1:--}" "$3" json "$2"; }

# ---------------------------------------------------------------------------
# Frame rendering: a pure function of records + width + colour + charset.
# The python3 formatter measures display width (unicodedata.east_asian_width),
# truncates on grapheme-cluster boundaries and paints the shared palette. Its
# header carries the literal @@CLOCK@@ so frames compare equal across ticks.
# ---------------------------------------------------------------------------

read -r -d '' _ST_FRAME_PY <<'PY' || true
import os, re, sys, unicodedata

# argv: team width color(0|1) ascii(0|1); stdin: TSV records
# role  title  state  milestone  step  age_min(-1 = none)  note
team, width, color, ascii_ = sys.argv[1], int(sys.argv[2]), sys.argv[3] == '1', sys.argv[4] == '1'
keys = len(sys.argv) > 5 and sys.argv[5] == '1'
sys.stdin.reconfigure(encoding='utf-8', errors='replace')
sys.stdout.reconfigure(encoding='ascii' if ascii_ else 'utf-8', errors='replace')

PAL = {'alert': (0xFF, 0x45, 0x3A), 'active': (0xAF, 0x52, 0xDE),
       'done': (0x30, 0xD1, 0x58), 'dim': (0x8E, 0x8E, 0x93)}
#        token        utf8 ascii  word           role
STATES = {'PERMISSION':('⊘', '!', 'permission',  'alert'),
          'WAITING':   ('⏸', '!', 'waiting',     'alert'),
          'MODEL_GONE':('⚠', 'M', 'model gone',  'alert'),
          'DEAD':      ('✗', 'x', 'dead',        'alert'),
          'STALLED':   ('⧗', '~', 'stalled?',    'alert'),
          'WORKING':   ('◐', '*', 'working',     'active'),
          'IDLE':      ('◌', '-', 'idle',        'dim'),
          'UNKNOWN':   ('?', '?', 'unknown',     'dim'),
          'FINISHED':  ('✓', '+', 'finished',    'done')}
ORDER = list(STATES)  # alerts first (most urgent first), then working, unknown, finished
HINT = {'PERMISSION': 'approve it in its pane', 'WAITING': 'answer it in its pane', 'MODEL_GONE': 'model no longer offered',
        'DEAD': 'pane gone; respawn or check',
        'STALLED': 'no update; maybe a permission prompt'}

def paint(s, role):
    if not color or not s:
        return s
    r, g, b = PAL[role]
    return f'\x1b[38;2;{r};{g};{b}m{s}\x1b[0m'

def cw(ch):
    if unicodedata.combining(ch) or ch in '‍︎️' or unicodedata.category(ch) in ('Mn', 'Me', 'Cf'):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1

def dw(s):
    return sum(cw(c) for c in s)

def clusters(s):
    # A cluster is a base char plus following zero-width chars (combining marks, ZWJ
    # and what it joins, variation selectors) — truncation never splits one.
    out, join = [], False
    for c in s:
        if out and (cw(c) == 0 or join):
            out[-1] += c
        else:
            out.append(c)
        join = c == '‍'
    return out

def fit(s, w):
    """Truncate to display width w (ellipsis included), then pad to exactly w."""
    if w <= 0:
        return ''
    if dw(s) > w:
        ell = '~' if ascii_ else '…'
        acc = ''
        for cl in clusters(s):
            if dw(acc) + dw(cl) > w - 1:
                break
            acc += cl
        s = acc + ell
    return s + ' ' * (w - dw(s))

def age(m):
    m = int(m)
    if m < 0:
        return '-'
    return f'{m}m' if m < 60 else f'{m // 60}h{m % 60:02d}m'

def asciify(s):
    # Non-UTF-8 locale: fold accents (ç -> c), replace anything else with '?' so the
    # width measured is the width printed.
    s = ''.join(c for c in unicodedata.normalize('NFKD', s) if not unicodedata.combining(c))
    return ''.join(c if ord(c) < 128 else '?' for c in s)

recs = []
S = None   # @summary from _st_summary: the one source of overall % and team ETA
for line in sys.stdin:
    if ascii_:
        line = asciify(line)
    f = line.rstrip('\n').split('\t')
    if f[0] == '@summary' and len(f) >= 10:
        try:
            S = dict(zip(('done', 'total', 'pct', 'est', 'elapsed', 'eta', 'pending',
                          'unassigned', 'prs'), map(int, f[1:10])))
            S['ready'] = set(f[10].split(',')) if len(f) > 10 else set()
        except ValueError:
            S = None
        continue
    if len(f) < 7 or f[2] not in STATES:
        continue
    def num(i):
        try:
            return int(f[i])
        except (IndexError, ValueError):
            return -1
    recs.append(dict(role=f[0], title=f[1], state=f[2], ms=f[3], step=f[4],
                     age=age(f[5]), note=('' if f[6] == '-' else f[6]),
                     pct=num(7), elapsed=num(8)))

def eta_of(r):
    # Linear extrapolation of a SELF-REPORTED percentage: a guess on a guess.
    # Rendered with a leading ~ and only when the teammate reported a %.
    if r['pct'] <= 0 or r['pct'] >= 100 or r['elapsed'] < 0:
        return ''
    return '~' + age(r['elapsed'] * (100 - r['pct']) // r['pct'])

def bar_of(r, w=5):
    if r['pct'] < 0:
        return ' ' * (w + 5)
    full, empty = ('#', '-') if ascii_ else ('█', '░')
    fl = w * r['pct'] // 100
    return (paint(full * fl, 'done') + paint(empty * (w - fl), 'dim')
            + f"{r['pct']}%".rjust(5))

def sym(st):
    u, a, word, role = STATES[st]
    return (a if ascii_ else u), word, role

total = len(recs)
done = sum(1 for r in recs if r['ms'] == 'reported' or r['state'] == 'FINISHED')
sep = ' - ' if ascii_ else ' · '
# The clock (8 cols once bash substitutes @@CLOCK@@) is reserved first; the team
# name gives way, and this line is exempt from clip() so the placeholder stays whole.
tasks_mode = bool(S) and S['total'] > 0 and S['pct'] >= 0
head = (f"{team}{sep}{S['done']}/{S['total']} tasks{sep}" if tasks_mode
        else f'{team}{sep}{done}/{total} reported{sep}')
if dw(head) > width - 8:
    head = fit(head, width - 9).rstrip() + ' '
out = [head + '@@CLOCK@@']
# The bar prefers the team's AVERAGE self-reported progress over the share of
# teammates that have reported: 4 teammates at 80% is not "0% done". A reported
# or finished teammate counts as 100. Falls back to reported/total when nobody
# self-reports a %, so a team that reports none renders exactly as before.
eff = [100 if (r['ms'] == 'reported' or r['state'] == 'FINISHED') else r['pct']
       for r in recs if (r['ms'] == 'reported' or r['state'] == 'FINISHED' or r['pct'] >= 0)]
use_avg = any(r['pct'] >= 0 for r in recs) and bool(eff)
pct = (sum(eff) // len(eff)) if use_avg else ((100 * done // total) if total else 0)
suffix = ''
if tasks_mode:
    # Overall task progress wins: done tasks plus each open task's owner-reported %.
    pct, use_avg = S['pct'], bool(S['est'])
    if S['eta'] >= 0:
        suffix = f"{sep}ETA ~{age(S['eta'])}"
label = ('  ~' if use_avg else '  ') + f'{pct}%' + suffix
# The % and ETA never truncate: the bar gives way first, down to nothing.
barw = max(0, min(20, width - dw(label)))
filled = barw * pct // 100
full, empty = ('#', '-') if ascii_ else ('█', '░')
# '~' marks a self-reported estimate, the same convention the ETA column uses.
out.append(paint(full * filled, 'done') + paint(empty * (barw - filled), 'dim') + label)
out.append('')

# An idle teammate while a ready task has no owner, or while it holds a ready task itself, is the waste the user cares about.
if S and (S['unassigned'] > 0 or S['ready']):
    for r in recs:
        if r['state'] == 'IDLE' and (S['unassigned'] > 0 or r['title'] in S['ready']):
            r['note'], r['alert'] = 'idle with work pending', True
alerts = [r for r in recs if STATES[r['state']][3] == 'alert' or r.get('alert')]
# Finished teammates have no pane; they fold into one line under the live rows.
finished = [r for r in recs if r['state'] == 'FINISHED']
rest = [r for r in recs if r not in alerts and r['state'] != 'FINISHED']
alerts.sort(key=lambda r: ORDER.index(r['state']))
rest.sort(key=lambda r: ORDER.index(r['state']))

# Row keys in display order (alerts first). Written out so the monitor's input
# loop dispatches on the same ordering the frame shows -- no duplicated sort.
for i, r in enumerate(alerts + rest, 1):
    r['key'] = i if i < 10 else ''
rolew = min(18, max([dw(r['role']) for r in recs] + [4]))

if alerts:
    hdr = ('!' if ascii_ else '⚠') + f' NEEDS YOU ({len(alerts)})'
    out.append(paint(hdr, 'alert'))
    agew = max(dw(r['age']) for r in alerts)
    wordw = max(dw(sym(r['state'])[1]) for r in alerts)
    # 4 indent + glyph + space + role + 2 + word + 2 + age: role shrinks before word or age
    arolew = max(3, min(rolew, width - (4 + 2 + 2 + wordw + 2 + agew)))
    for r in alerts:
        s, word, role = sym(r['state'])
        detail = r['note'] or (r['step'] if r['step'] != '-' else '') or HINT.get(r['state'], '')
        msg = f'{word}{sep}{detail}'
        msgw = width - (4 + 2 + arolew + 2 + 2 + agew)
        if dw(msg) > msgw:
            msg = word if msgw < dw(word) + dw(sep) + 4 else msg
        line = (f"[{r['key']}] " if keys else '    ')
        line += paint(s, 'alert') + ' ' + fit(r['role'], arolew) + '  '
        r['line'] = len(out) + 1
        line += fit(msg, max(msgw, dw(word))) + '  ' + r['age'].rjust(agew)
        out.append(line.rstrip())
    out.append('')

if rest:
    def label(r):
        s, word, _ = sym(r['state'])
        if r['state'] == 'WORKING' and r['ms'] in ('spawned', 'investigating', 'drafting'):
            word = r['ms']
        return s, word
    labels = [label(r) for r in rest]
    statew = max([dw(s + ' ' + w) for s, w in labels] + [5])
    agew = max([dw(r['age']) for r in rest] + [3])
    # PROGRESS/ETA appear only when a teammate actually self-reported a %, so a
    # team that reports none renders exactly as before.
    # Reserve PROGRESS/ETA only while ROLE and STATE stay readable. A fixed
    # width gate was wrong: a teammate pane in the default grid is ~80 cols, so
    # an 84-col gate hid the ETA almost always. STEP absorbs what is left and
    # drops itself (show_step) when it gets too thin.
    base = 4 + 2 + 2 + agew + 8 + 12   # prefix + gaps + AGE + min ROLE + min STATE
    progw = 10 if (any(r['pct'] >= 0 for r in rest) and width - base >= 12) else 0
    etaw = 6 if (progw and any(eta_of(r) for r in rest)
                 and width - (base + 12) >= 8) else 0
    extra = progw + (2 if progw else 0) + etaw + (2 if etaw else 0)
    # role shrinks first (to 3), then the state word, so ROLE + STATE + AGE survive
    trolew = max(3, min(rolew, width - (4 + 2 + statew + 2 + agew + extra)))
    statew = max(3, min(statew, width - (4 + trolew + 2 + 2 + agew + extra)))
    stepw = width - (4 + trolew + 2 + statew + 2 + 2 + agew + extra)
    show_step = width >= 60 and stepw >= 8
    head = '    ' + fit('ROLE', trolew) + '  ' + fit('STATE', statew) + '  '
    head += (fit('STEP', stepw) + '  ' if show_step else '')
    head += (fit('PROGRESS', progw) + '  ' if progw else '')
    head += ('ETA'.rjust(etaw) + '  ' if etaw else '') + 'AGE'.rjust(agew)
    out.append(paint(head.rstrip(), 'dim'))
    for r, (s, word) in zip(rest, labels):
        role = STATES[r['state']][3]
        step = r['step']
        if progw and r['pct'] >= 0:   # the PROGRESS column already shows the self-reported %
            step = re.sub(r'\s*[·-]\s*\d{1,3}%\s*$', '', step) or '-'
        if r['note']:
            step = r['note'] if step == '-' else f"{r['note']}{sep}{step}"
        line = (f"[{r['key']}] " if keys else '  ' + ('-' if ascii_ else '·') + ' ')
        line += fit(r['role'], trolew) + '  '
        r['line'] = len(out) + 1
        line += paint(s, role) + ' ' + fit(word, statew - dw(s) - 1) + '  '
        line += (fit(step, stepw) + '  ' if show_step else '')
        line += (bar_of(r) + '  ' if progw else '')
        line += (eta_of(r).rjust(etaw) + '  ' if etaw else '') + r['age'].rjust(agew)
        out.append(line.rstrip())

if finished or (S and S['pending']):
    out.append('')
if finished:
    fl = ('+' if ascii_ else '✓') + f' {len(finished)} finished'
    if S and S['prs']:
        fl += f"{sep}{S['prs']} PR" + ('' if S['prs'] == 1 else 's')
    out.append('  ' + paint(fl, 'done'))
if S and S['pending']:
    out.append('  ' + paint(f"backlog: {S['pending']} pending{sep}{S['unassigned']} unassigned", 'dim'))

def clip(line):
    # Last guard: no line wider than the pane. Escape sequences cost no width;
    # cut on a cluster boundary and close any open colour.
    vis, res, i = 0, '', 0
    while i < len(line):
        if line[i] == '\x1b':
            j = line.index('m', i) + 1
            res += line[i:j]; i = j; continue
        cl = line[i]; i += 1
        while i < len(line) and line[i] != '\x1b' and cw(line[i]) == 0:
            cl += line[i]; i += 1
        if vis + dw(cl) > width:
            return res + ('\x1b[0m' if color else '')
        res += cl; vis += dw(cl)
    return res

km = os.environ.get('TEAM_KEYMAP_OUT')
if km:
    try:
        with open(km, 'w') as fh:
            for r in alerts + rest:
                fh.write(f"{r.get('key') or ''}\t{r['role']}\t{r['state']}"
                         f"\t{r.get('line') or 0}\n")
    except OSError:
        pass

# Keybinding hint: a keyboard feature the user cannot see is a keyboard feature
# they will not use. Only in the interactive monitor, and only if a row has a key.
nkeys = sum(1 for r in (alerts + rest) if r.get('key'))
if keys and nkeys:
    rng = '1' if nkeys == 1 else f'1-{nkeys}'
    out.append('')
    out.append(paint(f'  {rng} focus pane{sep}r refresh{sep}q quit', 'dim'))

print('\n'.join([out[0]] + [clip(l) for l in out[1:]]))
PY

# _st_cols: terminal width. TEAM_COLS wins (tests), else `tput cols` — never $COLUMNS,
# which is 0 in non-interactive bash. tput prints 80 when stdout is not a tty.
_st_cols() {
  local c=${TEAM_COLS:-}
  case $c in ''|*[!0-9]*) c=$(tput cols 2>/dev/null || true) ;; esac
  case $c in ''|*[!0-9]*) c=80 ;; esac
  [ "$c" -lt 20 ] && c=20
  [ "$c" -gt 400 ] && c=400
  echo "$c"
}

# _st_color_on: 0 when colour applies. Evaluate where stdout is the real output,
# never inside $(...), where [ -t 1 ] is always false.
_st_color_on() {
  [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != dumb ] \
    && { [ -t 1 ] || [ "${TEAM_FORCE_COLOR:-}" = 1 ]; }
}

# _st_ascii: 0 when the locale is not UTF-8 (first of LC_ALL, LC_CTYPE, LANG set wins)
_st_ascii() {
  local loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  case $loc in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return 1 ;; esac
  return 0
}

# _st_frame <team> <cols> <color 0|1> <ascii 0|1>: records on stdin -> frame on stdout
_st_frame() {
  python3 -I -c "$_ST_FRAME_PY" "$@"
}

# _st_run_of <team>: the run dir the team's records read. Registry col 7 (the run dir spawn
# recorded; last row = newest when a slug is reused) wins over the newest .team/runs/*-<team>.
_st_run_of() {
  local team=$1 reg run rd
  reg=$(_reg "$team")
  run=$(ls -dt "$(_root)/.team/runs/"*"-$team" 2>/dev/null | head -1 || true)
  rd=$(awk 'NF>=7 && $7!="-" {r=$7} END{print r}' "$reg" 2>/dev/null || true)
  [ -n "$rd" ] && [ -d "$rd" ] && run=$rd
  printf '%s\n' "$run"
}

# _st_collect <team> [--records]: resolve run dir + lead pane, print the team's records and
# the @summary record (--records: the teammate records only). Exit 3 when the team has no registry.
_st_collect() {
  local team=$1 only=${2:-}
  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || return 3
  local run; run=$(_st_run_of "$team")

  # Lead's pane_ref, for the "in the lead's pane" note. Inside the monitor pane
  # _lead_pane would resolve to the monitor itself, so sub_monitor bakes
  # TEAM_LEAD_PANE into the pane's command.
  local leadpane=
  if command -v cmux >/dev/null && [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
    if [ -n "${TEAM_LEAD_PANE:-}" ]; then
      leadpane="$TEAM_LEAD_PANE"
    else
      local lp; lp=$(_lead_pane 2>/dev/null || true)
      leadpane="${lp%% *}"
    fi
  fi
  local recs; recs=$(_st_records "$reg" "$run" "$leadpane" "$team")
  [ -z "$recs" ] || printf '%s\n' "$recs"
  [ "$only" = --records ] && return 0
  printf '%s\n' "$recs" | _st_summary "${run:--}" "$team" 2>/dev/null || true
}

# _st_tui_pick: sets _ST_TUI to the command that runs the full-screen TUI monitor
# (scripts/monitor_tui.py, Textual) and returns 0; returns 1 for the classic monitor.
# TEAM_MONITOR_UI=classic forces the classic one. Textual already importable by python3
# wins; else `uv run --script` resolves the script's inline dependency on first use.
_ST_TUI=()
_st_tui_pick() {
  _ST_TUI=()
  local py="$here/monitor_tui.py"
  [ "${TEAM_MONITOR_UI:-auto}" != classic ] && [ -f "$py" ] || return 1
  if python3 -c 'import sys, textual; sys.exit(not 1 <= int(textual.__version__.split(".")[0]) <= 8)' 2>/dev/null; then
    _ST_TUI=(python3 "$py")
  elif command -v uv >/dev/null 2>&1; then
    _ST_TUI=(uv run --quiet --script "$py")
  else
    return 1
  fi
}

# _st_close_self: close the pane this monitor runs in (tmux pane or cmux surface).
_st_close_self() {
  if [ "$(_mux)" = tmux ] && [ -n "${TMUX_PANE:-}" ]; then
    _tmux kill-pane -t "$TMUX_PANE" >/dev/null 2>&1 || true
  elif [ -n "${CMUX_SURFACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then
    cmux close-surface --force --surface "$CMUX_SURFACE_ID" >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# sub_status [--watch | --json [--sync]] <team>
# One frame: summary + progress bar, a NEEDS YOU block only when something needs
# attention, then the table. --watch re-reads the width every tick, repaints only
# when the frame changed, syncs the sidebar from the same records, and exits 0
# once `close` removes the registry. In a terminal, --watch runs the TUI monitor
# (monitor_tui.py) when Textual or uv is available, and falls back to this loop.
# --json prints the same state as one JSON document (the TUI's only data source);
# --sync also updates the sidebar from it, as one --watch tick does.
# Exit: 0 ok, 3 no registry
# ---------------------------------------------------------------------------

sub_status() {
  local watch= json= sync=
  while :; do case ${1:-} in
    --watch) watch=1; shift ;; --json) json=1; shift ;; --sync) sync=1; shift ;;
    *) break ;;
  esac; done
  local team=${1:?team}
  local reg; reg=$(_reg "$team")
  [ -f "$reg" ] || { printf 'no teammates recorded for %s\n' "$team" >&2; return 3; }

  if [ -n "$json" ]; then
    local run recs; run=$(_st_run_of "$team")
    recs=$(_st_collect "$team" --records) || return 3
    if [ -n "$sync" ]; then
      _st_sync_apply "$team" "$recs"$'\n'"$(printf '%s\n' "$recs" | _st_summary "${run:--}" "$team" 2>/dev/null)" || true
    fi
    printf '%s\n' "$recs" | _st_json "${run:--}" "$reg" "$team"
    return 0
  fi

  local color=0 ascii=0
  _st_color_on && color=1
  _st_ascii && ascii=1

  if [ -z "$watch" ]; then
    local frame; frame=$(_st_collect "$team" | _st_frame "$team" "$(_st_cols)" "$color" "$ascii")
    printf '%s\n' "${frame/@@CLOCK@@/$(date '+%H:%M:%S')}"
    return 0
  fi

  local interval=${TEAM_STATUS_INTERVAL:-30}
  case $interval in *[!0-9]*|'') interval=30 ;; esac
  [ "$interval" -lt 1 ] && interval=1
  # Interactive only when stdin is a tty: `read -t` on a pipe returns EOF
  # immediately, which would spin the loop instead of waiting.
  local keys=0
  [ -t 0 ] && keys=1

  # The TUI monitor, when this is a real terminal and Textual/uv can run it. Its exit
  # code says why it stopped: 0 the user quit, 4 every teammate finished (close this pane,
  # as the classic loop does), 5 the team was closed. Anything else (no network for uv's
  # first install, a crash) falls through to the classic loop below.
  if [ "$keys" = 1 ] && [ -t 1 ] && _st_tui_pick; then
    local trc=0
    TEAM_SCRIPT="$here/team.sh" "${_ST_TUI[@]}" --team "$team" --team-sh "$here/team.sh" || trc=$?
    case $trc in
      0|5) return 0 ;;
      4) _st_close_self; return 0 ;;
      *) printf 'monitor: the TUI stopped (exit %s); using the classic monitor\n' "$trc" >&2; sleep 2 ;;
    esac
  fi
  local km= mouse=0
  if [ "$keys" = 1 ]; then
    km=$(mktemp "${TMPDIR:-/tmp}/team-keymap.XXXXXX") || km=
    # Mouse capture takes click-drag away from the terminal's own text selection
    # (shift+drag still selects). TEAM_MONITOR_MOUSE=0 opts out and keeps the keys.
    [ "${TEAM_MONITOR_MOUSE:-1}" != 0 ] && mouse=1
    # Leave the terminal as we found it on every exit path, mouse mode included.
    # The trap runs after sub_status returned, when its locals are gone (set -u would kill it and
    # turn a clean exit into 1), so the values are baked into the string now.
    trap "rm -f -- $(printf %q "$km") 2>/dev/null
          [ $mouse = 1 ] && printf '\\033[?1006l\\033[?1000l'
          stty echo 2>/dev/null; printf '\\033[?25h'" EXIT INT TERM
    [ "$mouse" = 1 ] && printf '\033[?1000h\033[?1006h'
    # Input arriving while we render (between `read` calls) would otherwise be
    # echoed into the frame by the tty driver -- mouse reports as raw escapes.
    stty -echo 2>/dev/null || true
  fi

  # Auto-close: when every teammate reaches `finished` the pane has nothing left
  # to show. Only on the TRANSITION -- a team that was already finished when the
  # monitor opened stays open, so asking for the pane never makes it vanish.
  local autoclose=1 was_all_fin=
  [ "${TEAM_MONITOR_AUTOCLOSE:-1}" = 0 ] && autoclose=0

  local prev= recs frame k
  while [ -f "$reg" ]; do
    recs=$(_st_collect "$team" || true)
    frame=$(printf '%s\n' "$recs" \
      | TEAM_KEYMAP_OUT="$km" _st_frame "$team" "$(_st_cols)" "$color" "$ascii" "$keys")
    if [ "$frame" != "$prev" ]; then
      clear || true
      printf '%s\n' "${frame/@@CLOCK@@/$(date '+%H:%M:%S')}"
      prev=$frame
    elif [ -t 1 ]; then
      # Unchanged frame: rewrite only the summary line so the clock shows the loop is alive
      local head=${frame%%$'\n'*}
      printf '\033[s\033[H%s\033[K\033[u' "${head/@@CLOCK@@/$(date '+%H:%M:%S')}"
    fi
    _st_sync_apply "$team" "$recs" || true

    # all finished? (non-empty record set, every row FINISHED)
    local allfin=
    if [ -n "$recs" ] && ! printf '%s\n' "$recs" | awk -F'\t' 'NF>=3 && $1!~/^@/ && $3!="FINISHED"{found=1} END{exit !found}'; then
      grep -qv '^@' <<<"$recs" && allfin=1
    fi
    if [ -n "$allfin" ] && [ -z "$was_all_fin" ] && [ "$autoclose" = 1 ] \
       && [ -n "${_ST_SAW_UNFINISHED:-}" ]; then
      printf '\n  all teammates finished — closing this pane.\n'
      printf '  (reopen with: team.sh monitor %s · keep it with TEAM_MONITOR_AUTOCLOSE=0)\n' "$team"
      sleep "${TEAM_MONITOR_CLOSE_GRACE:-4}"
      _st_close_self
      return 0
    fi
    [ -n "$allfin" ] && was_all_fin=1 || { was_all_fin=; _ST_SAW_UNFINISHED=1; }

    if [ "$keys" = 1 ]; then
      # The read timeout IS the refresh interval, so input never delays a repaint.
      k=
      if read -rsn1 -t "$interval" k 2>/dev/null; then
        case $k in
          q|Q) return 0 ;;
          r|R) prev= ;;
          [1-9]) _st_focus "$team" "$km" "$k" && prev= ;;
          $'\033')
            # Possible SGR mouse report: ESC [ < btn ; col ; row (M press | m release).
            local seq= c
            while read -rsn1 -t 0.2 c 2>/dev/null; do
              seq+=$c
              case $c in [Mm]) break ;; esac
              [ ${#seq} -lt 24 ] || break
            done
            _st_click "$team" "$km" "$seq" && prev=
            ;;
        esac
      fi
    else
      sleep "$interval"
    fi
  done
}

# _st_click <team> <keymap> <seq>: map an SGR mouse release to the row on that
# terminal line and focus it. Ignores presses (so one click acts once), drags and
# wheel events. Returns 1 when the click landed on no row.
_st_click() {
  local team=$1 km=$2 seq=$3
  [ -n "$km" ] && [ -f "$km" ] || return 1
  # Act on release only: "[<0;COL;ROWm"
  case $seq in "[<0;"*m) ;; *) return 1 ;; esac
  local body=${seq#"[<0;"}; body=${body%m}
  local row=${body#*;}
  case $row in ''|*[!0-9]*) return 1 ;; esac
  local role state
  role=$(awk -F'\t' -v r="$row" '$4==r{print $2; exit}' "$km")
  state=$(awk -F'\t' -v r="$row" '$4==r{print $3; exit}' "$km")
  [ -n "$role" ] || return 1
  _st_focus_role "$team" "$role" "$state"
}

# _st_focus <team> <keymap> <key>: focus the pane of the row that key labels.
# Returns 1 (no repaint) when the key names no row or the teammate has no pane.
_st_focus() {
  local team=$1 km=$2 key=$3
  [ -n "$km" ] && [ -f "$km" ] || return 1
  local role state
  role=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$km")
  state=$(awk -F'\t' -v k="$key" '$1==k{print $3; exit}' "$km")
  [ -n "$role" ] || return 1
  _st_focus_role "$team" "$role" "$state"
}

# _st_focus_role <team> <role> <state>: the one focus path, shared by key and click.
_st_focus_role() {
  local team=$1 role=$2 state=$3
  # A finished teammate has no session and no pane; say so instead of a bare exit 3.
  if [ "$state" = FINISHED ]; then
    printf '\n  %s has finished — no pane to focus. Its report is in the run dir.\n' "$role"
    sleep 2
    return 0
  fi
  local script="${TEAM_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/../team.sh}"
  bash "$script" show "$team" "$role" 2>&1 | tail -2 || true
  sleep 1
  return 0
}

# ---------------------------------------------------------------------------
# sub_monitor <team>
# Opens one auto-refreshing status pane with layout=dash (not a teammate).
# Requires cmux with workspace context (_require_cmux ws).
# Exit: 0 ok, 1 already-running, 3 cmux unavailable
# ---------------------------------------------------------------------------

sub_monitor() {
  local team=${1:?team}

  # A pane-capable backend is required: cmux (recommended) or tmux (lib/mux.sh).
  _mux_need ws
  local be; be=$(_mux)

  local reg; reg=$(_reg "$team")
  local interval=${TEAM_STATUS_INTERVAL:-30}
  case ${interval:-} in *[!0-9]*|'') interval=30 ;; esac
  local title="$team-monitor"

  # Capture lead's pane_ref NOW (running as the lead), for the monitor pane's
  # command (inside it, _lead_pane would resolve to the monitor itself).
  local lead_pane=
  if [ "$be" = tmux ]; then lead_pane=$TMUX_PANE
  else local lp; lp=$(_lead_pane 2>/dev/null || true); lead_pane="${lp%% *}"; fi
  local lead_pane_q; lead_pane_q=$(printf '%q' "$lead_pane")

  # Acquire registry lock: makes single-instance check + append atomic vs spawn.
  # _lock sets an EXIT trap for cleanup; do NOT set another EXIT trap after this.
  _lock "$reg"

  # Single-instance guard: refuse if a live dash row with this title exists.
  # Dead rows (pane manually closed) are pruned so a fresh monitor can open.
  if [ -f "$reg" ]; then
    local ex_row
    ex_row=$(awk -v t="$title" '$4==t && $3=="dash"{print $0; exit}' "$reg" 2>/dev/null || true)
    if [ -n "$ex_row" ]; then
      local ex_backend ex_ref
      ex_backend=$(awk '{print $1}' <<<"$ex_row")
      ex_ref=$(awk '{print $2}' <<<"$ex_row")
      if _alive "$ex_backend" "$ex_ref" 2>/dev/null; then
        printf 'monitor: dashboard %q already running for team %q\n' "$title" "$team" >&2
        printf '  Stop it first: team.sh close %q\n' "$team" >&2
        return 1
      else
        # Dead row: prune in-place
        local prunetmp="$reg.pruning-$$"
        awk -v t="$title" '!($4==t && $3=="dash")' "$reg" > "$prunetmp" \
          && mv "$prunetmp" "$reg" || rm -f "$prunetmp"
      fi
    fi
  fi

  # The pane runs `status --watch`: the loop lives in real bash (sub_status) so it can
  # keep the previous frame and repaint only on change; it reads the width each tick,
  # syncs the sidebar, and exits when `close` removes the registry (no orphan
  # process). TEAM_LEAD_PANE is baked in for the "in the lead's pane" note.
  local team_q; team_q=$(printf '%q' "$team")
  local script_q; script_q=$(printf '%q' "$here/team.sh")
  local cmd="TEAM_MUX=$be TEAM_LEAD_PANE=$lead_pane_q TEAM_STATUS_INTERVAL=$interval bash $script_q status --watch $team_q"

  local ref
  ref=$(_mux_open dash - "$cmd" "$title") || { printf 'monitor: could not open the pane\n' >&2; return 1; }
  _be=$be _reg_add "$team" "$ref" dash "$title" - - -
  printf 'monitor pane: %s\n' "$title"
}

# ---------------------------------------------------------------------------
# sub_sync [--clear] <team>
# Update the lead workspace sidebar: status pill (team-<team>) + progress bar.
# --clear: remove the pill and progress bar (called when the team closes).
# Exit: always 0 (cmux errors warn only; use return, never exit).
# ---------------------------------------------------------------------------

sub_sync() {
  local clear=
  case "${1:-}" in --clear) clear=1; shift ;; esac
  local team=${1:?team}

  command -v cmux >/dev/null 2>&1 || return 0
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 0

  local ws="$CMUX_WORKSPACE_ID"
  local key="team-$team"  # per-team key prevents two teams clobbering each other

  if [ -n "$clear" ]; then
    cmux clear-status "$key" --workspace "$ws" >/dev/null 2>&1 || true
    # Only clear the progress bar if no other team-* key exists in this workspace.
    # clear-progress is workspace-wide; two teams sharing a workspace must not
    # wipe each other's bar.
    local other_key
    other_key=$(cmux list-status --workspace "$ws" 2>/dev/null \
      | grep -oE '^team-[^=]+' | grep -vF "$key" | head -1 || true)
    [ -z "$other_key" ] && cmux clear-progress --workspace "$ws" >/dev/null 2>&1 || true
    cmux log --source team --level info "team $team: closed" \
      --workspace "$ws" >/dev/null 2>&1 || true
    # Remove state file so a reuse of this slug starts fresh
    rm -f "$(dirname "$(_reg "$team")")/team-$team.sync" 2>/dev/null || true
    return 0
  fi

  local recs; recs=$(_st_collect "$team") || return 0
  _st_sync_apply "$team" "$recs"
}

# _st_sync_apply <team> <records>: pill + progress + transition log from _st_records
# output. Read-only towards teammates (decision 28): it only writes the sidebar and
# its own .sync state file, because the monitor pane and the lead both run it.
_st_sync_apply() {
  local team=$1 recs=$2
  command -v cmux >/dev/null 2>&1 || return 0
  [ -n "${CMUX_WORKSPACE_ID:-}" ] || return 0
  local ws="$CMUX_WORKSPACE_ID" key="team-$team"

  local total=0 reported=0 needs=0 started=
  # Team average of self-reported progress: a reported/finished teammate counts
  # as 100, a live one contributes its own % when it reported one. selfn > 0
  # means at least one real self-report, which is what switches the bar over.
  local pctsum=0 pctn=0 selfn=0
  local role title state ms _step _age _note pct
  local s_done= s_total= s_pct=-1 s_est=0
  while IFS=$'\t' read -r role title state ms _step _age _note pct _; do
    [ -n "$title" ] || continue
    if [ "$role" = @summary ]; then
      s_done=$title s_total=$state s_pct=$ms s_est=$_step; continue
    fi
    total=$((total + 1))
    { [ "$ms" = reported ] || [ "$state" = FINISHED ]; } && reported=$((reported + 1))
    [ "$ms" != spawned ] && started=1
    case $state in PERMISSION|WAITING|DEAD|MODEL_GONE|STALLED) needs=$((needs + 1)) ;; esac
    if [ "$ms" = reported ] || [ "$state" = FINISHED ]; then
      pctsum=$((pctsum + 100)); pctn=$((pctn + 1))
    elif [ -n "${pct:-}" ] && [ "$pct" != - ] && [ "$pct" -ge 0 ] 2>/dev/null; then
      pctsum=$((pctsum + pct)); pctn=$((pctn + 1)); selfn=$((selfn + 1))
    fi
  done <<<"$recs"

  # Phase, pill colour and log level move together (one palette with the pane)
  local phase pill_color level
  if [ "$total" -gt 0 ] && [ "$reported" -ge "$total" ]; then
    phase=done; pill_color=$_ST_C_DONE; level=success
  elif [ "$needs" -gt 0 ]; then
    phase="needs you"; pill_color=$_ST_C_ALERT; level=warning
  elif [ "$reported" -gt 0 ] || [ -n "$started" ]; then
    phase=working; pill_color=$_ST_C_ACTIVE; level=progress
  else
    phase=spawning; pill_color=$_ST_C_ACTIVE; level=progress
  fi

  # Progress fraction 0.0-1.0. Prefers the team average (see the loop above) so
  # the sidebar and the pane show the same number; falls back to reported/total.
  local frac="0.0" avg= 
  if [ "$selfn" -gt 0 ] && [ "$pctn" -gt 0 ]; then
    avg=$((pctsum / pctn))
  fi
  if [ -n "$avg" ] && command -v python3 >/dev/null 2>&1; then
    frac=$(python3 -c "print(f'{$avg/100:.2f}')" 2>/dev/null) || frac="0.0"
  elif [ "$total" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
    frac=$(python3 -c "print(f'{$reported/$total:.2f}')" 2>/dev/null) || frac="0.0"
  fi

  # '~' marks the average as self-reported; the hard N/M fact stays alongside it.
  local pill="$phase · $reported/$total reported"
  [ -n "$avg" ] && pill="$phase · ~$avg% · $reported/$total reported"
  # With a backlog, overall task progress (the pane's headline number) wins.
  if [ "${s_total:-0}" -gt 0 ] 2>/dev/null && [ "$s_pct" -ge 0 ] 2>/dev/null; then
    local t=; [ "$s_est" = 1 ] && t='~'
    pill="$phase · $t$s_pct% · $s_done/$s_total tasks"
    frac=$(python3 -c "print(f'{$s_pct/100:.2f}')" 2>/dev/null) || frac="0.0"
  fi

  # Update sidebar (never fatal; use per-team key and explicit workspace)
  cmux set-status "$key" "$pill" --icon sparkle --color "$pill_color" \
    --priority "$_ST_PILL_PRIORITY" --workspace "$ws" >/dev/null 2>&1 || true
  cmux set-progress "$frac" --label "$team" --workspace "$ws" >/dev/null 2>&1 || true

  # Transition logging. State file: line 1 = last pill, then "title<TAB>state<TAB>ms"
  # per teammate. Derived from _reg's directory so TEAM_REG_DIR overrides work in tests.
  local state_file; state_file="$(dirname "$(_reg "$team")")/team-$team.sync"
  local prev_pill="" prev_rows=""
  if [ -f "$state_file" ]; then
    prev_pill=$(head -1 "$state_file" 2>/dev/null || true)
    prev_rows=$(tail -n +2 "$state_file" 2>/dev/null || true)
  fi

  if [ "$pill" != "$prev_pill" ]; then
    cmux log --source team --level "$level" "$team: $pill" --workspace "$ws" >/dev/null 2>&1 || true
  fi

  local cur_rows="" prev pstate pms msg lvl
  while IFS=$'\t' read -r role title state ms _step _age _note; do
    [ -n "$title" ] && [ "$role" != @summary ] || continue
    cur_rows="${cur_rows}${title}"$'\t'"${state}"$'\t'"${ms}"$'\n'
    prev=$(awk -F'\t' -v t="$title" '$1==t {print; exit}' <<<"$prev_rows" 2>/dev/null || true)
    pstate=$(awk -F'\t' '{print $2}' <<<"$prev"); pms=$(awk -F'\t' '{print $3}' <<<"$prev")
    msg= lvl=
    if [ -z "$prev" ] || [ "$state" != "$pstate" ]; then
      case $state in
        PERMISSION) msg="waiting on a permission prompt" lvl=warning ;;
        WAITING)    msg="waiting (needs input)" lvl=warning ;;
        IDLE)       msg="idle (turn ended without a report)" lvl=info ;;
        STALLED)    msg="stalled?" lvl=warning ;;
        DEAD)       msg=dead lvl=error ;;
        MODEL_GONE) msg="model gone" lvl=error ;;
        FINISHED)   msg=finished lvl=success ;;
      esac
      [ -z "$prev" ] && [ -z "$msg" ] && msg=spawned lvl=progress
    fi
    if [ "$ms" = reported ] && [ "$pms" != reported ] && [ -z "$msg" ]; then
      msg=reported lvl=success
    fi
    [ -n "$msg" ] && { cmux log --source team --level "$lvl" "$title: $msg" \
      --workspace "$ws" >/dev/null 2>&1 || true; }
  done <<<"$recs"

  # Write current state (never fatal)
  { printf '%s\n' "$pill"; printf '%s' "$cur_rows"; } > "$state_file" 2>/dev/null || true
}
