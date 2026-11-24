#!/usr/bin/env bash
# tests/monitor-tui.sh — the status --json contract and the TUI monitor (scripts/monitor_tui.py).
# All headless: a stub cmux on PATH, a scratch TEAM_REG_DIR and HOME, a synthetic registry, run dir,
# worktree and transcript. Nothing touches real panes.
#   J*  status --json: the one document the TUI reads (joined registry fields, parsed tasks, live state)
#   U*  the summary's `unassigned` count, shared by the classic monitor and the TUI
#   P*  monitor_tui.py: its stdlib layer (--selftest), and a Textual render + key/screen walk when Textual is installed
#   X*  all teammates finished: the TUI's exit 4 closes the pane (stub TUI, real pty)
#   W*  status --watch picks the classic monitor when TEAM_MONITOR_UI=classic
# USAGE:  bash tests/monitor-tui.sh
set -uo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/skills/team/scripts/team.sh}"
TUI="$(dirname "$TEAM_SH")/monitor_tui.py"
LIB="$(dirname "$TEAM_SH")/lib/status.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
# A portable timeout: GNU `timeout` is absent from a stock macOS PATH.
tmo() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else perl -e 'my $s = shift; my $p = fork; if (!$p) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill 15, $p; waitpid $p, 0; exit 124 }; alarm $s; waitpid $p, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$@"
  fi
}
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
unset TEAM_MEMBER NO_COLOR TEAM_FORCE_COLOR TEAM_COLS TEAM_MONITOR_UI

mkdir -p "$W/bin" "$W/reg" "$W/home"; chmod 700 "$W/reg"
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (1) stub" ;;
  identify)
    surf=""; prev=""; for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
    [ -n "${CMUX_CALLS:-}" ] && echo "identify $surf" >> "$CMUX_CALLS"
    case " ${CMUX_NULL_REFS:-} " in *" $surf "*) echo '{"caller":null}'; exit 0 ;; esac
    case " ${CMUX_GONE_REFS:-} " in
      *" $surf "*) echo '{"caller":{"pane_ref":null}}' ;;
      *) echo "{\"caller\":{\"pane_ref\":\"pane:$surf\",\"surface_ref\":\"${surf:-surface:lead}\"}}" ;;
    esac ;;
  list-panes) echo '{"panes":[]}' ;;
  list-notifications) echo '[]' ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"
export PATH="$W/bin:$PATH" HOME="$W/home" TEAM_REG_DIR="$W/reg" CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead

G="$W/repo"; mkdir -p "$G"; git -C "$G" init -q
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
RUN="$G/.team/runs/2026-11-18-j1"; mkdir -p "$RUN/reports" "$RUN/status" "$RUN/prompts"
git -C "$G" worktree add -q -b team/j1-api "$G/.team/worktrees/j1-api" HEAD
cat > "$RUN/tasks.md" <<'T'
j1-api — model: sonnet — spec: new
- [x] T1 j1-api: design the retry policy — owns: src/retry.py — needs: -
- [ ] T2 j1-api: implement retry — owns: src/retry.py — needs: T1
- [ ] T3 any: load-test it — owns: read-only — needs: T1
- [ ] T4 j1-ui: show retries — owns: web/r.tsx — needs: T2
- [x] T5 j1-sec: threat model — owns: read-only — needs: -
T
printf 'T2: implementing backoff · 45%%\n' > "$RUN/status/api.txt"
printf 'T3: load test · 10%%\n' > "$RUN/status/ui.txt"
printf 'FINDINGS: x\nPARALLELISM: 2\nhttps://github.com/acme/app/pull/12\n' > "$RUN/reports/sec.md"
S1=11111111-2222-3333-4444-555555555555
{
  echo "cmux surface:3 pane j1-api sonnet - $RUN $G live $S1 $G/.team/worktrees/j1-api"
  echo "cmux surface:4 pane j1-ui sonnet - $RUN $G live 22222222-2222-3333-4444-555555555555 $G/a dir with spaces"
  echo "cmux surface:5 pane j1-sec opus - $RUN $G finished 33333333-2222-3333-4444-555555555555 $G"
  echo "cmux surface:7 dash j1-monitor - - - $G live - -"
} > "$W/reg/team-j1.tabs"

