#!/usr/bin/env bash
# tests/tmux.sh — the tmux fallback backend (lib/mux.sh): spawn grid, tabs, finish/close, show,
# status liveness, a mixed cmux+tmux registry, backend detection, and one real-tmux smoke test.
# X1-X8 use a logging tmux stub; X9 drives a real tmux server on a private socket and is
# skipped when tmux is not installed.
# USAGE: bash tests/tmux.sh   (or TEAM_SH=/path/to/team.sh bash tests/tmux.sh)
set -uo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/team.sh}"
W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT
fails=0; passes=0
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
REAL_TMUX=$(command -v tmux || true)

mkdir -p "$W/bin" "$W/realbin"
TMUX_LOG="$W/tmux.log"; CMUX_LOG="$W/cmux.log"; : > "$TMUX_LOG"; : > "$CMUX_LOG"
# tmux stub. Knobs: TMUX_GONE_PANES "%1 %2" (display fails "can't find pane"),
# TMUX_TITLES "%N=title ..." (pane_title answers; default: the title it was given by select-pane -T).
cat > "$W/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_LOG"
[ "$1" = -L ] && shift 2
ST="$TMUX_LOG.panes"; touch "$ST"
case "$1" in
  select-pane) [ "${4:-}" = -T ] && printf '%s\t%s\n' "$3" "$5" >> "$ST" ;;
  kill-pane) grep -v "^$3	" "$ST" > "$ST.tmp"; mv "$ST.tmp" "$ST" ;;
esac
n=$(grep -cE '(split-window|new-window)' "$TMUX_LOG")
case "$1" in
  split-window|new-window) printf '%%%d\n' $((n + 10)) ;;
  display|display-message)
    t=; f=; while [ $# -gt 0 ]; do case $1 in -t) t=$2; shift ;; -p) ;; *) f=$1 ;; esac; shift; done
    # Like real tmux 3.7: a missing pane answers an empty line with exit 0.
    for g in ${TMUX_GONE_PANES:-}; do [ "$g" = "$t" ] && { echo; exit 0; }; done
    case $f in
      *pane_title*)
        for kv in ${TMUX_TITLES:-}; do [ "${kv%%=*}" = "$t" ] && { echo "${kv#*=}"; exit 0; }; done
        awk -F'\t' -v t="$t" '$1==t {v=$2} END{print v}' "$ST" ;;
      *) echo "${t:-%0}" ;;
    esac ;;
  list-panes)
    awk -F'\t' '{print $1 "\t" $2 "\tterminal"}' "$ST"
    for kv in ${TMUX_TITLES:-}; do printf '%s\t%s\tterminal\n' "${kv%%=*}" "${kv#*=}"; done ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/tmux"
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  ping) echo PONG ;; --version) echo "cmux 0.65.0 stub" ;;
  identify) echo '{"caller":{"pane_ref":"pane-stub","surface_ref":"surface:1"}}' ;;
  tree) echo '{"workspaces":[{"ref":"workspace:1","surfaces":[{"ref":"surface:5","title":"'"${CMUX_T5:-x}"'"}]}]}' ;;
  close-surface) echo OK ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/claude"; chmod +x "$W/bin/claude"
export PATH="$W/bin:$PATH" TMUX_LOG CMUX_LOG
unset TEAM_MEMBER CMUX_WORKSPACE_ID CMUX_SURFACE_ID
export TMUX="/tmp/tmux-test,1,0" TMUX_PANE=%0 TEAM_MUX=tmux

mkdir -p "$W/home/.claude/team/roles"
cat > "$W/home/.claude/settings.json" <<'JSON'
{"modelPicker":{"options":[{"model":"system.ai.claude-sonnet-4-6","behavesAs":"sonnet"}]}}
JSON
echo '{"projects":{}}' > "$W/home/.claude.json"
export HOME="$W/home" TEAM_MODELS_FILE="$W/home/.claude/settings.json" TEAM_ROLES_DIR="$W/home/.claude/team/roles"
export TEAM_REG_DIR="$W/regs"; mkdir -p "$TEAM_REG_DIR"
_git() { git -c user.email=t@t -c user.name=T "$@"; }
R="$W/repo"; mkdir -p "$R"; _git -C "$R" init -q; _git -C "$R" commit -q --allow-empty -m init
R=$(cd "$R" && pwd -P); RUN="$R/.team/runs/2026-11-17-x"; mkdir -p "$RUN/prompts" "$RUN/reports" "$RUN/status"
: > "$RUN/tasks.md"; printf 'go\n' > "$RUN/prompts/p.md"
sp() { (cd "$R" && bash "$TEAM_SH" spawn "$@" 2>&1); }
REG() { echo "$TEAM_REG_DIR/team-$1.tabs"; }

