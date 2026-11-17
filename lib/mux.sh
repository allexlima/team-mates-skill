#!/usr/bin/env bash
# lib/mux.sh — terminal multiplexer backend for team.sh: cmux (default, recommended) or tmux
# (fallback when the lead is not in cmux). Sourced by team.sh before lib/status.sh; functions only.
#
# A registry row's col 1 names its backend (cmux|tmux) and col 2 its ref (surface:N | %N), so one
# registry can hold both and every per-row action uses the row's own backend.
#   _mux                       -> cmux | tmux | none for NEW panes: TEAM_MUX, else cmux inside a
#                                 cmux pane, else tmux inside a tmux session
#   _tmux ARGS...              -> tmux, on the private socket TEAM_TMUX_SOCKET when set (tests)
#   _mux_need [ws]             -> exit 3 unless a backend is usable; ws: new panes can open here
#   _mux_open <right|down|tab|dash> <anchor|-> <cmd> <title>  -> prints the new ref; anchor - = the lead
#   _mux_close <backend> <ref> -> 0 closed or already gone; else prints the error, returns 1
#   _mux_titles                -> "<ref>TAB<title>TAB<type>" for every live surface/pane
#   _mux_focus <backend> <ref> -> brings a tmux pane forward (cmux focus stays in team.sh show)
# Requires team.sh: _require_cmux, _surface_titles, $sub (for messages).

_tmux() { tmux ${TEAM_TMUX_SOCKET:+-L "$TEAM_TMUX_SOCKET"} "$@"; }

_mux() {
  case ${TEAM_MUX:-} in cmux|tmux) echo "$TEAM_MUX"; return 0 ;; esac
  if [ -n "${CMUX_WORKSPACE_ID:-}" ] && command -v cmux >/dev/null 2>&1; then echo cmux
  elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then echo tmux
  else echo none; fi
}

_mux_none() {
  echo "team.sh: '$sub' needs a terminal multiplexer. cmux is recommended (brew install --cask cmux, https://www.cmux.dev/; run /team from a cmux pane). tmux works as a fallback: run /team inside a tmux session. --inline needs neither." >&2
  exit 3
}

_mux_need() {
  local be; be=$(_mux)
  if [ "${1:-}" = ws ]; then
    case $be in
      cmux) _require_cmux ws ;;
      tmux)
        command -v tmux >/dev/null 2>&1 || _mux_none
        [ -n "${TMUX_PANE:-}" ] || { echo "team.sh: '$sub' must run inside a tmux pane (TMUX_PANE is unset)." >&2; exit 3; } ;;
      *) _mux_none ;;
    esac
    return 0
  fi
  # Acting on recorded rows: cmux when it answers, else tmux when installed.
  case $be in
    cmux) _require_cmux ;;
    tmux) command -v tmux >/dev/null 2>&1 || _mux_none ;;
    *) if command -v cmux >/dev/null 2>&1; then _require_cmux
       elif ! command -v tmux >/dev/null 2>&1; then _mux_none; fi ;;
  esac
}

_mux_open() {
  local lay=$1 anchor=$2 cmd=$3 title=$4 out
  case $(_mux) in
    tmux)
      [ "$anchor" != - ] || anchor=$TMUX_PANE
      case $lay in
        tab) out=$(_tmux new-window -d -n "$title" -P -F '#{pane_id}' "$cmd") || return 1 ;;
        dash) out=$(_tmux split-window -d -v -l 30% -t "$anchor" -P -F '#{pane_id}' "$cmd") || return 1 ;;
        right) out=$(_tmux split-window -d -h -t "$anchor" -P -F '#{pane_id}' "$cmd") || return 1 ;;
        *) out=$(_tmux split-window -d -v -t "$anchor" -P -F '#{pane_id}' "$cmd") || return 1 ;;
      esac
      # Titles stick only while the program inside does not retitle the pane;
      # spawn disables Claude's own terminal titles for exactly this reason.
      _tmux select-pane -t "$out" -T "$title" >/dev/null 2>&1 || true
      echo "$out" ;;
    *)
      [ "$anchor" != - ] || anchor=$CMUX_SURFACE_ID
      case $lay in
        tab) out=$(cmux new-surface --type terminal --workspace "$CMUX_WORKSPACE_ID" --command "$cmd" --focus false) || return 1 ;;
        right) out=$(cmux new-split right --surface "$anchor" --command "$cmd" --focus false) || return 1 ;;
        *) out=$(cmux new-split down --surface "$anchor" --command "$cmd" --focus false) || return 1 ;;
      esac
      out=$(awk '{print $2}' <<<"$out")   # "OK surface:N ..."
      cmux rename-tab --surface "$out" "$title" >/dev/null
      echo "$out" ;;
  esac
}

_mux_close() {
  local err
  case $1 in
    tmux) err=$(_tmux kill-pane -t "$2" 2>&1 >/dev/null) && err=
          case $err in *"can't find"*|*"no server"*) err= ;; esac ;;
    cmux) err=$(cmux close-surface --surface "$2" --force 2>&1 >/dev/null) && err=
          case $err in *not_found*) err= ;; esac ;;
    *) err="unknown backend $1" ;;
  esac
  [ -z "$err" ] || { printf '%s\n' "$err"; return 1; }
}

_mux_titles() {
  if command -v cmux >/dev/null 2>&1 && [ "$(cmux ping 2>/dev/null)" = PONG ]; then
    _surface_titles || return 1
  fi
  if command -v tmux >/dev/null 2>&1; then
    _tmux list-panes -a -F '#{pane_id}	#{pane_title}	terminal' 2>/dev/null || true
  fi
}

_mux_focus() {
  _tmux select-window -t "$2" >/dev/null 2>&1 || true
  _tmux select-pane -t "$2" >/dev/null 2>&1
}