json=$(cd "$G" && bash "$TEAM_SH" status --json j1 2>/dev/null)
# ═══ J1 — status --json is one valid document with the summary, teammates and tasks ═══
check=$(python3 -I - "$json" "$G" "$S1" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); G, S1 = sys.argv[2], sys.argv[3]
bad = []
m = {t["title"]: t for t in d["teammates"]}
if d.get("version") != 1: bad.append("version")
if set(m) != {"j1-api", "j1-ui", "j1-sec"}: bad.append(f"titles={sorted(m)} (the dash monitor must be left out)")
a = m.get("j1-api", {})
if a.get("session_id") != S1 or a.get("branch") != "team/j1-api" or a.get("task") != "T2" or a.get("pct") != 45:
    bad.append(f"api={a}")
if a.get("step") != "T2: implementing backoff": bad.append(f"step={a.get('step')!r} (the % suffix is stripped)")
if m.get("j1-ui", {}).get("cwd") != G + "/a dir with spaces": bad.append(f"ui cwd={m.get('j1-ui', {}).get('cwd')!r}")
if m.get("j1-sec", {}).get("state") != "FINISHED" or not m["j1-sec"].get("report"): bad.append("sec finished+report")
t = {x["id"]: x for x in d["tasks"]}
if t.get("T2", {}).get("scope") != "implement retry" or t["T2"].get("owns") != "src/retry.py" or t["T2"].get("needs") != ["T1"]:
    bad.append(f"T2={t.get('T2')}")
if not t["T2"]["ready"] or t["T4"]["ready"]: bad.append("ready flags")
s = d["summary"]
if (s["done"], s["total"], s["prs"]) != (2, 5, 1): bad.append(f"summary={s}")
if d["prs"] != ["https://github.com/acme/app/pull/12"]: bad.append(f"prs={d['prs']}")
print("; ".join(bad))
PY
)
[ -z "$check" ] && pass "J1: status --json joins registry fields (session, cwd with spaces, branch) and parses tasks (scope, owns, needs, ready)" \
  || fail "J1: status --json contract" "$check"

# ═══ J4 — a live surface (compact `cmux identify` JSON) is WORKING; a null pane_ref is DEAD ═══
st=$(cd "$G" && CMUX_GONE_REFS=surface:4 bash "$TEAM_SH" status --json j1 2>/dev/null \
  | python3 -I -c 'import json,sys; m={t["title"]: t["state"] for t in json.load(sys.stdin)["teammates"]}; print(m["j1-api"], m["j1-ui"])')
[ "$st" = "WORKING DEAD" ] && pass "J4: compact identify JSON: live surface is WORKING, null pane_ref is DEAD" \
  || fail "J4: cmux identify parse" "$st"

# ═══ B1 — no task lines, one of three finished, nobody reports a %: the classic bar and json bar_pct agree (33) ═══
RUN2="$G/.team/runs/2026-11-18-j2"; mkdir -p "$RUN2/reports" "$RUN2/status"
printf 'FINDINGS: x\nPARALLELISM: none\n' > "$RUN2/reports/c.md"
{ echo "cmux surface:13 pane j2-a sonnet - $RUN2 $G live - -"; echo "cmux surface:14 pane j2-b sonnet - $RUN2 $G live - -"
  echo "cmux surface:15 pane j2-c sonnet - $RUN2 $G finished - -"; } > "$W/reg/team-j2.tabs"
cpct=$(cd "$G" && LC_ALL=en_US.UTF-8 TEAM_COLS=100 bash "$TEAM_SH" status j2 2>/dev/null | grep -oE '[0-9]+%' | head -1)
jpct=$(cd "$G" && bash "$TEAM_SH" status --json j2 2>/dev/null | python3 -I -c 'import json,sys; s=json.load(sys.stdin)["summary"]; print(s["bar_pct"], s["bar_est"])')
[ "$cpct" = "33%" ] && [ "$jpct" = "33 False" ] && pass "B1: classic bar $cpct = json bar_pct (the TUI renders it verbatim)" \
  || fail "B1: bar % mismatch" "classic=$cpct json=$jpct"

# ═══ J5 — `"caller": null` is UNKNOWN (what _alive/reap treat as alive), not DEAD ═══
st=$(cd "$G" && CMUX_NULL_REFS=surface:4 bash "$TEAM_SH" status --json j1 2>/dev/null \
  | python3 -I -c 'import json,sys; m={t["title"]: t["state"] for t in json.load(sys.stdin)["teammates"]}; print(m["j1-ui"])')
[ "$st" = UNKNOWN ] && pass "J5: a null caller leaves the row UNKNOWN, matching _alive" || fail "J5: null caller" "$st"

