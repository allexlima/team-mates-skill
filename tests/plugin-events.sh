#!/usr/bin/env bash
# Hermetic tests for the /team event plugin (skills/team/plugin): the hook
# writer must append one {t, ev, tool, ntype} line, never log tool input,
# and do nothing when TEAM_EVENTS_FILE is unset or unsafe.
#   bash tests/plugin-events.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
P="$HERE/skills/team/plugin"
H="$P/hooks/event.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$2"; fi; }

E="$W/events/r.jsonl"; mkdir -p "$W/events"
pre='{"session_id":"s","cwd":"/x\"tool_name\":\"Evil","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo sk-ant-SECRET","tool_name":"Leak","notification_type":"leak"},"tool_use_id":"u"}'
out=$(printf '%s' "$pre" | TEAM_EVENTS_FILE="$E" sh "$H" PreToolUse); rc=$?
check "exit 0, no stdout" '[ "$rc" = 0 ] && [ -z "$out" ]'
check "tool name kept" 'grep -q "\"ev\":\"PreToolUse\",\"tool\":\"Bash\"}" "$E"'
check "nothing from tool_input" '! grep -qE "SECRET|Leak|leak|Evil|command" "$E"'
case "$(ls -l "$E")" in -rw-------*) pass "new file is 0600" ;; *) fail "new file is 0600" "$(ls -l "$E")" ;; esac

printf '%s' '{"hook_event_name":"Notification","message":"Claude needs \"tool_name\":\"X\"","title":"t","notification_type":"permission_prompt"}' \
  | TEAM_EVENTS_FILE="$E" sh "$H" Notification
printf '{"hook_event_name":"Stop","last_assistant_message":"sk-ant-SECRET"}' | TEAM_EVENTS_FILE="$E" sh "$H" Stop
check "append-only: 3 lines, first kept" '[ "$(wc -l <"$E" | tr -d " ")" = 3 ] && head -1 "$E" | grep -q PreToolUse'
check "notification type kept" 'sed -n 2p "$E" | grep -q "\"ev\":\"Notification\",\"ntype\":\"permission_prompt\"}"'
check "no message or last_assistant_message" '! grep -qE "SECRET|needs|\"X\"" "$E"'
keys=$(python3 -I -c 'import json,sys
print(sorted({k for l in open(sys.argv[1]) for k in json.loads(l)}))' "$E")
check "only t/ev/tool/ntype keys, valid JSON" '[ "$keys" = "['"'"'ev'"'"', '"'"'ntype'"'"', '"'"'t'"'"', '"'"'tool'"'"']" ]'

ml=$(printf '{"tool_name":"Read",\n"tool_input":{\n"tool_name":"Leak"}}')
printf '%s' "$ml" | TEAM_EVENTS_FILE="$E" sh "$H" PreToolUse
check "multi-line payload: later lines ignored" '! grep -q Leak "$E"'

n=$(wc -l <"$E")
printf '{}' | env -u TEAM_EVENTS_FILE sh "$H" Stop
check "unset TEAM_EVENTS_FILE: no-op" '[ "$(wc -l <"$E")" = "$n" ] && [ -z "$(ls "$W" | grep -v events)" ]'
printf '{}' | TEAM_EVENTS_FILE="$W/nodir/r.jsonl" sh "$H" Stop
check "missing parent dir: no-op" '[ ! -e "$W/nodir" ]'
printf '{}' | TEAM_EVENTS_FILE="$E" sh "$H" 'Stop;touch x'
check "bad event name: no-op" '[ "$(wc -l <"$E")" = "$n" ]'
ln -s "$W/target" "$W/events/link.jsonl"
printf '{}' | TEAM_EVENTS_FILE="$W/events/link.jsonl" sh "$H" Stop
check "symlink target refused" '[ ! -e "$W/target" ]'
big=$(head -c 300000 /dev/zero | tr '\0' a)
printf '{"tool_name":"Write","tool_input":{"content":"%s"}}' "$big" | TEAM_EVENTS_FILE="$E" sh "$H" PreToolUse
check "large payload drained, line written" 'tail -1 "$E" | grep -q "\"tool\":\"Write\""'

check "plugin.json names the plugin" 'python3 -I -c "import json,sys;assert json.load(open(sys.argv[1]))[\"name\"]==\"team-mates-events\"" "$P/.claude-plugin/plugin.json"'
check "hooks.json: each event calls event.sh with its own name" 'python3 -I - "$P/hooks/hooks.json" <<'"'"'PY'"'"'
import json,sys
h=json.load(open(sys.argv[1]))["hooks"]
need={"PreToolUse","PostToolUse","PermissionRequest","Notification","Stop","SubagentStop","SessionEnd"}
assert need<=set(h), need-set(h)
for e,gs in h.items():
  for g in gs:
    for c in g["hooks"]:
      assert c["command"]==f"\"${{CLAUDE_PLUGIN_ROOT}}/hooks/event.sh\" {e}", c
PY'
check "writer is executable" '[ -x "$H" ]'

echo; [ "$fails" = 0 ] && echo "all plugin-events tests passed" || { echo "$fails failed"; exit 1; }