# X1-X2: pane grid
: > "$TMUX_LOG"
o1=$(sp x1 a "$RUN/prompts/p.md" sonnet); o2=$(sp x1 b "$RUN/prompts/p.md" sonnet); o3=$(sp x1 c "$RUN/prompts/p.md" sonnet)
row_a=$(awk '$4=="x1-a"' "$(REG x1)")
{ [[ $row_a == "tmux %"*" pane x1-a "* ]] && grep -qE '^split-window -d -h -t %0 ' "$TMUX_LOG"; } \
  && pass "X1: spawn opens a tmux pane right of the lead and records a tmux row" \
  || fail "X1: tmux spawn" "row=[$row_a] o=$o1 log=$(cat "$TMUX_LOG")"
pa=$(awk '$4=="x1-a"{print $2}' "$(REG x1)")
{ grep -qE "^split-window -d -h -t $pa " "$TMUX_LOG" && grep -qE "^split-window -d -v -t $pa " "$TMUX_LOG"; } \
  && pass "X2: second and third teammates follow the two-column grid" \
  || fail "X2: grid" "log=$(cat "$TMUX_LOG")"
grep -qE '^select-pane -t %[0-9]+ -T x1-a$' "$TMUX_LOG" \
  && pass "X2b: the pane is titled <team>-<role>" || fail "X2b: pane title" "log=$(cat "$TMUX_LOG")"

# X3: --tabs -> one window per teammate
: > "$TMUX_LOG"; o=$(sp --tabs x3 a "$RUN/prompts/p.md" sonnet)
grep -qE '^new-window -d -n x3-a ' "$TMUX_LOG" && pass "X3: --tabs opens a tmux window per teammate" \
  || fail "X3: tabs" "o=$o log=$(cat "$TMUX_LOG")"

# X4: finish and close kill the pane
printf '# R\nPARALLELISM: none\n' > "$RUN/reports/a.md"; printf -- '- [x] x1-a: done\n' >> "$RUN/tasks.md"
: > "$TMUX_LOG"; o=$(cd "$R" && bash "$TEAM_SH" finish x1 a 2>&1); rc=$?
grep -qE "^kill-pane -t $pa$" "$TMUX_LOG" && [ $rc = 0 ] \
  && pass "X4: finish kills the teammate's tmux pane" || fail "X4: finish" "rc=$rc o=$o log=$(cat "$TMUX_LOG")"
: > "$TMUX_LOG"; o=$(cd "$R" && bash "$TEAM_SH" close x1 2>&1); rc=$?
{ [ $rc = 0 ] && [ "$(grep -c '^kill-pane' "$TMUX_LOG")" = 2 ] && [ ! -e "$(REG x1)" ]; } \
  && pass "X4b: close kills every live tmux pane and removes the registry" \
  || fail "X4b: close" "rc=$rc o=$o log=$(cat "$TMUX_LOG")"

# X5: show
: > "$TMUX_LOG"; px=$(awk '{print $2}' "$(REG x3)"); o=$(cd "$R" && bash "$TEAM_SH" show x3 a 2>&1); rc=$?
{ grep -qE "^select-window -t $px$" "$TMUX_LOG" && grep -qE "^select-pane -t $px$" "$TMUX_LOG"; } \
  && pass "X5: show selects the teammate's window and pane" || fail "X5: show" "rc=$rc o=$o log=$(cat "$TMUX_LOG")"

# X6: status liveness for tmux rows
reg6=$(REG x6); for r in w d s; do
  printf 'tmux %%6%s pane x6-%s - - %s %s live 1 %s\n' "$r" "$r" "$RUN" "$R" "$R"
done > "$reg6"
echo 'working · 10%' > "$RUN/status/w.txt"; echo 'working · 10%' > "$RUN/status/s.txt"
touch -t "$(date -v-11M +%Y%m%d%H%M 2>/dev/null || date -d '-11 min' +%Y%m%d%H%M)" "$RUN/status/s.txt"
out=$(cd "$R" && env TEAM_COLS=100 TMUX_GONE_PANES=%6d bash "$TEAM_SH" status x6 2>&1)
{ grep -qE ' w .*(working|investigating)' <<<"$out" && grep -qE ' d .*dead' <<<"$out" && grep -qE ' s .*stalled' <<<"$out"; } \
  && pass "X6: tmux rows read alive -> working, gone -> dead, silent 11 min -> stalled?" \
  || fail "X6: tmux status" "$out"

