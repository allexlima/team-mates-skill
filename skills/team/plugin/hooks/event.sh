#!/bin/sh
# Claude Code hook for /team: append one JSONL line {t, ev, tool, ntype, sub} to
# $TEAM_EVENTS_FILE. $1 is the event name, set per event in hooks.json.
# Never logs tool input, prompts or messages: each payload line is cut at
# "tool_input" and only short [A-Za-z0-9_.:-] values are kept. Always exits 0
# with no output, so it never changes a permission decision. sub is 1 when the event came
# from a subagent (a top-level agent_id before tool_input); the id itself is never logged.
f=${TEAM_EVENTS_FILE:-}
ev=$1
case $ev in ''|*[!A-Za-z]*) f= ;; esac
if [ -z "$f" ] || [ -L "$f" ] || [ ! -d "${f%/*}" ]; then cat >/dev/null; exit 0; fi
# No notion of nesting: a nested tool_name before tool_input would be logged; real payloads put it top-level first.
v='[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_.:-]\{1,128\}\)".*'
x=$(head -c 8192 | sed -n "1!q; s/\"tool_input\".*//; h; s/.*\"tool_name\"$v/,\"tool\":\"\1\"/p; g; s/.*\"notification_type\"$v/,\"ntype\":\"\1\"/p; g; s/.*\"agent_id\"[[:space:]]*:[[:space:]]*\".*/,\"sub\":1/p")
cat >/dev/null
set -f
# shellcheck disable=SC2086 # split $x into its fields on purpose; set -f stops globbing
set -- $x
(umask 077; printf '{"t":%s,"ev":"%s"%s%s}\n' "$(date +%s)" "$ev" "${1:-}" "${2:-}${3:-}" >> "$f") 2>/dev/null
exit 0