# ═══ J7 — one refresh asks cmux identify once per teammate surface (the probe), not again per row ═══
CMUX_CALLS="$W/calls"; : > "$CMUX_CALLS"
(cd "$G" && CMUX_CALLS="$CMUX_CALLS" bash "$TEAM_SH" status --json j1 >/dev/null 2>&1)
got=$(grep 'surface:' "$CMUX_CALLS" | sort | uniq -c | awk '{print $1 "x" $3}' | tr '\n' ' ')
[ "$got" = "1xsurface:3 1xsurface:4 " ] && pass "J7: status --json identifies each live teammate surface exactly once per refresh (finished ones not at all)" \
  || fail "J7: identify calls per refresh" "$got"

# ═══ J6 — a `gating <sha>` status line is state GATING with gate_sha, end to end through team.sh ═══
printf 'T3: gating 9f8e7d6 · 90%%\n' > "$RUN/status/ui.txt"
st=$(cd "$G" && bash "$TEAM_SH" status --json j1 2>/dev/null \
  | python3 -I -c 'import json,sys; m={t["title"]: t for t in json.load(sys.stdin)["teammates"]}["j1-ui"]; print(m["state"], m["gate_sha"])')
printf 'T3: load test · 10%%\n' > "$RUN/status/ui.txt"
[ "$st" = "GATING 9f8e7d6" ] && pass "J6: status --json reports GATING and gate_sha for a teammate inside a gate" || fail "J6: gating state" "$st"

# ═══ J2 — the same counts as the classic frame (one parser, two outputs) ═══
frame=$(cd "$G" && LC_ALL=en_US.UTF-8 TEAM_COLS=100 bash "$TEAM_SH" status j1 2>/dev/null)
grep -q 'j1 · 2/5 tasks' <<<"$frame" && pass "J2: classic frame and status --json agree on 2/5 tasks" || fail "J2: classic frame counts" "$frame"

# ═══ J3 — no registry: exit 3, nothing on stdout ═══
out=$(cd "$G" && bash "$TEAM_SH" status --json nosuchteam 2>/dev/null); rc=$?
[ "$rc" = 3 ] && [ -z "$out" ] && pass "J3: status --json on an unknown team exits 3 with no output" || fail "J3: unknown team" "rc=$rc out=$out"

# ═══ U1 — an `any` task a live teammate names on its status line is not unassigned ═══
un=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["summary"]["unassigned"])' "$json")
[ "$un" = 0 ] && pass "U1: T3 (any, ready) claimed by ui's status line 'T3: ...' does not count as unassigned" \
  || fail "U1: claimed any task counted as unassigned" "unassigned=$un"
printf 'T2: implementing backoff · 50%%\n' > "$RUN/status/ui.txt"   # ui no longer names T3
un=$(cd "$G" && bash "$TEAM_SH" status --json j1 | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["summary"]["unassigned"])')
[ "$un" = 1 ] && pass "U2: once nobody names T3, the ready any task is unassigned again" || fail "U2: unclaimed any task" "unassigned=$un"

# ═══ P1 — the TUI's stdlib layer: forecast, history, transcript reader ═══
st=$(python3 -I "$TUI" --selftest 2>&1); rc=$?
[ "$rc" = 0 ] && pass "P1: monitor_tui.py --selftest ($(grep -c '^PASS' <<<"$st") checks: forecast, history, transcript)" \
  || fail "P1: monitor_tui.py --selftest" "$(grep FAIL <<<"$st")"

# ═══ P2 — Textual render of the live fixture: header, a card, the backlog (skips without Textual) ═══
# The TUI runs under python3 when it can import Textual, else under `uv run --script` (the PEP 723 header
# pins Textual: the same path status.sh takes). TEAM_REQUIRE_TUI=1 (CI) turns "neither" into a failure.
TUIRUN=()
if python3 -c 'import textual' 2>/dev/null; then TUIRUN=(python3 "$TUI")
elif command -v uv >/dev/null 2>&1; then TUIRUN=(uv run --quiet --script "$TUI"); fi
if [ "${#TUIRUN[@]}" = 0 ] && [ "${TEAM_REQUIRE_TUI:-}" = 1 ]; then
  fail "P2: TEAM_REQUIRE_TUI=1 but neither Textual nor uv is available" "the render and walk tests cannot run"