# X7: mixed registry
reg7=$(REG x7); printf 'cmux surface:5 pane x7-c - - %s %s live 1 %s\ntmux %%71 pane x7-t - - %s %s live 1 %s\n' "$RUN" "$R" "$R" "$RUN" "$R" "$R" > "$reg7"
o1=$(cd "$R" && env TEAM_COLS=100 bash "$TEAM_SH" status x7 2>&1); r1=$?
: > "$TMUX_LOG"; : > "$CMUX_LOG"
o2=$(cd "$R" && env CMUX_T5=x7-c TMUX_TITLES=%71=x7-t bash "$TEAM_SH" close x7 2>&1); r2=$?
{ [ $r1 = 0 ] && [ $r2 = 0 ] && grep -q '^kill-pane -t %71$' "$TMUX_LOG" && grep -q 'close-surface --surface surface:5' "$CMUX_LOG"; } \
  && pass "X7: a registry with cmux and tmux rows: status works and close uses each row's own backend" \
  || fail "X7: mixed registry" "r1=$r1 r2=$r2 o1=$o1 o2=$o2 tmux=$(cat "$TMUX_LOG") cmux=$(cat "$CMUX_LOG")"

# X10: the monitor opens as a tmux pane and is recorded as a dash row
: > "$TMUX_LOG"; o=$(cd "$R" && bash "$TEAM_SH" monitor x3 2>&1); rc=$?
mrow=$(awk '$3=="dash"' "$(REG x3)")
{ [ $rc = 0 ] && [[ $mrow == "tmux %"*" dash x3-monitor "* ]] && grep -qE '^split-window -d -v .*TEAM_MUX=tmux .*status --watch' "$TMUX_LOG"; } \
  && pass "X10: monitor opens a tmux pane running status --watch and records a tmux dash row" \
  || fail "X10: tmux monitor" "rc=$rc o=$o row=[$mrow] log=$(cat "$TMUX_LOG")"

# X8: no backend
o=$(cd "$R" && env -u TMUX -u TMUX_PANE -u TEAM_MUX PATH="$W/realbin:/usr/bin:/bin" bash "$TEAM_SH" spawn x8 a "$RUN/prompts/p.md" sonnet 2>&1); rc=$?
{ [ $rc = 3 ] && grep -qi 'cmux' <<<"$o" && grep -qi 'tmux' <<<"$o" \
  && [ "$(grep -bo -i 'cmux' <<<"$o" | head -1 | cut -d: -f1)" -lt "$(grep -bo -i 'tmux' <<<"$o" | head -1 | cut -d: -f1)" ]; } \
  && pass "X8: with neither cmux nor tmux, spawn exits 3 and recommends cmux before tmux" \
  || fail "X8: no backend" "rc=$rc o=$o"

# X9: real tmux smoke test on a private socket
if [ -n "$REAL_TMUX" ]; then
  sock="team-test-$$"
  ln -s "$REAL_TMUX" "$W/realbin/tmux"
  "$REAL_TMUX" -L "$sock" new-session -d -s t -x 200 -y 50
  lead=$("$REAL_TMUX" -L "$sock" display -p -t t '#{pane_id}')
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$W/realbin/claude"; chmod +x "$W/realbin/claude"
  RP="$W/realbin:$PATH"; RP=${RP//"$W/bin:"/}
  o=$(cd "$R" && env PATH="$RP" TEAM_TMUX_SOCKET="$sock" TMUX_PANE="$lead" bash "$TEAM_SH" spawn x9 a "$RUN/prompts/p.md" sonnet 2>&1); rc=$?
  p9=$(awk '{print $2}' "$(REG x9)" 2>/dev/null)
  alive=$("$REAL_TMUX" -L "$sock" display -p -t "$p9" '#{pane_title}' 2>/dev/null || true)
  o2=$(cd "$R" && env PATH="$RP" TEAM_TMUX_SOCKET="$sock" TMUX_PANE="$lead" bash "$TEAM_SH" close x9 2>&1)
  gone=$("$REAL_TMUX" -L "$sock" list-panes -a -F '#{pane_id}' 2>&1 | grep -cx -- "$p9" || true)
  "$REAL_TMUX" -L "$sock" kill-server 2>/dev/null || true
  { [ $rc = 0 ] && [ "$alive" = x9-a ] && [ "$gone" = 0 ]; } \
    && pass "X9: real tmux: spawn opens a titled pane, close removes it" \
    || fail "X9: real tmux" "rc=$rc p9=$p9 alive=[$alive] gone=[$gone] o=$o o2=$o2"
else
  echo "SKIP  X9: tmux not installed"
fi

echo; echo "tmux: $passes passed, $fails failed"
[ "$fails" = 0 ] || exit 1
echo "all passed ($passes cases)"
