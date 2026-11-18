#!/usr/bin/env bash
# tests/status-render.sh — golden-frame + state tests for the rev5 monitor renderer.
# Source: .team/runs/2026-10-08-rev5/decisions.md (decisions 1-7, 41, 43, 48), tasks.md.
# Every case names the requirement it covers (A1..., decision N). All headless: a stub cmux on
# PATH, a scratch TEAM_REG_DIR, synthetic registries and run dirs. Nothing touches real panes.
# USAGE:  bash tests/status-render.sh            (current worktree)
#         TEAM_SH=/path/to/team.sh bash tests/status-render.sh
# Two layers:
#   G*  pure layer: `_st_frame <team> <cols> <color> <ascii>` fed TSV records; byte-exact goldens.
#   E*  end to end: `team.sh status <team>` over a fixture registry; asserts the derived STATE.
# No -e: every case reports PASS/FAIL itself, so a failing command must not abort the run.
set -uo pipefail

TEAM_SH="${TEAM_SH:-$(cd "$(dirname "$0")/.." && pwd)/skills/team/scripts/team.sh}"
LIB="$(dirname "$TEAM_SH")/lib/status.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0; passes=0
# tmo <secs> cmd...: GNU timeout, else gtimeout, else perl alarm (macOS CI has no coreutils); 124 on expiry.
tmo() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else perl -e 'my $s = shift; my $p = fork; if (!$p) { exec @ARGV or exit 127 }
    $SIG{ALRM} = sub { kill 15, $p; waitpid $p, 0; exit 124 }; alarm $s; waitpid $p, 0; exit($? >> 8)' "$@"
  fi
}
pass() { echo "PASS  $1"; passes=$((passes+1)); }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
unset TEAM_MEMBER NO_COLOR TEAM_FORCE_COLOR TEAM_COLS
# One UTF-8 locale for the whole suite: en_US.UTF-8 when installed, else C.UTF-8 (minimal CI images).
UTF8_LOC=C.UTF-8
locale -a 2>/dev/null | grep -qix 'en_US\.utf-\?8' && UTF8_LOC=en_US.UTF-8
export UTF8_LOC

# ── stub cmux: identify answers "gone" for refs listed in $CMUX_GONE_REFS; everything else is empty ──
mkdir -p "$W/bin"
CMUX_LOG="$W/cmux.log"; : > "$CMUX_LOG"; export CMUX_LOG
cat > "$W/bin/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CMUX_LOG"
case "$1" in
  ping) echo PONG ;;
  --version) echo "cmux 0.65.0 (108) stub" ;;
  identify)
    surf=""; prev=""
    for a; do [ "$prev" = "--surface" ] && surf="$a"; prev="$a"; done
    case " ${CMUX_ERR_REFS:-} " in *" $surf "*) echo "Error: timeout" >&2; exit 1 ;; esac
    case " ${CMUX_NOTFOUND_REFS:-} " in *" $surf "*) echo "Error: not_found" >&2; exit 1 ;; esac
    case " ${CMUX_GONE_REFS:-} " in
      *" $surf "*) echo '{"caller":{"pane_ref":null}}' ;;
      *) echo "{\"caller\":{\"pane_ref\":\"pane-live\",\"surface_ref\":\"${surf:-surface:lead}\"}}" ;;
    esac ;;
  list-panes) echo '{"panes":[]}' ;;
  list-notifications) echo '[]' ;;
  *) true ;;
esac
SH
chmod +x "$W/bin/cmux"
export PATH="$W/bin:$PATH"
export HOME="$W/home"; mkdir -p "$HOME"
export TEAM_REG_DIR="$W/reg"; mkdir -p "$TEAM_REG_DIR"
export CMUX_WORKSPACE_ID=ws-test CMUX_SURFACE_ID=surface:lead

# Display width of stdin lines, one number per line (east-asian wide = 2, combining = 0).
dwidth() {
  python3 -I -c '
import sys, unicodedata as u
for l in sys.stdin.read().split("\n")[:-1] or []:
    print(sum(0 if u.combining(c) else 2 if u.east_asian_width(c) in "WF" else 1 for c in l))'
}
# Run _st_frame in a clean bash with the library sourced; records on stdin.
# `|| true`: on code without _st_frame the case must FAIL (empty frame), not abort the whole run.
frame() { LC_ALL=$UTF8_LOC bash -c '. "$1"; shift; _st_frame "$@"' _ "$LIB" "$@" 2>/dev/null || true; }
rec() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }   # role title state milestone step age_min note

# ═══ G1 — A1/decision 1: all-healthy frame is compact, no NEEDS YOU block ═══
healthy=$( { rec core fx-core WORKING drafting "drafting report" 3 ""
             rec docs fx-docs FINISHED reported - 0 ""
             rec status fx-status WORKING investigating "investigating facts" 5 ""; } | frame fx 72 0 0 )
want='fx · 1/3 reported · @@CLOCK@@
██████░░░░░░░░░░░░░░  33%

    ROLE    STATE            STEP                                    AGE
  · core    ◐ drafting       drafting report                          3m
  · status  ◐ investigating  investigating facts                      5m

  ✓ 1 finished'
[ "$healthy" = "$want" ] \
  && pass "G1: all-healthy compact frame matches golden (summary, bar, table, no alert block)" \
  || { fail "G1: all-healthy compact frame matches golden"; diff <(printf '%s\n' "$want") <(printf '%s\n' "$healthy") | sed 's/^/        /' | head -12; }
grep -q 'NEEDS YOU' <<<"$healthy" \
  && fail "G1b: no NEEDS YOU block when nothing needs attention (decision 1)" \
  || pass "G1b: no NEEDS YOU block when nothing needs attention (decision 1)"

# ═══ G2 — decision 1: alerts pinned in a NEEDS YOU block above the table ═══
alert=$( { rec core fx-core WORKING drafting "-" 1 ""
           rec a fx-a DEAD spawned - 0 "report safe; resume unavailable"
           rec b fx-b WAITING drafting "which db?" 2 ""; } | frame fx 72 0 0 )
hdr_line=$(grep -n 'ROLE' <<<"$alert" | head -1 | cut -d: -f1 || true)
need_line=$(grep -n 'NEEDS YOU (2)' <<<"$alert" | head -1 | cut -d: -f1 || true)
if [ -n "$need_line" ] && [ -n "$hdr_line" ] && [ "$need_line" -lt "$hdr_line" ] \
   && sed -n "${need_line},${hdr_line}p" <<<"$alert" | grep -q 'waiting' \
   && sed -n "${need_line},${hdr_line}p" <<<"$alert" | grep -q 'dead'; then
  pass "G2: WAITING + DEAD pinned in 'NEEDS YOU (2)' block above the table (decision 1)"
else fail "G2: alerts pinned in NEEDS YOU block above the table" "$(printf '%s' "$alert" | head -12)"; fi

# ═══ G3 — decision 3: 50-col narrow frame drops STEP, keeps ROLE/STATE/AGE, never overflows ═══
narrow=$( { rec core fx-core WORKING drafting "drafting a very long step description here" 3 ""
            rec a fx-a DEAD spawned - 0 "report safe; resume unavailable"; } | frame fx 50 0 0 )
th=$(grep 'ROLE' <<<"$narrow" | tail -1 || true)
if grep -q 'STATE' <<<"$th" && grep -q 'AGE' <<<"$th" && ! grep -q 'STEP' <<<"$th" \
   && [ "$(dwidth <<<"$narrow" | sort -n | tail -1)" -le 50 ]; then
  pass "G3: 50 cols — STEP dropped, ROLE/STATE/AGE kept, no line wider than 50 (decision 3)"
