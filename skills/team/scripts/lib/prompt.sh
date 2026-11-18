#!/usr/bin/env bash
# Teammate prompt rendering (sourced by team.sh after its helpers; functions only).
# sub_prompt renders references/prompt-template.md for one teammate to stdout.

# Usage: prompt <team> <role> --task T<n> --lead <name> --brief <file>
#          [--build] [--no-gate] [--tl <name>] [--run <dir>] [--branch <name>]
sub_prompt() {
  _need_py
  local team=${1:-} role=${2:-}
  [ -n "$team" ] && [ -n "$role" ] || { echo "usage: team.sh prompt <team> <role> --task T<n> --lead <name> --brief <file> [--build] [--no-gate] [--tl <name>] [--run <dir>] [--branch <name>]" >&2; return 2; }
  shift 2
  local task='' lead='' brief='' build=0 gate=1 tl='' run='' branch=''
  while [ $# -gt 0 ]; do
    case $1 in
      --task) task=${2:-}; shift 2 ;;
      --lead) lead=${2:-}; shift 2 ;;
      --brief) brief=${2:-}; shift 2 ;;
      --tl) tl=${2:-}; shift 2 ;;
      --run) run=${2:-}; shift 2 ;;
      --branch) branch=${2:-}; shift 2 ;;
      --build) build=1; shift ;;
      --no-gate) gate=0; shift ;;
      *) echo "prompt: unknown option '$1'" >&2; return 2 ;;
    esac
  done
  [[ $task =~ ^T[0-9]+$ ]] || { echo "prompt: --task T<n> is required" >&2; return 2; }
  [ -n "$lead" ] || { echo "prompt: --lead <name> is required" >&2; return 2; }
  [ -f "$brief" ] || { echo "prompt: --brief <file> must be a readable file" >&2; return 2; }
  _validate_role_name "$role" || return $?
  local root skilldir skillcmd tpl
  # $here is set by team.sh before it sources this lib
  root=$(_root)
  # shellcheck disable=SC2154
  skilldir=$(cd "$here/.." && pwd); tpl="$skilldir/references/prompt-template.md"
  # The teammate allowlist pre-approves only the tilde form of the facts-lint and status commands, so the
  # commands use it when the skill is installed there; file paths stay absolute (the Read tool needs that).
  skillcmd=$skilldir
  # shellcheck disable=SC2088 # the literal ~ is the point: the allowlist matches it
  [ "$skilldir" = "$HOME/.claude/skills/team" ] && skillcmd='~/.claude/skills/team'
  [ -f "$tpl" ] || { echo "prompt: $tpl is missing" >&2; return 3; }
  if [ -z "$run" ]; then
    run=$(ls -d "$root"/.team/runs/*-"$team" 2>/dev/null | tail -1 || true)
    [ -n "$run" ] || { echo "prompt: no run dir $root/.team/runs/*-$team (pass --run)" >&2; return 3; }
  fi
  run=$(cd "$run" 2>/dev/null && pwd) || { echo "prompt: --run dir not found" >&2; return 3; }
  [ -f "$run/tasks.md" ] || { echo "prompt: $run/tasks.md is missing" >&2; return 3; }
  grep -qE "^- \[.\] $task " "$run/tasks.md" || { echo "prompt: $task is not a task line in $run/tasks.md" >&2; return 2; }
  [ -n "$branch" ] || branch="team/$team-$role"
  [ -n "$tl" ] || tl=$lead

  # Roster: the backlog header lines "<team>-<role> — model: ..." (no checkbox).
  local roster
  roster=$(grep -oE "^$team-[a-z0-9-]+ — model" "$run/tasks.md" | sed 's/ — model//; s/.*/`&`/' | paste -sd, - | sed 's/,/, /g' || true)
  [ -n "$roster" ] || { echo "prompt: no '$team-<role> — model: …' header lines in $run/tasks.md" >&2; return 2; }

  # Role spec (if any): the file minus its title and the Preferred tier paragraph.
  local lens='' rf
  if rf=$(sub_role "$role" 2>/dev/null); then
    lens=$(awk 'NR==1 && /^# /{next} /^\*\*Preferred tier/{skip=1; next} skip && /^$/{skip=0; next} !skip' "$rf")
    lens="
## Role

$lens
"
  fi

  local gate_note='' tl_note=''
  [ "$build$gate" = 11 ] && gate_note=" (the no-mistakes gate above is the one exception: run it as told, it pushes your branch for you)"
  [ "$tl" != "$lead" ] && tl_note=" (and to \`$tl\`)"

  # Conditional blocks first ({{if X}} / {{else}} / {{end}}, nestable, one marker per line), then values.
  awk -v build="$build" -v gate="$gate" '
    function active(  i) { for (i = 1; i <= d; i++) if (!on[i]) return 0; return 1 }
    /^\{\{if [a-z]+\}\}$/ { v = $0; gsub(/[{}]|if /, "", v); d++; on[d] = (v=="build" ? build : v=="gate" ? gate : 0); next }
    /^\{\{else\}\}$/ { on[d] = !on[d]; next }
    /^\{\{end\}\}$/ { d--; next }
    active() { print }
  ' "$tpl" | BRIEF=$(cat "$brief") LENS=$lens python3 -c '
import os, sys
a = dict(team=sys.argv[1], role=sys.argv[2], lead=sys.argv[3], tl=sys.argv[4], root=sys.argv[5], run=sys.argv[6],
         skilldir=sys.argv[7], skillcmd=sys.argv[14], task=sys.argv[8], worktree=sys.argv[9], branch=sys.argv[10], roster=sys.argv[11],
         gate_note=sys.argv[12], tl_note=sys.argv[13], brief=os.environ["BRIEF"], lens=os.environ["LENS"])
s = sys.stdin.read()
import re
# One pass over the template, so text inside the brief or the role is never expanded again.
print(re.sub(r"\{\{([a-z_]+)\}\}", lambda m: a.get(m.group(1), m.group(0)), s), end="")
' "$team" "$role" "$lead" "$tl" "$root" "$run" "$skilldir" "$task" "$root/.team/worktrees/$team-$role" "$branch" "$roster" "$gate_note" "$tl_note" "$skillcmd"
}
