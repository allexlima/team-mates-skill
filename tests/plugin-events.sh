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
mcp=mcp__plugin_fe-ai-tools_fe-vending-machine__auto_approve_extension_requests
printf '{"tool_name":"%s","tool_input":{}}' "$mcp" | TEAM_EVENTS_FILE="$E" sh "$H" PreToolUse
check "75-char MCP tool name kept" '[ ${#mcp} = 75 ] && tail -1 "$E" | grep -q "\"tool\":\"$mcp\"}"'

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
      if "fence.py" in c["command"]:
        assert e=="PreToolUse" and g["matcher"]=="Edit|Write|MultiEdit|NotebookEdit|Bash", g; continue
      assert c["command"]==f"\"${{CLAUDE_PLUGIN_ROOT}}/hooks/event.sh\" {e}", c
PY'
# --- PreToolUse fence (fence.py) -------------------------------------------
F="$P/hooks/fence.py"
mkdir -p "$W/wt/sub" "$W/run" "$W/out"; ln -s "$W/out" "$W/wt/escape"
fence() { # $1 roots, $2 tool_input json -> prints deny|allow
  local o; o=$(printf '{"cwd":"%s","tool_name":"Write","tool_input":%s}' "$W/wt" "$2" | TEAM_FENCE_ROOTS="$1" python3 -I "$F")
  case $o in *'"deny"'*) echo deny ;; '') echo allow ;; *) echo "odd:$o" ;; esac; }
R2="$W/wt:$W/run"
check "fence: inside worktree allowed" '[ "$(fence "$R2" "{\"file_path\":\"$W/wt/sub/a.txt\"}")" = allow ]'
check "fence: run dir allowed" '[ "$(fence "$R2" "{\"file_path\":\"$W/run/r.md\"}")" = allow ]'
check "fence: relative path resolved from cwd" '[ "$(fence "$R2" "{\"file_path\":\"sub/a.txt\"}")" = allow ]'
check "fence: outside denied" '[ "$(fence "$R2" "{\"file_path\":\"$W/out/b.txt\"}")" = deny ]'
check "fence: .. escape denied" '[ "$(fence "$R2" "{\"file_path\":\"$W/wt/../out/b.txt\"}")" = deny ]'
check "fence: symlinked dir escape denied" '[ "$(fence "$R2" "{\"file_path\":\"$W/wt/escape/b.txt\"}")" = deny ]'
check "fence: sibling prefix denied" 'mkdir -p "$W/wt2"; [ "$(fence "$R2" "{\"file_path\":\"$W/wt2/x\"}")" = deny ]'
check "fence: notebook_path checked" '[ "$(fence "$R2" "{\"notebook_path\":\"$W/out/n.ipynb\"}")" = deny ]'
check "fence: unset roots = no fence" '[ "$(fence "" "{\"file_path\":\"$W/out/b.txt\"}")" = allow ]'
check "fence: no path = allow" '[ "$(fence "$R2" "{}")" = allow ]'
check "fence: non-object payload = allow" '[ "$(printf "[]" | TEAM_FENCE_ROOTS="$R2" python3 -I "$F"; echo "rc=$?")" = "rc=0" ]'

# Bash: git forms that skip hooks. Cases are data lines "want<TAB>command";
# \n in a command is a real newline.
gitcase() { # $1 want, $2 command
  local o; o=$(python3 -I -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1].replace("\\n","\n")}}))' "$2" \
    | TEAM_FENCE_ROOTS="$R2" python3 -I "$F")
  case $o in *'"deny"'*) got=deny ;; '') got=allow ;; *) got="odd:$o" ;; esac
  if [ "$got" = "$1" ]; then pass "fence git: $1 $2"; else fail "fence git: $1 $2" "got $got"; fi; }