fi
if [ "${#TUIRUN[@]}" -gt 0 ]; then
  mkdir -p "$HOME/.claude/projects/-fx"
  printf '%s\n' '{"type":"assistant","timestamp":"2026-11-18T10:00:00Z","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":99000,"output_tokens":5},"content":[{"type":"tool_use","id":"u1","name":"Bash","input":{"command":"pytest -q"}}]}}' \
    > "$HOME/.claude/projects/-fx/$S1.jsonl"
  (cd "$G" && tmo 120 "${TUIRUN[@]}" --team j1 --team-sh "$TEAM_SH" --screenshot "$W/shot.svg" --size 140x40 >/dev/null 2>&1)
  txt=$(python3 -I -c 'import html,re,sys; print(html.unescape(re.sub(r"<[^>]+>", "", open(sys.argv[1]).read())).replace("\xa0"," "))' "$W/shot.svg" 2>/dev/null)
  miss=
  for want in 'TEAM-MATES' 'j1' 'api' 'T2' 'Backlog' 'implement retry' 'pytest -q' 'ctx 50%'; do
    grep -qF -- "$want" <<<"$txt" || miss+=" [$want]"
  done
  [ -z "$miss" ] && pass "P2: the TUI renders the live team: header, cards, backlog, and the tool in flight + context from the transcript" \
    || fail "P2: TUI render" "missing:$miss"
  # P4: every screen and key once (details + its tabs, help, theme, refresh, show), on the demo and the live fixture.
  wd=$(tmo 120 "${TUIRUN[@]}" --demo --walk 2>&1); wdrc=$?
  wl=$(cd "$G" && tmo 120 "${TUIRUN[@]}" --team j1 --team-sh "$TEAM_SH" --walk 2>&1); wlrc=$?
  [ "$wdrc" = 0 ] && [ "$wlrc" = 0 ] && pass "P4: the TUI walks every screen and key without a crash (demo + live fixture)" \
    || fail "P4: TUI walk" "demo rc=$wdrc $(tail -2 <<<"$wd" | tr '\n' ' ') live rc=$wlrc $(tail -2 <<<"$wl" | tr '\n' ' ')"
  ls "$RUN/monitor/history.jsonl" >/dev/null 2>&1 && pass "P3: the TUI keeps its history in <run>/monitor/history.jsonl" || fail "P3: history file" "none"
else
  echo "SKIP  P2/P3: Textual is not installed (pip install textual)"
fi

# ═══ X1 — all teammates finished: the TUI exits 4, the status pane closes its own surface ═══
# A stub monitor_tui.py that exits 4 (what the real one does after the grace period) in a copy of the
# skill, a stub uv that runs it, a real pty (the TUI is picked for terminals only), and the stub cmux
# logging close-surface. An exit of 0 or 5 must close nothing.
SK="$W/skill"; cp -R "$(dirname "$TEAM_SH")/.." "$SK" 2>/dev/null
mkdir -p "$W/xbin"
printf '#!/usr/bin/env bash\nshift; shift; shift; exec python3 "$@"\n' > "$W/xbin/uv"; chmod +x "$W/xbin/uv"
sed 's|^  \*) true ;;|  close-surface) echo "$*" >> "$CMUX_LOG" ;;\n  *) true ;;|' "$W/bin/cmux" > "$W/xbin/cmux"; chmod +x "$W/xbin/cmux"
x1() {   # x1 <exit code of the stub TUI> -> prints what cmux saw
  printf 'import sys\nsys.exit(%s)\n' "$1" > "$SK/scripts/monitor_tui.py"; : > "$W/cmux.log"
  (cd "$G" && CMUX_LOG="$W/cmux.log" PATH="$W/xbin:$PATH" TEAM_MONITOR_UI=auto tmo 30 python3 -c '
import pty, sys
sys.exit(pty.spawn(["bash", sys.argv[1], "status", "--watch", "j1"]) >> 8)' "$SK/scripts/team.sh" >/dev/null 2>&1)
  cat "$W/cmux.log"
}
if [ -d "$SK/scripts" ]; then
  out4=$(x1 4); out0=$(x1 0)
  [ "$out4" = "close-surface --force --surface surface:lead" ] && [ -z "$out0" ] \
    && pass "X1: exit 4 (all finished) closes the monitor's own surface; exit 0 closes nothing" \
    || fail "X1: exit-4 auto-close" "exit4=[$out4] exit0=[$out0]"
fi

# ═══ W1 — TEAM_MONITOR_UI=classic keeps the classic monitor ═══
pick=$(TEAM_MONITOR_UI=classic bash -c 'here=$(dirname "$1"); . "$2"; _st_tui_pick && echo tui || echo classic' _ "$TEAM_SH" "$LIB" 2>/dev/null)
[ "$pick" = classic ] && pass "W1: TEAM_MONITOR_UI=classic selects the classic monitor" || fail "W1: classic opt-out" "$pick"

echo
echo "monitor-tui: $passes passed, $fails failed"
[ "$fails" = 0 ] && echo "all passed ($passes cases)"
exit $(( fails > 0 ))