else fail "G3: 50-col narrow frame" "header=[$th] maxw=$(dwidth <<<"$narrow" | sort -n | tail -1)"; fi

# ═══ G4 — decision 4: pure-layer colour switch ═══
c0=$(rec core fx-core WORKING drafting step 1 "" | frame fx 72 0 0)
c1=$(rec core fx-core WORKING drafting step 1 "" | frame fx 72 1 0)
if ! grep -q $'\033' <<<"$c0" && grep -q $'\033\\[' <<<"$c1"; then
  pass "G4: colour flag 0 -> no escapes, 1 -> escapes (decision 4)"
else fail "G4: colour flag 0 -> no escapes, 1 -> escapes"; fi

# ═══ G5 — decision 4: ASCII fallback has no non-ASCII bytes and keeps word+symbol ═══
asc=$( { rec core fx-core WORKING drafting "-" 1 ""; rec docs fx-docs FINISHED reported - 1 ""; } | frame fx 60 0 1 )
if ! LC_ALL=C grep -q $'[\x80-\xff]' <<<"$asc" && grep -q 'finished' <<<"$asc"; then
  pass "G5: ASCII mode emits no non-ASCII bytes and still says 'finished' (decision 4)"
else fail "G5: ASCII mode" "$(printf '%s' "$asc" | head -6)"; fi

# ═══ G6 — decision 5: UTF-8 / wide step strings keep every table row the same display width ═══
utf=$( { rec a fx-a WORKING drafting "investigação de fatos" 1 ""
         rec b fx-b WORKING drafting "日本語のステップ説明" 2 ""
         rec c fx-c WORKING drafting "plain ascii step" 3 ""; } | frame fx 72 0 0 )
widths=$(grep -E '^  · |ROLE' <<<"$utf" | dwidth | sort -u | wc -l | tr -d ' ' || true)
nrows=$(grep -cE '^  · ' <<<"$utf" || true)   # guard: 3 data rows must exist, or the width check is vacuous
{ [ "$widths" = 1 ] && [ "$nrows" = 3 ]; } \
  && pass "G6: accented + CJK steps keep all table rows the same display width (decision 5)" \
  || fail "G6: UTF-8 alignment" "distinct row widths=$widths rows=$nrows; frame:
$utf"


# ═══ G7 — decision 63: narrow widths truncate ROLE before dropping STATE/AGE; no line wider than the terminal ═══
longrole=r_abcdefghijklmnop1   # 18 chars
bad=
for cols in 20 30 40 50 72; do
  f=$( { rec "$longrole" fx-x WAITING drafting "needs a decision" 7 ""
         rec "${longrole}b" fx-y DEAD spawned - 2 ""
         rec "${longrole}c" fx-z WORKING drafting "日本語のステップ説明 investigação" 3 ""; } | frame fx "$cols" 0 0 )
  f=${f/@@CLOCK@@/00:00:00}   # the placeholder is 9 wide, the real clock 8: measure the real width
  mw=$(dwidth <<<"$f" | sort -n | tail -1)
  [ "${mw:-999}" -le "$cols" ] || bad+=" cols=$cols:maxwidth=$mw"
  if [ "$cols" -ge 40 ]; then
    # alert rows keep their state WORD (not just the glyph), every table row keeps its AGE
    grep -E 'r_abc' <<<"$f" | sed -n '1,2p' | grep -qiE 'waiting|dead' || bad+=" cols=$cols:alert-word-lost"
    [ "$(grep -cE '^  . r_abc.* [0-9]+m$' <<<"$f")" -ge 1 ] || bad+=" cols=$cols:age-lost"
  fi
done
[ -z "$bad" ] && pass "G7: widths 20-72 with 18-char roles + CJK: no line wider than the terminal; alert rows keep the state word and table rows their AGE at >=40 cols (decision 63)" \
  || fail "G7: narrow-width priority" "$bad"

# ═══ G8 — decision 64: never glyph alone — every state has a distinct ASCII glyph ═══
asc8=$( { for st in FINISHED WORKING WAITING DEAD MODEL_GONE IDLE STALLED UNKNOWN; do rec "r_$st" "fx-r_$st" "$st" drafting step 3 ""; done; } | frame fx 60 0 1 )
glyphs=$(python3 -I - "$asc8" <<'PYG'
import sys
lines = sys.argv[1].split("\n")
hdr = next((i for i, l in enumerate(lines) if "ROLE" in l), len(lines))
out = {}
for i, l in enumerate(lines):
    t = l.split()
    for st in ("FINISHED","WORKING","WAITING","DEAD","MODEL_GONE","IDLE","STALLED","UNKNOWN"):
        if "r_" + st in t:
            k = t.index("r_" + st)
            out[st] = t[k-1] if i < hdr else t[k+1]   # alert rows: glyph before role; table rows: after
for l in lines:   # finished teammates fold into one line led by their glyph
    if l.strip().endswith("1 finished"):
        out["FINISHED"] = l.split()[0]
print(" ".join(f"{k}={v}" for k, v in sorted(out.items())))
PYG
)
n_states=$(wc -w <<<"$glyphs" | tr -d ' ')
n_distinct=$(tr ' ' '\n' <<<"$glyphs" | sed 's/.*=//' | sort -u | wc -l | tr -d ' ')
{ [ "$n_states" = 8 ] && [ "$n_distinct" = 8 ]; } \
  && pass "G8: all 8 states have distinct ASCII glyphs (WAITING vs MODEL_GONE no longer collide) (decision 64)" \
  || fail "G8: ASCII glyph collision" "states=$n_states distinct=$n_distinct :: $glyphs"