while IFS=$'\t' read -r want cmd; do [ -n "$want" ] && gitcase "$want" "$cmd"; done <<'CASES'
deny	git -C /x commit --no-verify -m a
deny	git -c core.hooksPath=/dev/null commit -m a
deny	git -c Core.HooksPath=x commit
deny	git -ccore.hooksPath=x commit
deny	git --config-env=core.hooksPath=V commit
deny	git --config-env core.hooksPath=V commit
deny	git commit -nm msg
deny	git commit -an
deny	git status && git -C . commit --no-verify
deny	cd x; /usr/bin/git commit --no-verify
deny	env FOO=1 git commit --no-verify
deny	command git -C . push --no-verify
deny	GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=x git commit
deny	bash -c "git -C . commit --no-verify"
deny	git status\ngit commit -n
deny	bash -lc "git commit --no-verify"
deny	sh -ec 'git commit -n'
deny	git config core.hooksPath /dev/null
allow	git -C . config --unset core.hooksPath
deny	export GIT_CONFIG_PARAMETERS="'core.hooksPath=x'"; git commit
deny	git commit --no-verif
deny	git push --no-ver
deny	git commit \\n--no-verify -m x
deny	env -u FOO git commit --no-verify
deny	env -S "git commit --no-verify"
deny	nice -n 5 git commit --no-verify
deny	time -p git commit --no-verify
deny	env -P /usr/bin git commit --no-verify
deny	exec -a name git commit --no-verify
deny	/usr/bin/env git commit --no-verify
deny	timeout 60 git commit --no-verify
deny	timeout -s KILL 60 git commit --no-verify
deny	env -iu FOO git commit --no-verify
deny	/bin/bash -c "git commit --no-verify"
allow	git commit \\n-m ok
allow	git config --get core.hooksPath
allow	git config user.name x
allow	bash -l script.sh
allow	git commit -mn
allow	git commit -am "mention --no-verify in a message"
allow	git commit -m x -- --no-verify
allow	git push -n
allow	git log -n 3
allow	git -C /x commit -m ok
allow	git -c user.name=x commit -m ok
allow	echo git commit --no-verify
allow	grep -rn no-verify .
allow	git commit -m "unbalanced
deny	git -c alias.ci=commit ci -n
deny	git -c "alias.x=commit -n" x
deny	git -c include.path=/tmp/evil.cfg commit
deny	git -c includeIf.gitdir:/x.path=/tmp/e commit
deny	git config alias.ci "commit -n"
deny	GIT_CONFIG_GLOBAL=/tmp/evil.cfg git commit
deny	GIT_CONFIG_SYSTEM=/tmp/evil.cfg git commit
deny	GIT_CONFIG=/tmp/evil.cfg git commit
deny	sudo git commit -n
deny	sudo -u root git -C . commit -n
deny	sudo -n git commit --no-verify
deny	sudo -S git commit -n
deny	sudo -k git commit -n
deny	sudo --user root git commit --no-verify
deny	doas git commit -n
deny	doas -u root git -C . commit --no-verify
deny	git commit -m a\ #x --no-verify
deny	git config --rename-section foo include
deny	git config rename-section foo includeIf.gitdir:/
deny	/usr/bin/time -a -o f git commit --no-verify
deny	git commit -m a#b --no-verify
deny	git commit -m "#12 fix" --no-verify
deny	git config set core.hooksPath /dev/null
deny	git config --file .git/config core.hooksPath x
deny	if git commit -n; then :; fi
deny	! git commit --no-verify
deny	{ git commit -n; }
deny	for x in 1; do git commit -n; done
deny	git config core.hooksPath get
deny	git config include.path list
allow	git config get core.hooksPath
allow	git status # --no-verify
allow	git status\n# git commit --no-verify
allow	git config remote.origin.url https://host/include-lib.git
allow	git config user.name alias.bob
allow	git config --unset core.hooksPath
allow	git -c user.name=include commit -m ok
allow	sudo ls
allow	doas ls
CASES
check "writer is executable" '[ -x "$H" ]'

echo; [ "$fails" = 0 ] && echo "all plugin-events tests passed" || { echo "$fails failed"; exit 1; }
