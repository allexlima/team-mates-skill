#!/usr/bin/env bash
# Hermetic tests for `team.sh prompt` (lib/prompt.sh + references/prompt-template.md).
# Runs the real team.sh in a scratch git repo; never opens a pane.
#   bash tests/prompt.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TS="$HERE/skills/team/scripts/team.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fails=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1${2:+ — $2}"; fails=$((fails+1)); }
unset TEAM_MEMBER

R="$W/repo"; RUN="$R/.team/runs/2026-01-01-tt"
mkdir -p "$RUN" "$R/.team/roles"; git -C "$R" init -q
printf 'tt-a — model: sonnet — spec: new\ntt-b — model: opus — spec: new\n- [ ] T1 tt-a: x — owns: f — needs: -\n' > "$RUN/tasks.md"
printf 'GOAL-LINE {{role}} {{lead}}\n' > "$W/brief.md"
printf '# a\n\n**Lens:** LENS-TEXT\n\n**Preferred tier:** sonnet\n\n**Lessons:** LESSON-TEXT\n' > "$R/.team/roles/a.md"
P() { (cd "$R" && TEAM_ROLES_DIR="$W/nolib" bash "$TS" prompt tt a --task T1 --lead 'lead [ab12]' --brief "$W/brief.md" "$@"); }

out=$(P --build)
case $out in *'{{if'*|*'{{end'*|*'{{else'*) fail "P1: no template markers left" ;; *) pass "P1: no template markers left" ;; esac
case $out in *'`tt-a` on a team led by `lead [ab12]`'*'`tt-a`, `tt-b`'*) pass "P2: names, lead and roster filled" ;; *) fail "P2: names, lead and roster filled" ;; esac
case $out in *'GOAL-LINE {{role}} {{lead}}'*) pass "P3: the brief is inserted verbatim, not re-expanded" ;; *) fail "P3: the brief is inserted verbatim, not re-expanded" ;; esac
case $out in *LENS-TEXT*LESSON-TEXT*) pass "P4: role spec included" ;; *) fail "P4: role spec included" ;; esac
case $out in *'Preferred tier'*) fail "P5: tier line left out" ;; *) pass "P5: tier line left out" ;; esac
case $out in *"$R/.team/runs/2026-01-01-tt/status/a.txt"*) pass "P6: absolute run paths use the bare role" ;; *) fail "P6: absolute run paths use the bare role" ;; esac
case $out in *'git worktree'*'team/tt-a'*'gate it:'*) pass "P7: --build adds worktree, branch and gate rules" ;; *) fail "P7: --build adds worktree, branch and gate rules" ;; esac
out=$(P)
case $out in *'git worktree'*|*'gate it:'*|*git-practices*) fail "P8: no build rules without --build" ;; *) pass "P8: no build rules without --build" ;; esac
out=$(P --build --no-gate)
case $out in *"don't push"*) case $out in *'gate it:'*) fail "P9: --no-gate leaves commits on the branch" ;; *) pass "P9: --no-gate leaves commits on the branch" ;; esac ;; *) fail "P9: --no-gate leaves commits on the branch" ;; esac
out=$(P --tl tt-tl)
case $out in *'(and to `tt-tl`)'*) pass "P10: --tl is copied on the report" ;; *) fail "P10: --tl is copied on the report" ;; esac
set +e
P --task T9 >/dev/null 2>&1; rc=$?; [ "$rc" = 2 ] && pass "P11: a task id not in tasks.md exits 2" || fail "P11: a task id not in tasks.md exits 2" "rc=$rc"
(cd "$R" && bash "$TS" prompt tt a --lead l --brief "$W/brief.md" >/dev/null 2>&1); rc=$?; [ "$rc" = 2 ] && pass "P12: missing --task exits 2" || fail "P12: missing --task exits 2" "rc=$rc"
(cd "$R" && bash "$TS" prompt tt a --task T1 --lead l --brief "$W/none.md" >/dev/null 2>&1); rc=$?; [ "$rc" = 2 ] && pass "P13: unreadable --brief exits 2" || fail "P13: unreadable --brief exits 2" "rc=$rc"
(cd "$R" && bash "$TS" prompt zz a --task T1 --lead l --brief "$W/brief.md" >/dev/null 2>&1); rc=$?; [ "$rc" = 3 ] && pass "P14: no run dir for the team exits 3" || fail "P14: no run dir for the team exits 3" "rc=$rc"
set -e
echo; [ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