# === M*: overall task progress, team ETA, folded finished rows, backlog line ===
# @summary record (from _st_summary): done total pct(-1 none) est(0|1) elapsed_min eta_min(-1) pending unassigned prs
summ() { printf '@summary\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
f=$( { summ 5 8 62 0 23 14 3 0 0; rec core m1-core WORKING investigating "T6: coding" 1 "-"; } | frame m1 100 0 0 )
l1=$(sed -n 1p <<<"$f"); l2=$(sed -n 2p <<<"$f")
{ grep -q '5/8 tasks' <<<"$l1" && grep -q '62%' <<<"$l2" && grep -q 'ETA ~14m' <<<"$l2"; } \
  && pass "M1: header shows done/total tasks; the bar line shows overall % and the team ETA" \
  || fail "M1: headline" "$f"

f=$( { summ 5 8 62 0 23 14 3 0 0; rec core m2-core WORKING investigating "T6: coding" 1 "-"; } | frame m2 24 0 0 )
top=$(sed -n '1,2p' <<<"$f"); over=$(sed -n '2,$p' <<<"$f" | while IFS= read -r l; do [ "$(dwidth "$l")" -gt 24 ] && echo "$l"; done)
{ grep -q '62%' <<<"$top" && grep -q 'ETA ~14m' <<<"$top" && [ -z "$over" ]; } \
  && pass "M2: at 24 columns the % and ETA still show in full and no line overflows" \
  || fail "M2: narrow headline" "over=[$over] $f"

f=$( { summ 2 3 66 0 10 5 1 0 0; rec fa m3-fa FINISHED reported - 1 "-"; rec fb m3-fb FINISHED reported - 1 "-"; rec live m3-live WORKING investigating "T3: x" 1 "-"; } | frame m3 100 0 0 )
{ [ "$(grep -c '2 finished' <<<"$f")" = 1 ] && ! grep -qE '^ +. fa |^ +. fb ' <<<"$f" && grep -qE ' live ' <<<"$f"; } \
  && pass "M3: finished teammates fold into one '2 finished' line instead of a row each" \
  || fail "M3: folded finished" "$f"

f=$( { summ 0 0 -1 0 0 -1 0 0 0; rec a m4-a WORKING spawned - 0 "-"; } | frame m4 100 0 0 2>&1 )
{ ! grep -q 'ETA' <<<"$f" && grep -q 'reported' <<<"$f" && ! grep -qi 'traceback\|error' <<<"$f"; } \
  && pass "M4: no tasks and no % reported: legacy header, no ETA, no crash" \
  || fail "M4: empty summary" "$f"

f=$( { summ 1 3 33 0 5 10 2 1 0; rec idl m5-idl IDLE investigating "T1: done" 3 "-"; } | frame m5 100 0 0 )
grep -q 'idle with work pending' <<<"$f" \
  && pass "M5: an idle teammate while an unassigned task is ready is flagged under NEEDS YOU" \
  || fail "M5: idle with work pending" "$f"

f=$( { summ 2 3 66 0 10 5 1 0 2; rec fa m6-fa FINISHED reported - 1 "-"; rec fb m6-fb FINISHED reported - 1 "-"; rec live m6-live WORKING investigating "x" 1 "-"; } | frame m6 100 0 0 )
grep -q '2 finished · 2 PRs' <<<"$f" && pass "M6: the folded line counts PRs from reports" || fail "M6: PR count" "$f"

f=$( { summ 0 3 10 1 5 45 3 0 0; rec a m9-a WORKING investigating "T1: x · 30%" 1 "-"; } | frame m9 100 0 0 )
grep -q 'backlog: 3 pending · 0 unassigned' <<<"$f" && pass "M9: backlog line shows pending and unassigned tasks" || fail "M9: backlog line" "$f"

f=$( { summ 0 2 20 1 5 20 2 0 0; printf 'a\tm10-a\tWORKING\tinvestigating\tT1: wiring the API · 40%%\t1\t-\t40\t5\n'; } | frame m10 100 0 0 )
{ grep -q 'T1: wiring the API' <<<"$f" && ! grep -q 'API · 40%' <<<"$f" && grep -q ' 40%' <<<"$f"; } \
  && pass "M10: STEP drops the trailing '· NN%' that the PROGRESS column already shows" \
  || fail "M10: step percent dedupe" "$f"

f=$( { summ 3 8 45 1 120 185 5 0 0; rec core m11-core WORKING investigating "T6: coding" 1 "-"; } | frame m11 20 0 0 )
grep -q '~45% · ETA ~3h05m' <<<"$(sed -n 2p <<<"$f")" \
  && pass "M11: at 20 columns the % and a 3h05m ETA still show in full (the bar gives way to nothing)" \
  || fail "M11: 20-col headline" "$f"

# _st_summary end to end: status prefix crediting, legacy task files
summary_of() { # <tasks.md content> <records...> -> @summary line
  local d; d=$(mktemp -d "$W/sum.XXXX"); mkdir -p "$d/reports"; printf '%s' "$1" > "$d/tasks.md"; shift
  printf '%s\n' "$@" | bash -c '. "$1"; _st_summary "$2"' _ "$LIB" "$d" 2>&1
}
r7=$(printf 'w\tm7-w\tWORKING\tinvestigating\tdrafting · 40%%\t1\t-\t40\t10')
got=$(summary_of "$(printf -- '- [ ] T1 m7-w: a\n- [ ] T2 m7-w: b\n')" "$r7")
[ "$(cut -f2-5 <<<"$got")" = "$(printf '0\t2\t20\t1')" ] \
  && pass "M7: a status line without a T<n>: prefix credits its % to the teammate's first open task" \
  || fail "M7: unprefixed credit" "got=[$got]"
got=$(summary_of "$(printf -- '- [x] T1 m13-a:\n- [ ] T2 m13-a:\n')" "$(printf 'a\tm13-a\tWORKING\tinvestigating\tx\t1\t-\t-\t3')")
[ "$(cut -f2-3 <<<"$got")" = "$(printf '1\t2')" ] \
  && pass "M13: a task line with no scope after the colon still counts, as finish counts it" \
  || fail "M13: scopeless task line" "got=[$got]"
r8=$(printf 'a\tm8-a\tWORKING\tinvestigating\tx\t1\t-\t-\t3')
got=$(summary_of "$(printf -- '- [x] m8-a: a\n- [ ] m8-b: b\n- [ ] m8-c: c\n')" "$r8")
[ "$(cut -f2-4 <<<"$got")" = "$(printf '1\t3\t33')" ] \
  && pass "M8: a legacy one-line-per-role tasks.md gives done/total and an overall %" \
  || fail "M8: legacy tasks" "got=[$got]"

# M14: another team's lines in a shared tasks.md do not count; with no team given every line does
summary_team() { # <team> <tasks.md content> <records...>
  local d t=$1; d=$(mktemp -d "$W/sum.XXXX"); mkdir -p "$d/reports"; printf '%s' "$2" > "$d/tasks.md"; shift 2
  printf '%s\n' "$@" | bash -c '. "$1"; _st_summary "$2" "$3"' _ "$LIB" "$d" "$t" 2>&1
}
tm=$(printf -- '- [x] T1 tm2-a: x\n- [ ] T2 tm2-a: y\n- [ ] T3 any: z\n- [x] T4 other-b: w\n- [ ] T5 other-b: v\n')
got=$(summary_team tm2 "$tm" "$(printf 'a\ttm2-a\tWORKING\tinvestigating\tx\t1\t-\t-\t3')")
[ "$(cut -f2-3 <<<"$got")" = "$(printf '1\t3')" ] \
  && pass "M14: _st_summary counts only <team>-* and any owners" \
  || fail "M14: foreign team lines counted" "got=[$got]"
got=$(summary_of "$tm" "$(printf 'a\ttm2-a\tWORKING\tinvestigating\tx\t1\t-\t-\t3')")
[ "$(cut -f3 <<<"$got")" = 5 ] && pass "M14b: with no team every task line counts" || fail "M14b: no-team count" "got=[$got]"

# M15: a live owner with a ready task of its own is listed; a blocked one is not
got=$(summary_team tm2 "$(printf -- '- [ ] T1 tm2-a: x\n- [ ] T2 tm2-b: y - needs: T1\n')" \
  "$(printf 'a\ttm2-a\tIDLE\tinvestigating\tx\t1\t-\t-\t3')" "$(printf 'b\ttm2-b\tIDLE\tinvestigating\tx\t1\t-\t-\t3')")
[ "$(cut -f11 <<<"$got")" = tm2-a ] \
  && pass "M15: @summary lists live owners whose own task is ready (not blocked ones)" \
  || fail "M15: ready owners" "got=[$got]"

# M16: idle teammate with its own ready task is flagged even when nothing is unassigned
f=$( { printf '@summary\t0\t2\t0\t0\t5\t-1\t2\t0\t0\ttm2-a\n'; rec a tm2-a IDLE investigating "T1: waiting" 3 "-"; rec b tm2-b IDLE investigating "T2: waiting" 3 "-"; } | frame m16 100 0 0 )
{ [ "$(grep -c 'idle with work pending' <<<"$f")" = 1 ] && grep -E 'tm2-a|a ' <<<"$f" | grep -q 'idle with work pending'; } \
  && pass "M16: idle teammate with a ready task of its own is flagged 'idle with work pending'" \
  || fail "M16: own ready task" "$f"

# M17 (A2): a ready `any` task that a live teammate has claimed in its status prefix is not unassigned
got=$(summary_team tm2 "$(printf -- '- [ ] T3 any: z\n')" "$(printf 'a\ttm2-a\tWORKING\tinvestigating\tT3: doing it\t1\t-\t-\t3')")
[ "$(cut -f9 <<<"$got")" = 0 ] && pass "M17: a ready any task claimed by a live teammate's T<n>: prefix is not unassigned" \
  || fail "M17: claimed any task" "got=[$got]"
got=$(summary_team tm2 "$(printf -- '- [ ] T3 any: z\n')" "$(printf 'a\ttm2-a\tWORKING\tinvestigating\tidle chat\t1\t-\t-\t3')")
[ "$(cut -f9 <<<"$got")" = 1 ] && pass "M17b: an unclaimed ready any task stays unassigned" || fail "M17b: unclaimed" "got=[$got]"

got=$(summary_team tm2 "$(printf -- '- [ ] T3 any: z\n')" "$(printf 'a\ttm2-a\tIDLE\tinvestigating\tT3: starting\t1\t-\t-\t3')")
[ "$(cut -f11 <<<"$got")" = tm2-a ] && pass "M17c: the live claimant of a ready any task is its ready holder" \
  || fail "M17c: claimant not listed" "got=[$got]"
got=$(summary_team tm2 "$(printf -- '- [ ] T1 tm2-a: x\n')" \
  "$(printf 'a\ttm2-a\tIDLE\tinvestigating\tx\t1\t-\t-\t3')" "$(printf 'b\ttm2-b\tWORKING\tinvestigating\tT1: taking it\t1\t-\t-\t3')")
[ "$(cut -f11 <<<"$got")" = tm2-b ] && pass "M17d: a task claimed by another teammate is no longer the line owner's" \
  || fail "M17d: line owner still listed" "got=[$got]"

# M17e: a reused teammate (own lines all ticked, ms=reported) still claims a ready any task
got=$(summary_team tm2 "$(printf -- '- [x] T1 tm2-a: x\n- [ ] T3 any: z\n')" "$(printf 'a\ttm2-a\tWORKING\treported\tT3: picking it up\t1\t-\t-\t3')")
[ "$(cut -f9 <<<"$got")" = 0 ] && pass "M17e: a reported teammate's claim on a ready any task counts as assigned" \
  || fail "M17e: reported claimant ignored" "got=[$got]"

# M18: team tm does not take team tm-x's lines (a sibling run dir names tm-x)
d=$(mktemp -d "$W/pre.XXXX"); mkdir -p "$d/2026-11-18-tm/reports" "$d/2026-11-18-tm-x"
printf -- '- [ ] T1 tm-a: x\n- [ ] T2 tm-x-a: y\n' > "$d/2026-11-18-tm/tasks.md"
got=$(bash -c '. "$1"; _st_summary "$2" tm' _ "$LIB" "$d/2026-11-18-tm" </dev/null 2>&1)
[ "$(cut -f3 <<<"$got")" = 1 ] && pass "M18: team tm ignores team tm-x's lines when tm-x is a sibling run" \
  || fail "M18: slug prefix collision" "got=[$got]"

# M19 (A1): GNU stat (-f is filesystem mode: junk on stdout, exit 1) must not break ELAPSED/AGE
mkdir -p "$W/gnu"
cat > "$W/gnu/stat" <<'SH'
#!/bin/sh
case $1 in
  -f) echo "  File: \"$3\""; echo "    ID: 0 Namelen: 255 Type: ext2/ext3"; exit 1 ;;
  -c) /usr/bin/stat -c %Y "$3" 2>/dev/null || /usr/bin/stat -f %m "$3" ;;
esac
SH
chmod +x "$W/gnu/stat"
RUNG="$W/gnurun"; mkdir -p "$RUNG/reports" "$RUNG/status"; GR="$W/gnureg"; mkdir -m 700 "$GR"
printf 'x\n' > "$GR/team-g1-w.sysprompt.md"; printf 'T1: x\n' > "$RUNG/status/w.txt"
rec=$(PATH="$W/gnu:$PATH" TEAM_REG_DIR="$GR" bash -c '. "$1"; _reg() { echo "'"$GR"'/team-$1.tabs"; }; _st_row "$2" "$3" "" g1' _ "$LIB" "cmux surface:190 pane g1-w - - $RUNG $W live 9999 $W" "$RUNG" 2>&1 || true)
{ [[ "$(cut -f6 <<<"$rec")" =~ ^[0-9]+$ ]] && [[ "$(cut -f9 <<<"$rec")" =~ ^[0-9]+$ ]]; } \
  && pass "M19: AGE and ELAPSED are integers under a GNU stat" \
  || fail "M19: GNU stat breaks AGE/ELAPSED" "rec=[$rec]"

# ═══ End-to-end fixtures ═══
G="$W/repo"; mkdir -p "$G"; git -C "$G" init -q
RUN="$W/run"; mkdir -p "$RUN/reports" "$RUN/status"
: > "$RUN/tasks.md"
reg_row() {   # backend ref title state(col9|'') -> row; layout pane, no model, rundir=$RUN, root=$G
  local backend=$1 ref=$2 title=$3 state=${4:-}
  if [ -n "$state" ]; then
    printf '%s %s pane %s - - %s %s %s %s %s\n' "$backend" "$ref" "$title" "$RUN" "$G" "$state" "11111111-2222-3333-4444-555555555555" "$G"
  else
    printf '%s %s pane %s - - %s\n' "$backend" "$ref" "$title" "$RUN"     # legacy 7-col row
  fi
}
status_out() { # <team> [env...] -> plain-frame text
  local t=$1; shift
  (cd "$G" && env LC_ALL=$UTF8_LOC TEAM_COLS=100 "$@" bash "$TEAM_SH" status "$t" 2>&1)
}
row_of() { grep -E "^  (·|-) $1 |^ +. $1 " <<<"$2" | head -1; }

# ═══ E1 — decision 8/41: FINISHED (marker set, surface closed, report on disk) renders finished, never dead ═══
printf 'REPORT\nPARALLELISM: none\n' > "$RUN/reports/fin.md"
{ reg_row cmux surface:101 e1-fin finished; } > "$TEAM_REG_DIR/team-e1.tabs"
out=$(status_out e1 CMUX_GONE_REFS="surface:101")
if grep -q 'finished' <<<"$out" && ! grep -qi 'dead' <<<"$out"; then
  pass "E1: finished teammate (marker, closed surface) renders 'finished' and never 'dead' (decisions 8, 41)"
else fail "E1: finished renders finished, not dead" "$out"; fi

# === B1: a reused teammate (report on disk, T1 ticked, T2 open) is working on T2, not reported ===
RUNB="$W/runb"; mkdir -p "$RUNB/reports" "$RUNB/status"
printf 'REPORT\nPARALLELISM: none\n' > "$RUNB/reports/w.md"
printf -- '- [x] T1 b1-w: a\n- [ ] T2 b1-w: b\n' > "$RUNB/tasks.md"
printf 'T2: reading code · 10%%\n' > "$RUNB/status/w.txt"
printf 'cmux surface:120 pane b1-w - - %s %s live 11111111-2222-3333-4444-555555555555 %s\n' "$RUNB" "$G" "$G" > "$TEAM_REG_DIR/team-b1.tabs"
out=$(status_out b1)
r=$(grep -E ' w ' <<<"$out" | head -1)
if [ -n "$r" ] && ! grep -q 'report on disk' <<<"$out" && ! grep -q '1/1 reported' <<<"$out"; then
  pass "B1: report on disk + an open T2 task reads as working on T2, not reported"
else fail "B1: reused teammate not reported" "$out"; fi

# === M12: a reused team slug reads the newest run's tasks.md for the headline, not the first row's ===
RUNO="$W/run-old"; RUNW="$W/run-new"; mkdir -p "$RUNO/reports" "$RUNW/reports" "$RUNW/status"
printf -- '- [x] T1 m12-a: a\n' > "$RUNO/tasks.md"; printf -- '- [ ] T1 m12-b: a\n- [ ] T2 m12-b: b\n' > "$RUNW/tasks.md"
{ printf 'cmux surface:130 pane m12-a - - %s %s finished 1 %s\n' "$RUNO" "$G" "$G"
  printf 'cmux surface:131 pane m12-b - - %s %s live 1 %s\n' "$RUNW" "$G" "$G"; } > "$TEAM_REG_DIR/team-m12.tabs"
out=$(status_out m12)
grep -q '0/2 tasks' <<<"$out" && pass "M12: headline uses the newest run's backlog when a team slug is reused" \
  || fail "M12: stale run summary" "$out"

# ═══ E2 — no report + closed surface + no marker renders dead ═══
{ reg_row cmux surface:102 e2-gone live; } > "$TEAM_REG_DIR/team-e2.tabs"
out=$(status_out e2 CMUX_GONE_REFS="surface:102")
if grep -qi 'dead' <<<"$out" && ! grep -q 'finished' <<<"$out"; then
  pass "E2: no marker + closed surface renders 'dead' (and not finished)"
else fail "E2: closed surface without marker renders dead" "$out"; fi

# ═══ E3 — decision 43: backend != cmux renders unknown, never alive/working ═══
# (tmux rows are a live backend since the tmux fallback; an unknown backend keeps this guarantee)
{ reg_row legacy %7 e3-old live; } > "$TEAM_REG_DIR/team-e3.tabs"
out=$(status_out e3)
if grep -qi 'unknown' <<<"$out" && ! grep -qiE 'working|drafting|spawned' <<<"$out"; then
  pass "E3: non-cmux backend row renders 'unknown', not alive (decision 43)"
else fail "E3: non-cmux backend renders unknown" "$out"; fi

# ═══ E4 — legacy 7-column row (no marker) with a gone surface is dead, never finished (decision 26 compat) ═══
{ reg_row cmux surface:104 e4-legacy; } > "$TEAM_REG_DIR/team-e4.tabs"
out=$(status_out e4 CMUX_GONE_REFS="surface:104")
if grep -qi 'dead' <<<"$out" && ! grep -q 'finished' <<<"$out"; then
  pass "E4: legacy 7-col row, surface gone -> dead, never finished"
else fail "E4: legacy row gone -> dead" "$out"; fi

# ═══ E5 — decision 4 / 48: colour gate is evaluated on the real stdout, with NO_COLOR and TERM=dumb winning ═══
{ reg_row cmux surface:105 e5-a live; } > "$TEAM_REG_DIR/team-e5.tabs"
forced=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=xterm-256color)
nocol=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=xterm-256color NO_COLOR=1)
dumb=$(status_out e5 TEAM_FORCE_COLOR=1 TERM=dumb)
plain=$(status_out e5 TERM=xterm-256color)
if grep -q $'\033\\[' <<<"$forced" && ! grep -q $'\033' <<<"$nocol" \
   && ! grep -q $'\033' <<<"$dumb" && ! grep -q $'\033' <<<"$plain"; then
  pass "E5: escapes only when forced on a colour TERM; NO_COLOR, TERM=dumb and a non-tty all emit none (decisions 4, 48)"
else fail "E5: colour gate" "forced_esc=$(grep -c $'\033' <<<"$forced") nocolor_esc=$(grep -c $'\033' <<<"$nocol") dumb_esc=$(grep -c $'\033' <<<"$dumb") plain_esc=$(grep -c $'\033' <<<"$plain")"; fi

# ═══ E6 — decision 5: end-to-end UTF-8 step stays column-aligned (fails on the old cut -c1-40 table) ═══
printf 'investigação de fatos\n' > "$RUN/status/acc.txt"
printf '日本語のステップ説明\n' > "$RUN/status/cjk.txt"
{ reg_row cmux surface:106 e6-acc live; reg_row cmux surface:107 e6-cjk live; reg_row cmux surface:108 e6-pla live; } > "$TEAM_REG_DIR/team-e6.tabs"
printf 'plain\n' > "$RUN/status/pla.txt"
out=$(status_out e6)
w=$(grep -E '^  · |ROLE' <<<"$out" | dwidth | sort -u | wc -l | tr -d ' ' || true)
nrows=$(grep -cE '^  · ' <<<"$out" || true)
{ [ "$w" = 1 ] && [ "$nrows" = 3 ] && grep -q 'investigação de fatos' <<<"$out"; } \
  && pass "E6: accented/CJK step strings, all rows same display width end to end (decision 5)" \
  || fail "E6: end-to-end UTF-8 alignment" "distinct widths=$w rows=$nrows
$out"


# ═══ E7 — decision 62: a transient cmux failure is UNKNOWN, never DEAD; sync does not log it at error level ═══
{ reg_row cmux surface:110 e7-a live; reg_row cmux surface:111 e7-b live; } > "$TEAM_REG_DIR/team-e7.tabs"
: > "$CMUX_LOG"
out=$(status_out e7 CMUX_ERR_REFS="surface:110 surface:111")
(cd "$G" && env CMUX_ERR_REFS="surface:110 surface:111" bash "$TEAM_SH" sync e7) >/dev/null 2>&1 || true
if grep -qi 'unknown' <<<"$out" && ! grep -qi 'dead' <<<"$out" && ! grep -q 'NEEDS YOU' <<<"$out" \
   && ! grep -E '^log ' "$CMUX_LOG" | grep -q -- '--level error'; then
  pass "E7: 'Error: timeout' from cmux identify renders unknown, no NEEDS YOU, and sync logs nothing at --level error (decision 62)"
else fail "E7: transient failure" "$out
log: $(grep -E '^log ' "$CMUX_LOG" | head -3)"; fi
: > "$CMUX_LOG"
out=$(status_out e7 CMUX_NOTFOUND_REFS="surface:110 surface:111")
(cd "$G" && env CMUX_NOTFOUND_REFS="surface:110 surface:111" bash "$TEAM_SH" sync e7) >/dev/null 2>&1 || true
{ grep -qi 'dead' <<<"$out" && grep -q 'NEEDS YOU' <<<"$out"; } \
  && pass "E7b: control — a definite not_found still renders dead and pins NEEDS YOU" \
  || fail "E7b: not_found is dead" "$out"

# ═══ E8 — decision 65: the clock survives narrow widths (never a stray '@') ═══
{ reg_row cmux surface:120 e8longteamname-a live; } > "$TEAM_REG_DIR/team-e8longteamname.tabs"
bad=
for cols in 24 30 40 55; do
  hl=$(status_out e8longteamname TEAM_COLS=$cols | head -1)
  grep -q '@' <<<"$hl" && bad+=" cols=$cols:stray-@[$hl]"
  grep -qE '[0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$hl" || bad+=" cols=$cols:no-clock[$hl]"
done
[ -z "$bad" ] && pass "E8: header keeps a real HH:MM:SS clock and never a stray '@' at 24-55 cols, with a long team name (decision 65)" \
  || fail "E8: clock at narrow width" "$bad"


# ═══ C1-C5 — workstream C: sidebar pill + severity-coded log, via `team.sh sync` (decisions 13, 14, 21, 22) ═══
sync_run() { (cd "$G" && env "${@:2}" bash "$TEAM_SH" sync "$1" 2>&1) >/dev/null || true; }
RUNC="$G/.team/runs/2026-10-08-c1"; mkdir -p "$RUNC/reports" "$RUNC/status"
{ printf 'cmux surface:130 pane c1-a - - %s %s live 1111 %s\n' "$RUNC" "$G" "$G"
  printf 'cmux surface:131 pane c1-b - - %s %s live 2222 %s\n' "$RUNC" "$G" "$G"; } > "$TEAM_REG_DIR/team-c1.tabs"
: > "$CMUX_LOG"; sync_run c1
pill=$(grep -E '^set-status ' "$CMUX_LOG" | head -1)
pcol=$(sed -n 's/.*--color \(#[0-9A-Fa-f]\{6\}\).*/\1/p' <<<"$pill")
pprio=$(sed -n 's/.*--priority \([0-9][0-9]*\).*/\1/p' <<<"$pill")
if [ -n "$pcol" ] && [ "$(tr a-f A-F <<<"$pcol")" != "#4C8DFF" ] && [ "${pprio:-0}" -ge 1 ] && grep -q -- '--icon' <<<"$pill"; then
  pass "C1: the team pill passes --icon, a non-accent --color (not #4C8DFF) and --priority >= 1 so it outranks the shim's default-0 pill (decisions 13, 21)"
else fail "C1: pill differentiation" "pill=[$pill]"; fi
badlog=$(grep -E '^log ' "$CMUX_LOG" | grep -vE -- '--level (info|progress|success|warning|error)( |$)' || true)
{ grep -qE '^log ' "$CMUX_LOG" && [ -z "$badlog" ]; } \
  && pass "C2: every cmux log call carries an explicit --level (decision 22)" \
  || fail "C2: log levels" "unleveled: $badlog"
: > "$CMUX_LOG"; printf 'x\nPARALLELISM: none\n' > "$RUNC/reports/b.md"; sync_run c1
grep -qE -- '^log .*--level success .*c1-b: reported' "$CMUX_LOG" \
  && pass "C3: a report arriving logs '<title>: reported' at --level success (decision 14)" \
  || fail "C3: report -> success" "$(grep -E '^log ' "$CMUX_LOG")"
: > "$CMUX_LOG"; sync_run c1 CMUX_NOTFOUND_REFS="surface:130"
grep -qE -- '^log .*--level error .*c1-a: dead' "$CMUX_LOG" \
  && pass "C4: a definitely-gone teammate logs '<title>: dead' at --level error (decision 14)" \
  || fail "C4: dead -> error" "$(grep -E '^log ' "$CMUX_LOG")"
: > "$CMUX_LOG"; (cd "$G" && bash "$TEAM_SH" sync --clear c1) >/dev/null 2>&1 || true
{ grep -q '^clear-progress' "$CMUX_LOG" && grep -qE -- '^log .*--level info .*closed' "$CMUX_LOG"; } \
  && pass "C5: sync --clear clears the progress bar and logs 'closed' at --level info (decision 14)" \
  || fail "C5: clear" "$(cat "$CMUX_LOG")"

# ---------------------------------------------------------------------------
# P*  per-teammate self-reported progress, ETA, row keys and click mapping
# ---------------------------------------------------------------------------

# pct is field 8, elapsed-minutes field 9. 70% after 14m -> ~6m remaining.
P_RECS=$'core\tp-core\tWORKING\tdrafting\tdrafting report\t4\t\t70\t14\ntests\tp-tests\tWORKING\tinvestigating\trunning gates\t1\t\t40\t20'
# Same records with no percentage reported at all.
P_NOPCT=$'core\tp-core\tWORKING\tdrafting\tdrafting report\t4\t\t-1\t-1\ntests\tp-tests\tWORKING\tinvestigating\trunning gates\t1\t\t-1\t-1'

f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 0)
{ grep -q 'PROGRESS' <<<"$f" && grep -qE '70%' <<<"$f" && grep -qE '40%' <<<"$f"; }   && pass "P1: a reported '· NN%' renders a PROGRESS column with a per-row bar"   || fail "P1: progress column" "$f"

{ grep -q 'ETA' <<<"$f" && grep -qE '~6m' <<<"$f" && grep -qE '~30m' <<<"$f"; }   && pass "P2: ETA extrapolates elapsed*(100-pct)/pct and is marked '~' (70%@14m -> ~6m)"   || fail "P2: eta" "$f"

f=$(printf '%s\n' "$P_NOPCT" | frame p 100 0 0 0)
{ ! grep -q 'PROGRESS' <<<"$f" && ! grep -q 'ETA' <<<"$f" && grep -q 'STEP' <<<"$f"; }   && pass "P3: no teammate reporting a % renders no PROGRESS/ETA columns (goldens unchanged)"   || fail "P3: columns absent without pct" "$f"

# A 100% row is complete, so it has no remaining time to extrapolate.
f=$(printf 'd\tp-d\tWORKING\tdrafting\tdone\t1\t\t100\t30\n' | frame p 100 0 0 0)
{ grep -q '100%' <<<"$f" && ! grep -qE '~[0-9]+[mh]' <<<"$f"; }   && pass "P4: a 100% row shows the full bar and no ETA"   || fail "P4: 100% has no eta" "$f"

# Narrow: the core columns must still win over PROGRESS/ETA (decisions 63-65).
f=$(printf '%s\n' "$P_RECS" | frame p 40 0 0 0)
{ ! grep -q 'PROGRESS' <<<"$f" && grep -q 'ROLE' <<<"$f" && grep -q 'AGE' <<<"$f"   && [ "$(dwidth <<<"$f" | sort -n | tail -1)" -le 40 ]; }   && pass "P5: at 40 cols PROGRESS/ETA drop and ROLE+STATE+AGE survive, no overflow"   || fail "P5: narrow drops progress" "$f"

# An out-of-range percentage must not produce a bar wider than the column.
f=$(printf 'd\tp-d\tWORKING\tdrafting\tgone wild · 999%%\t1\t\t-1\t5\n' | frame p 100 0 0 0)
[ "$(dwidth <<<"$f" | sort -n | tail -1)" -le 100 ]   && pass "P6: a malformed/oversized percentage cannot overflow the pane width"   || fail "P6: pct clamp" "$f"

# keys=1 (interactive monitor only) numbers the rows and prints the hint line.
f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 1)
{ grep -q '\[1\] ' <<<"$f" && grep -q '\[2\] ' <<<"$f" && grep -q 'focus pane' <<<"$f"; }   && pass "P7: keys=1 numbers each row [N] and shows the keybinding hint"   || fail "P7: row keys" "$f"

f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 0)
{ ! grep -q '\[1\] ' <<<"$f" && ! grep -q 'focus pane' <<<"$f"; }   && pass "P8: keys=0 (one-shot status) keeps the plain bullet and no hint line"   || fail "P8: no keys when non-interactive" "$f"

# The keymap is the contract between the frame and the input loop: key, role,
# state, and the terminal LINE the row was printed on.
KM="$TEAM_REG_DIR/km.tsv"
printf '%s\n' "$P_RECS" | TEAM_KEYMAP_OUT="$KM" frame p 100 0 0 1 >/dev/null
line1=$(awk -F'\t' '$1=="1"{print $4}' "$KM")
f=$(printf '%s\n' "$P_RECS" | frame p 100 0 0 1)
got=$(sed -n "${line1:-0}p" <<<"$f")
{ [ -n "$line1" ] && grep -q '\[1\] ' <<<"$got"; }   && pass "P9: keymap line numbers address the row the frame actually printed"   || fail "P9: keymap line mapping" "line1=$line1 got=[$got]"

# Alerts come first, so keys are numbered across both blocks without collision.
A_RECS=$'t\tp-t\tWAITING\tinvestigating\tneeds input\t2\t\t-1\t-1\nc\tp-c\tWORKING\tdrafting\twork\t1\t\t70\t14'
printf '%s\n' "$A_RECS" | TEAM_KEYMAP_OUT="$KM" frame p 100 0 0 1 >/dev/null
{ [ "$(awk -F'\t' '$1=="1"{print $2}' "$KM")" = t ]   && [ "$(awk -F'\t' '$1=="2"{print $2}' "$KM")" = c ]   && [ "$(wc -l < "$KM" | tr -d ' ')" = 2 ]; }   && pass "P10: row keys run across NEEDS YOU then the table, one key per teammate"   || fail "P10: key ordering" "$(cat "$KM")"

# _st_click: release on a row focuses it; press, wheel, blank lines and junk do not.
clicks=$(LC_ALL=$UTF8_LOC bash -c '
  . "$1"; _st_focus_role() { echo "FOCUS:$2"; return 0; }
  for s in "[<0;9;5m" "[<0;9;99m" "[<0;9;5M" "[<64;9;5m" "junk"; do
    _st_click demo "$2" "$s" >/dev/null 2>&1 && echo "acted:$s" || echo "ignored:$s"
  done' _ "$LIB" "$KM" 2>/dev/null || true)
nacted=$(grep -c '^acted:' <<<"$clicks" || true)
{ [ "$nacted" = 1 ] && grep -q 'acted:\[<0;9;5m' <<<"$clicks"; }   && pass "P11: _st_click acts on a release over a row only — press, wheel, blank line and junk ignored"   || fail "P11: click guards" "$clicks"

# The clamp itself lives in the record layer (_st_row), not the formatter: an
# out-of-range "999%" must become 100 and must not be left in the STEP text.
RUNP="$G/.team/runs/2026-10-08-p1"; mkdir -p "$RUNP/reports" "$RUNP/status"
printf 'cmux surface:140 pane p1-w - - %s %s live 9999 %s\n' "$RUNP" "$G" "$G" > "$TEAM_REG_DIR/team-p1.tabs"
printf 'gone wild \xc2\xb7 999%%\n' > "$RUNP/status/w.txt"
rec=$(LC_ALL=$UTF8_LOC TEAM_REG_DIR="$TEAM_REG_DIR" bash -c '. "$1"; _st_row "$2" "$3" "" p1' _ "$LIB" "cmux surface:140 pane p1-w - - $RUNP $G live 9999 $G" "$RUNP" 2>/dev/null || true)
gotpct=$(cut -f8 <<<"$rec"); gotstep=$(cut -f5 <<<"$rec")
{ [ "${gotpct:-x}" = 100 ] && [ "${gotstep:-x}" = "gone wild" ]; } \
  && pass "P12: record layer clamps '999%' to 100 and strips it from the STEP text" \
  || fail "P12: pct clamp in _st_row" "pct=[$gotpct] step=[$gotstep] rec=[$rec]"

# A percentage the teammate never wrote stays absent (-1), not 0 -- 0% would draw
# an empty bar and claim "no progress", which is a different statement.
printf 'investigating facts\n' > "$RUNP/status/w.txt"
rec=$(LC_ALL=$UTF8_LOC TEAM_REG_DIR="$TEAM_REG_DIR" bash -c '. "$1"; _st_row "$2" "$3" "" p1' _ "$LIB" "cmux surface:140 pane p1-w - - $RUNP $G live 9999 $G" "$RUNP" 2>/dev/null || true)
[ "$(cut -f8 <<<"$rec")" = "-" ] \
  && pass "P13: a status line with no percentage reports pct '-' (absent), never 0" \
  || fail "P13: absent pct" "rec=[$rec]"

# A teammate pane in the default grid is ~80 cols: PROGRESS and ETA must both fit
# there, and ETA must still appear at 56. Fixed 72/84 gates failed this.
for w in 56 70 80; do
  f=$(printf '%s\n' "$P_RECS" | frame p "$w" 0 0 0)
  { grep -q 'PROGRESS' <<<"$f" && grep -q 'ETA' <<<"$f" \
    && [ "$(dwidth <<<"$f" | sort -n | tail -1)" -le "$w" ]; } \
    || { fail "P14: PROGRESS+ETA at $w cols" "$f"; break; }
  [ "$w" = 80 ] && pass "P14: PROGRESS and ETA both fit at 56/70/80 cols without overflow"
done

# ---------------------------------------------------------------------------
# A*  team-average progress on the top bar and the sidebar
# ---------------------------------------------------------------------------

# The case the average exists for: nobody has reported yet, but the team is most
# of the way there. reported/total would say 0%.
A_RECS=$'a\ta-a\tWORKING\tdrafting\tw\t1\t\t80\t10\nb\ta-b\tWORKING\tdrafting\tw\t1\t\t60\t10'
f=$(printf '%s\n' "$A_RECS" | frame a 100 0 0 0)
bar=$(sed -n '2p' <<<"$f")
{ grep -q '0/2 reported' <<<"$f" && grep -q '~70%' <<<"$bar"; } \
  && pass "A1: the top bar shows the team average (80+60)/2 = ~70% while 0/2 have reported" \
  || fail "A1: average bar" "$f"

# A reported teammate counts as 100 even though its status line carries no %.
A_MIX=$'a\ta-a\tWORKING\treported\tdone\t1\t\t-1\t10\nb\ta-b\tWORKING\tdrafting\tw\t1\t\t50\t10'
f=$(printf '%s\n' "$A_MIX" | frame a 100 0 0 0)
grep -q '~75%' <<<"$(sed -n '2p' <<<"$f")" \
  && pass "A2: a reported teammate counts as 100 in the average (100+50)/2 = ~75%" \
  || fail "A2: reported counts as 100" "$f"

# No self-reports anywhere: the bar stays the old reported/total, with no tilde,
# so every pre-existing golden frame is byte-identical.
f=$(printf '%s\n' "$P_NOPCT" | frame p 100 0 0 0)
bar=$(sed -n '2p' <<<"$f")
{ ! grep -q '~' <<<"$bar" && grep -q ' 0%' <<<"$bar"; } \
  && pass "A3: with no self-reported %, the bar falls back to reported/total and drops the ~" \
  || fail "A3: fallback" "[$bar]"

# The sidebar must carry the same number as the pane (one record source).
RUNA="$G/.team/runs/2026-10-08-a1"; mkdir -p "$RUNA/reports" "$RUNA/status"
{ printf 'cmux surface:150 pane a1-x - - %s %s live 1 %s\n' "$RUNA" "$G" "$G"
  printf 'cmux surface:151 pane a1-y - - %s %s live 2 %s\n' "$RUNA" "$G" "$G"; } > "$TEAM_REG_DIR/team-a1.tabs"
printf 'working \xc2\xb7 80%%\n' > "$RUNA/status/x.txt"
printf 'working \xc2\xb7 60%%\n' > "$RUNA/status/y.txt"
: > "$CMUX_LOG"; sync_run a1
prog=$(grep -E '^set-progress ' "$CMUX_LOG" | head -1)
pill=$(grep -E '^set-status ' "$CMUX_LOG" | head -1)
{ grep -q '0\.70' <<<"$prog" && grep -q '~70%' <<<"$pill" && grep -q '0/2 reported' <<<"$pill"; } \
  && pass "A4: the sidebar bar is 0.70 and the pill reads '~70% · 0/2 reported' — same number as the pane" \
  || fail "A4: sidebar average" "prog=[$prog] pill=[$pill]"

# Without any self-report the sidebar keeps its old reported/total fraction.
printf 'investigating facts\n' > "$RUNA/status/x.txt"
printf 'investigating facts\n' > "$RUNA/status/y.txt"
: > "$CMUX_LOG"; sync_run a1
pill=$(grep -E '^set-status ' "$CMUX_LOG" | head -1)
{ ! grep -q '~' <<<"$pill" && grep -q '0/2 reported' <<<"$pill"; } \
  && pass "A5: with no self-reported %, the pill keeps 'N/M reported' and shows no ~average" \
  || fail "A5: sidebar fallback" "pill=[$pill]"

# Tab is IFS whitespace: `read` collapses consecutive tabs, so an empty field
# silently shifts every later field left (this broke the team average once).
# _st_row must therefore never emit an empty field -- absent values use '-'.
RUNN="$G/.team/runs/2026-10-08-n1"; mkdir -p "$RUNN/reports" "$RUNN/status"
printf 'plain step with no note\n' > "$RUNN/status/q.txt"
rec=$(LC_ALL=$UTF8_LOC TEAM_REG_DIR="$TEAM_REG_DIR" bash -c '. "$1"; _reg() { echo "'"$TEAM_REG_DIR"'/team-$1.tabs"; }; _st_row "$2" "$3" "" n1' _ "$LIB" "cmux surface:160 pane n1-q - - $RUNN $G live 1 $G" "$RUNN" 2>/dev/null || true)
nf=$(printf '%s' "$rec" | awk -F'\t' '{print NF}')
empty=$(printf '%s' "$rec" | awk -F'\t' '{for(i=1;i<=NF;i++) if ($i=="") print i}')
{ [ "$nf" = 9 ] && [ -z "$empty" ]; } \
  && pass "N10: _st_row emits 9 fields and never an empty one (tab-collapse shifts fields)" \
  || fail "N10: record field contract" "nf=$nf empty_at=[$empty] rec=[$rec]"

# And the reader must land on the right field: pct, not elapsed.
got=$(printf '%s\n' "$rec" | bash -c 'IFS=$'"'"'\t'"'"' read -r a b c d e f g pct rest; echo "$pct"')
[ "$got" = "-" ] \
  && pass "N11: a positional read of the record lands pct on field 8, not elapsed" \
  || fail "N11: field alignment" "pct=[$got] rec=[$rec]"

# ---------------------------------------------------------------------------
# AC*  the monitor closes itself once every teammate is finished
# ---------------------------------------------------------------------------

RUNAC="$G/.team/runs/2026-10-08-ac"; mkdir -p "$RUNAC/reports" "$RUNAC/status"
printf 'working\n' > "$RUNAC/status/w.txt"
acreg="$TEAM_REG_DIR/team-ac.tabs"

# Already finished when the monitor opens: it must STAY open, otherwise asking
# for the pane on a completed run would make it vanish immediately.
printf 'cmux surface:170 pane ac-w - - %s %s finished - -\n' "$RUNAC" "$G" > "$acreg"
( cd "$G" && TEAM_REG_DIR="$TEAM_REG_DIR" TEAM_STATUS_INTERVAL=1 TEAM_MONITOR_CLOSE_GRACE=0 \
    tmo 4 bash "$TEAM_SH" status --watch ac >/dev/null 2>&1 ); rc=$?
[ "$rc" = 124 ] \
  && pass "AC1: a run already all-finished keeps the monitor open (no self-close on open)" \
  || fail "AC1: closed on open" "exit=$rc (124 = still running, as required)"

# Transition from live to finished: it must print the notice and exit 0.
printf 'cmux surface:170 pane ac-w - - %s %s live - -\n' "$RUNAC" "$G" > "$acreg"
( sleep 2; printf 'cmux surface:170 pane ac-w - - %s %s finished - -\n' "$RUNAC" "$G" > "$acreg" ) &
flip=$!
acout=$( cd "$G" && TEAM_REG_DIR="$TEAM_REG_DIR" TEAM_STATUS_INTERVAL=1 TEAM_MONITOR_CLOSE_GRACE=0 \
    tmo 12 bash "$TEAM_SH" status --watch ac 2>&1 ); rc=$?
wait "$flip" 2>/dev/null || true
{ [ "$rc" = 0 ] && grep -q 'all teammates finished' <<<"$acout"; } \
  && pass "AC2: when the last teammate finishes the monitor announces it and exits 0" \
  || fail "AC2: no self-close on transition" "exit=$rc out=[$(tail -3 <<<"$acout")]"

# The opt-out must hold the pane open through the same transition.
printf 'cmux surface:170 pane ac-w - - %s %s live - -\n' "$RUNAC" "$G" > "$acreg"
( sleep 2; printf 'cmux surface:170 pane ac-w - - %s %s finished - -\n' "$RUNAC" "$G" > "$acreg" ) &
flip=$!
( cd "$G" && TEAM_REG_DIR="$TEAM_REG_DIR" TEAM_STATUS_INTERVAL=1 TEAM_MONITOR_AUTOCLOSE=0 \
    tmo 6 bash "$TEAM_SH" status --watch ac >/dev/null 2>&1 ); rc=$?
wait "$flip" 2>/dev/null || true
[ "$rc" = 124 ] \
  && pass "AC3: TEAM_MONITOR_AUTOCLOSE=0 keeps the pane open after everyone finishes" \
  || fail "AC3: opt-out ignored" "exit=$rc (124 = still running, as required)"

# TM1: the perl fallback of tmo returns 124 on expiry and the command's own status otherwise
rc1=$( (PATH="$W/nobin:/usr/bin:/bin"; mkdir -p "$W/nobin"; tmo 1 sleep 5; echo $?) 2>/dev/null | tail -1)
rc2=$( (PATH="$W/nobin:/usr/bin:/bin"; tmo 5 sh -c 'exit 3'; echo $?) 2>/dev/null | tail -1)
{ [ "$rc1" = 124 ] && [ "$rc2" = 3 ]; } && pass "TM1: tmo returns 124 on expiry and the command's status otherwise" || fail "TM1: tmo" "rc1=$rc1 rc2=$rc2"

# AQ1 (A3): pressing q in a tty monitor exits 0. The EXIT trap read sub_status's locals after it
# returned; under `set -u` that trap died ("km: unbound variable") and turned the exit into 1.
RUNAQ="$G/.team/runs/2026-10-08-aq"; mkdir -p "$RUNAQ/reports" "$RUNAQ/status"
printf 'cmux surface:171 pane aq-w - - %s %s live - -\n' "$RUNAQ" "$G" > "$TEAM_REG_DIR/team-aq.tabs"
aqrc=$(cd "$G" && TEAM_SH="$TEAM_SH" TEAM_STATUS_INTERVAL=1 python3 -I - <<'PY' 2>&1
import fcntl, os, pty, select, struct, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    os.execvp('bash', ['bash', os.environ['TEAM_SH'], 'status', '--watch', 'aq'])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
time.sleep(3)
for _ in range(60):
    try: os.write(fd, b'q')   # re-send: a key typed between two reads waits for the next one
    except OSError: pass
    while select.select([fd], [], [], 0.5)[0]:   # drain, or a full tty buffer blocks the monitor
        try:
            if not os.read(fd, 65536): break
        except OSError: break
    r, st = os.waitpid(pid, os.WNOHANG)
    if r:
        print(os.waitstatus_to_exitcode(st)); sys.exit(0)
os.kill(pid, 9); print('hung')
PY
)
[ "$aqrc" = 0 ] && pass "AQ1: q in the tty monitor exits 0" || fail "AQ1: q exit status" "rc=[$aqrc]"

echo; echo "status-render: $passes passed, $fails failed"
[ "$fails" = 0 ] || exit 1
echo "all passed ($passes cases)"
