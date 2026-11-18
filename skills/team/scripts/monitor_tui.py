#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["textual>=1.0"]
# ///
"""Team-mates monitor: a full-screen TUI for a /team run.

It reads one source of truth, `team.sh status --json --sync <team>` (state detection,
the tasks.md parser and the sidebar sync all stay in lib/status.sh), and adds what a
terminal UI can: a live card per teammate, a forecast that follows the backlog's
dependencies and the team's parallelism, token and context use read from each
teammate's own Claude Code transcript, an event log and a per-teammate detail view.

`team.sh status --watch` (the monitor pane) runs it when Textual or uv is present:
    python3 monitor_tui.py --team <team> --team-sh <path/to/team.sh>
    uv run --script monitor_tui.py --team <team> --team-sh <path/to/team.sh>
    python3 monitor_tui.py --demo                 # a synthetic team, nothing to set up
Exit codes: 0 quit, 2 Textual missing, 4 every teammate finished (the caller closes
the pane), 5 the team was closed (no registry left).

Everything above the UI section is stdlib-only: the forecast, the history and the
transcript reader are tested without Textual (`--selftest`).
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import random
import re
import statistics
import subprocess
import sys
import time
from collections import deque
from datetime import datetime

# ── palette and states: the same four roles and glyphs as the classic monitor ──────────
PAL = {"alert": "#FF453A", "active": "#AF52DE", "done": "#30D158", "dim": "#8E8E93",
       "accent": "#4C8DFF", "warn": "#FF9F0A", "track": "#2A2C3A", "text": "#E6E6EB"}
#           token          glyph  word          palette role
STATES = {"WAITING":     ("⏸", "waiting",     "alert"),
          "MODEL_GONE":  ("⚠", "model gone",  "alert"),
          "DEAD":        ("✗", "dead",        "alert"),
          "STALLED":     ("⧗", "stalled?",    "alert"),
          "WORKING":     ("◐", "working",     "active"),
          "IDLE":        ("◌", "idle",        "dim"),
          "UNKNOWN":     ("?", "unknown",     "dim"),
          "FINISHED":    ("✓", "finished",    "done")}
ORDER = list(STATES)
HINT = {"WAITING": "used AskUserQuestion: answer in its pane, remind it to send NEEDS INPUT",
        "MODEL_GONE": "its model is no longer offered: respawn with another",
        "DEAD": "session exited: respawn it",
        "STALLED": "no status update for 10 min: look at its pane"}
SPIN = "◐◓◑◒"
EXIT_QUIT, EXIT_NO_TEXTUAL, EXIT_ALL_FINISHED, EXIT_TEAM_CLOSED = 0, 2, 4, 5
GONE_STATES = ("FINISHED", "DEAD", "MODEL_GONE")


# ── small formatters ──────────────────────────────────────────────────────────────────
def fmt_dur(sec):
    if sec is None:
        return "—"
    sec = max(0, int(round(sec)))
    if sec < 60:
        return f"{sec}s"
    m = sec // 60
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}m"


def fmt_tok(n):
    if not n:
        return "—"
    if n >= 1_000_000:
        return f"{n / 1e6:.1f}M"
    if n >= 1000:
        return f"{n / 1e3:.0f}k"
    return str(n)


def short_model(m):
    """claude-sonnet-4-6 -> 'sonnet 4.6'; an alias stays as it is."""
    if not m:
        return ""
    s = m.lower()
    for tier in ("opus", "sonnet", "haiku", "fable", "mythos"):
        if tier in s:
            v = re.findall(r"(?<!\d)(\d{1,2})[-.](\d{1,2})(?!\d)", s)
            return tier + (f" {v[-1][0]}.{v[-1][1]}" if v else "")
    return m.split("/")[-1][:16]


def pctl(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    f, c = math.floor(k), math.ceil(k)
    return xs[f] + (xs[c] - xs[f]) * (k - f)


def task_num(tid):
    m = re.match(r"T(\d+)$", tid or "")
    return int(m.group(1)) if m else 10 ** 6


def overall_pct(doc):
    """The headline %: overall task progress when tasks.md has task lines (status --json
    computes it), else the teammates' average self-reported % (reported/finished = 100)."""
    s = doc.get("summary") or {}
    if s.get("total", 0) > 0 and s.get("pct", -1) >= 0:
        return s["pct"], bool(s.get("est"))
    eff = []
    for m in doc.get("teammates", []):
        if m["state"] == "FINISHED" or m["milestone"] == "reported":
            eff.append(100)
        elif m.get("pct") is not None:
            eff.append(m["pct"])
    return (sum(eff) // len(eff), True) if eff else (0, False)


# ── history: what the monitor has watched happen (persisted per run) ─────────────────
class History:
    """Samples of each teammate's (task, %) over time, task start/done times, and events.

    Only what the monitor itself observed gets a timestamp. A task already done when the
    monitor attached has no known duration, so it never skews the forecast."""

    def __init__(self, path=None):
        self.path = path
        self.samples = {}      # title -> deque[(t, task, pct)]
        self.task_start = {}   # task id -> t
        self.task_done = {}    # task id -> t, or None when it finished unobserved
        self.last = {}         # title -> (state, milestone, task)
        self.events = deque(maxlen=300)   # (t, level, text)
        self._attached = False
        if path:
            self._load()

    def _load(self):
        try:
            with open(self.path, encoding="utf-8") as fh:
                lines = fh.readlines()[-5000:]
        except OSError:
            return
        for line in lines:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            k, t = e.get("k"), e.get("t", 0)
            if k == "s":
                self.samples.setdefault(e["title"], deque(maxlen=720)).append((t, e.get("task"), e.get("pct")))
            elif k == "start":
                self.task_start.setdefault(e["task"], t)
            elif k == "done":
                self.task_done[e["task"]] = e.get("at", t)
            elif k == "ev":
                self.events.append((t, e.get("level", "info"), e.get("text", "")))

    def _write(self, rec):
        if not self.path:
            return
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
        except OSError:
            self.path = None   # read-only run dir: keep going in memory

    def _event(self, t, level, text, new):
        self.events.append((t, level, text))
        self._write({"k": "ev", "t": t, "level": level, "text": text})
        new.append((t, level, text))

    def observe(self, doc, now):
        """Fold one status document in; return the events it produced."""
        new = []
        tasks = {t["id"]: t for t in doc.get("tasks", [])}
        owner_of = {t["id"]: t["owner"] for t in tasks.values()}
        for tid, t in tasks.items():
            if t["done"] and tid not in self.task_done:
                at = now if self._attached else None
                self.task_done[tid] = at
                self._write({"k": "done", "t": now, "task": tid, "at": at})
                if self._attached:
                    self._event(now, "success", f"✓ {tid} done ({owner_of.get(tid, '?')})", new)
        for m in doc.get("teammates", []):
            title, tid, pct = m["title"], m.get("task"), m.get("pct")
            started = m["state"] == "WORKING" or pct is not None
            if tid in tasks and not tasks[tid]["done"] and tid not in self.task_start and started:
                # Attached mid-task: `elapsed_min` counts from the teammate's spawn, so it is this
                # task's age only for a teammate on its first task. Otherwise the start is unknown.
                first = on_first_task(tasks.values(), title)
                start = now if self._attached else (now - (m.get("elapsed_min") or 0) * 60 if first else None)
                self.task_start[tid] = start
                self._write({"k": "start", "t": start, "task": tid})
            s = self.samples.setdefault(title, deque(maxlen=720))
            if pct is not None and tid and (not s or (s[-1][1], s[-1][2]) != (tid, pct)):
                s.append((now, tid, pct))
                self._write({"k": "s", "t": now, "title": title, "task": tid, "pct": pct})
            cur = (m["state"], m["milestone"], tid)
            prev = self.last.get(title)
            self.last[title] = cur
            if prev is None:
                if self._attached:
                    self._event(now, "info", f"＋ {m['role']} joined", new)
                continue
            if prev[0] != cur[0]:
                word = STATES.get(cur[0], ("", cur[0].lower(), "dim"))[1]
                role = STATES.get(cur[0], ("", "", "dim"))[2]
                lvl = {"alert": "error", "done": "success"}.get(role, "info")
                self._event(now, lvl, f"{m['role']}: {STATES.get(prev[0], ('', prev[0].lower()))[1]} → {word}", new)
            if prev[1] != "reported" and cur[1] == "reported" and cur[0] != "FINISHED":
                self._event(now, "success", f"{m['role']} reported", new)
            if tid and prev[2] and tid != prev[2]:
                self._event(now, "info", f"{m['role']} picked up {tid}", new)
        self._attached = True
        return new

    def spark(self, title, n=40):
        """The teammate's last n self-reported % samples, oldest first (task switches reset)."""
        return [p for _, _, p in list(self.samples.get(title, ()))[-n:] if p is not None]

    def rate(self, title, tid, pct_now, now, window=900):
        """Recent progress rate in %/s for this task, or None without enough signal."""
        pts = [(t, p) for t, k, p in self.samples.get(title, ()) if k == tid and p is not None and now - t <= window]
        if not pts or pct_now is None:
            return None
        t0, p0 = pts[0]
        if now - t0 < 45 or pct_now <= p0:
            return None
        return (pct_now - p0) / (now - t0)

    def durations(self):
        out = []
        for tid, end in self.task_done.items():
            start = self.task_start.get(tid)
            if end is not None and start is not None and end > start:
                out.append(end - start)
        return out


def on_first_task(tasks, title):
    """True when `title`'s spawn age is its current task's age: it has finished no task.
    An `any` task does not say who finished it, so any done `any` task makes it unknown."""
    return not any(t["done"] and t["owner"] in (title, "any") for t in tasks)


# ── forecast: list-scheduling the backlog over the live teammates ─────────────────────
def forecast(doc, hist, now):
    """Estimate when the backlog is done, with a range.

    Each live teammate finishes its current task at a time projected from its own %
    (a blend of the run-long linear rate and the recent rate the monitor observed). Every
    other open task gets a typical duration (the median of durations observed so far and of
    projected totals of tasks in flight) and is scheduled on the teammate that frees up
    first and may take it, after its `needs:` are done. The range reruns the schedule
    with the 25th and 75th percentile durations. All inputs are self-reported, so this is
    an estimate, and the UI says so."""
    tasks = {t["id"]: t for t in doc.get("tasks", []) if t["id"].startswith("T")}
    mates = doc.get("teammates", [])
    live = [m for m in mates if m["state"] not in GONE_STATES]
    out = {"eta": None, "lo": None, "hi": None, "per_task": {}, "per_mate": {}, "method": "none",
           "typical": None}
    if not tasks:
        # No backlog: each teammate's own linear projection; the team ends with the slowest.
        for m in live:
            pct, el = m.get("pct"), m.get("elapsed_min")
            if pct and 0 < pct < 100 and el:
                out["per_mate"][m["title"]] = el * 60 * (100 - pct) / pct
        if out["per_mate"]:
            eta = max(out["per_mate"].values())
            out.update(eta=eta, lo=eta * 0.7, hi=eta * 1.5, method="linear")
        return out
    if all(t["done"] for t in tasks.values()):
        out.update(eta=0, lo=0, hi=0, method="done")
        return out

    def needs_met(t):
        return all(n not in tasks or tasks[n]["done"] for n in t["needs"])

    active, projected = {}, []
    for m in live:
        tid, pct = m.get("task"), m.get("pct")
        if tid not in tasks or tasks[tid]["done"] or tid in active:
            continue
        if not needs_met(tasks[tid]) and not pct:
            continue   # an idle teammate parked on a blocked task is not working on it yet
        start = hist.task_start.get(tid) if hist else None
        unknown = False
        if start is None:
            if (hist and tid in hist.task_start) or not on_first_task(tasks.values(), m["title"]):
                unknown, start = True, now   # spawn time says nothing about this task's age
            else:
                start = now - (m.get("elapsed_min") or 0) * 60
        spent = max(1.0, now - start)
        rem = None
        if unknown:
            pass   # no age to project from: the typical duration below stands in
        elif pct is not None and 0 < pct < 100:
            lin = spent * (100 - pct) / pct
            rate = hist.rate(m["title"], tid, pct, now) if hist else None
            rem = lin if rate is None else 0.5 * lin + 0.5 * (100 - pct) / rate
            if pct >= 10:
                projected.append(spent * 100 / pct)
        elif pct is not None and pct >= 100:
            rem = 0.0
        active[tid] = [m["title"], rem, spent, pct if unknown else None]

    observed = hist.durations() if hist else []
    pool = observed + projected
    if pool:
        typ = statistics.median(pool)
        if len(pool) >= 3:
            lo_d, hi_d = pctl(pool, 0.25), pctl(pool, 0.75)
        else:
            lo_d, hi_d = typ * 0.7, typ * 1.5
        out["method"] = "observed" if len(observed) >= 2 else "projected"
    else:
        s = doc.get("summary") or {}
        el = (s.get("elapsed_min") or 0) * 60
        if s.get("done", 0) > 0 and el > 0:
            typ = el * max(1, len(live)) / s["done"]
            lo_d, hi_d = typ * 0.6, typ * 1.8
            out["method"] = "rough"
        else:
            return out   # nothing to go on yet: no ETA rather than a made-up one
    out["typical"] = typ
    for tid, a in active.items():
        if a[1] is None:
            left = typ * (100 - a[3]) / 100 if a[3] is not None else typ - a[2]
            a[1] = max(left, 0.15 * typ)

    def schedule(dur, scale):
        free = {m["title"]: 0.0 for m in live}
        end = {tid: 0.0 for tid, t in tasks.items() if t["done"]}
        for tid, (title, rem, *_) in active.items():
            end[tid] = rem * scale
            free[title] = max(free.get(title, 0.0), rem * scale)
        if not free:
            free = {"(next spawn)": 60.0}   # the lead has to start someone first
        pending = sorted((t for tid, t in tasks.items() if not t["done"] and tid not in active),
                         key=lambda t: task_num(t["id"]))
        while pending:
            pick = None
            for t in pending:
                needs = [n for n in t["needs"] if n in tasks]
                if all(n in end for n in needs):
                    pick = (t, max([end[n] for n in needs] + [0.0]))
                    break
            if pick is None:   # a cycle or a typo in needs: take the first, ignore its needs
                pick = (pending[0], max(end.values(), default=0.0))
            t, ready = pick
            cands = [t["owner"]] if t["owner"] in free else list(free)
            w = min(cands, key=lambda w: max(free[w], ready))
            end[t["id"]] = max(free[w], ready) + dur
            free[w] = end[t["id"]]
            pending.remove(t)
        return end

    mid = schedule(typ, 1.0)
    out["per_task"] = {tid: e for tid, e in mid.items() if not tasks[tid]["done"]}
    out["per_mate"] = {a[0]: a[1] for a in active.values()}
    out["eta"] = max(out["per_task"].values(), default=0.0)
    out["lo"] = max((e for tid, e in schedule(lo_d, 0.8).items() if not tasks[tid]["done"]), default=0.0)
    out["hi"] = max((e for tid, e in schedule(hi_d, 1.3).items() if not tasks[tid]["done"]), default=0.0)
    return out


# ── transcripts: tokens, context and the tool in flight, from Claude Code's own log ──────
def _parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def _tool_brief(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        return (inp.get("command") or "").split("\n")[0][:60]
    for key in ("file_path", "path", "notebook_path"):
        if inp.get(key):
            return os.path.basename(str(inp[key]))
    for key in ("description", "pattern", "url", "query", "prompt"):
        if inp.get(key):
            return str(inp[key]).split("\n")[0][:60]
    return ""


class Transcript:
    """Incremental reader of ~/.claude/projects/*/<session-id>.jsonl (read-only).

    Usage blocks repeat once per content block of a message, so input/cache tokens are
    counted once per message id and output tokens take the largest value seen."""

    def __init__(self, session_id, root=None, model_hint=""):
        self.sid = session_id
        self.hint = model_hint   # registry model id: transcripts drop its `[1m]` suffix
        self.root = root or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
        self.path, self.off, self.buf, self._next_look = None, 0, "", 0.0
        self.msgs = {}           # message id -> [input+cache tokens, output tokens]
        self.ctx = 0
        self.model = ""
        self.last_ts = None
        self.pending = {}        # tool_use id -> (name, brief, ts)
        self.recent = deque(maxlen=60)   # (ts, name, brief)
        self.tools = 0

    def _locate(self, now):
        if self.path or now < self._next_look:
            return self.path
        self._next_look = now + 20
        hits = glob.glob(os.path.join(self.root, "projects", "*", f"{self.sid}.jsonl"))
        self.path = max(hits, key=os.path.getmtime) if hits else None
        return self.path

    def poll(self, now=None):
        now = now or time.time()
        if not self._locate(now):
            return None
        try:
            with open(self.path, "rb") as fh:
                fh.seek(self.off)
                chunk = fh.read(4 << 20)
                self.off += len(chunk)
        except OSError:
            return None
        data = self.buf + chunk.decode("utf-8", errors="replace")
        lines = data.split("\n")
        self.buf = lines.pop()
        for line in lines:
            if line.strip():
                try:
                    self._feed(json.loads(line))
                except (ValueError, TypeError, AttributeError, KeyError):
                    continue
        return self.stats(now)

    def _feed(self, o):
        ts = _parse_ts(o.get("timestamp"))
        if ts:
            self.last_ts = ts if self.last_ts is None else max(self.last_ts, ts)
        msg = o.get("message") or {}
        content = msg.get("content") if isinstance(msg.get("content"), list) else []
        if o.get("type") == "assistant":
            u = msg.get("usage") or {}
            if u:
                mid = msg.get("id") or o.get("requestId") or o.get("uuid")
                inp = int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0) \
                    + int(u.get("cache_creation_input_tokens") or 0)
                rec = self.msgs.setdefault(mid, [0, 0])
                rec[0] = max(rec[0], inp)
                rec[1] = max(rec[1], int(u.get("output_tokens") or 0))
                if inp:
                    self.ctx = inp
            if msg.get("model"):
                self.model = msg["model"]
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    brief = _tool_brief(b.get("name", ""), b.get("input"))
                    self.pending[b.get("id")] = (b.get("name", "?"), brief, ts)
                    self.recent.append((ts, b.get("name", "?"), brief))
                    self.tools += 1
        elif o.get("type") == "user":
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    self.pending.pop(b.get("tool_use_id"), None)

    def stats(self, now):
        window = int(os.environ.get("TEAM_CONTEXT_WINDOW") or 0) or \
            (1_000_000 if "[1m]" in (self.hint + self.model).lower() or self.ctx > 200_000
             else 200_000)
        oldest = min(self.pending.values(), key=lambda p: p[2] or now, default=None)
        return {"tokens": sum(i + o for i, o in self.msgs.values()),
                "output": sum(o for _, o in self.msgs.values()),
                "ctx": self.ctx, "ctx_pct": min(100, round(100 * self.ctx / window)) if self.ctx else None,
                "last_ts": self.last_ts, "tools": self.tools,
                "pending": None if oldest is None else {"name": oldest[0], "brief": oldest[1],
                                                         "since": oldest[2]},
                "subagents": sum(1 for p in self.pending.values() if p[0] in ("Agent", "Task")),
                "recent": list(self.recent)}


# ── data sources ──────────────────────────────────────────────────────────────────────
class LiveSource:
    """`team.sh status --json --sync <team>`, plus each teammate's transcript."""

    def __init__(self, team_sh, team):
        self.team_sh, self.team = team_sh, team
        self.tx = {}

    def fetch(self):
        try:
            p = subprocess.run(["bash", self.team_sh, "status", "--json", "--sync", self.team],
                               capture_output=True, text=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as e:
            return "error", str(e)
        if p.returncode == 3:
            return "gone", None
        if p.returncode != 0:
            return "error", (p.stderr.strip().splitlines() or [f"exit {p.returncode}"])[-1]
        try:
            return "ok", json.loads(p.stdout)
        except ValueError as e:
            return "error", f"bad JSON from status --json: {e}"

    def transcripts(self, doc, now):
        out = {}
        for m in doc.get("teammates", []):
            sid = m.get("session_id")
            if not sid:
                continue
            tx = self.tx.setdefault(sid, Transcript(sid, model_hint=m.get("model") or ""))
            st = tx.poll(now)
            if st:
                out[m["title"]] = st
        return out

    def show(self, role):
        try:
            p = subprocess.run(["bash", self.team_sh, "show", self.team, role],
                               capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:   # a slow cmux must not take the app down
            return 1, [f"show failed: {type(e).__name__}"]
        return p.returncode, (p.stdout + p.stderr).strip().splitlines()[-1:] or [""]


class DemoSource:
    """A synthetic team that plays a whole run, accelerated, so the UI can be tried (and
    recorded for the README) with nothing set up. Nothing here touches a real team."""

    TEAM = "rev7"
    ROLES = [("tech-lead", "claude-opus-5-5"), ("api", "claude-sonnet-5-5"), ("ui", "claude-sonnet-5-5"),
             ("tests", "claude-sonnet-5-5"), ("security", "claude-opus-5-5"), ("docs", "claude-haiku-5-5")]
    TASKS = [("T1", "tech-lead", [], "plan the retry architecture and split the backlog", 9),
             ("T2", "api", ["T1"], "retry with exponential backoff and jitter", 16),
             ("T3", "api", ["T1"], "idempotency keys on POST /ingest", 12),
             ("T4", "ui", ["T2"], "retry state in the job panel", 11),
             ("T5", "tests", ["T2"], "property tests for backoff jitter", 10),
             ("T6", "security", [], "threat-model retry storms and quotas", 14),
             ("T7", "docs", ["T2"], "document the retry configuration", 7),
             ("T8", "any", ["T2", "T3"], "load-test the ingestion path", 9),
             ("T9", "tests", ["T3"], "regression suite for idempotency", 8),
             ("T10", "tech-lead", ["T4", "T5", "T7", "T8", "T9"], "review and merge the PR stack", 6)]
    # (role, start min, length min, state): incidents that pause that teammate's progress
    INCIDENTS = [("security", 8, 4, "WAITING"), ("docs", 33, 11, "STALLED"), ("ui", 26, 3, "IDLE")]
    STEPS = ["reading the code", "mapping the call sites", "dispatching 3 subagents",
             "writing the change", "running the tests", "drafting report"]

    def __init__(self, speed=40.0, start_min=0.0, seed=7):
        self.speed = speed
        self.t0 = time.time() - start_min * 60 / speed
        self.rng = random.Random(seed)
        self.wall0 = time.time()
        self._at = None
        self._plan()

    def backfill(self, hist, step=30):
        """Replay the simulated past into the history, as if the monitor had watched it."""
        end = self.sim_now()
        s = 0.0
        while s < end:
            self._at = s
            _, doc = self.fetch()
            hist.observe(doc, doc["now"])
            s += step
        self._at = None

    def _pause(self, role, a, b):
        return sum(max(0.0, min(b, (s + n) * 60) - max(a, s * 60)) for r, s, n, _ in self.INCIDENTS if r == role)

    def _plan(self):
        """Schedule the tasks once (minutes -> seconds), pauses included."""
        free = {r: 0.0 for r, _ in self.ROLES}
        free["tech-lead"] = 0.0
        self.sched = {}
        end = {}
        for tid, owner, needs, scope, mins in self.TASKS:
            ready = max([end[n] for n in needs] + [0.0])
            cands = [owner] if owner != "any" else ["tests", "api", "security"]
            w = min(cands, key=lambda r: max(free[r], ready))
            start = max(free[w], ready) + 25
            dur = mins * 60 * self.rng.uniform(0.85, 1.2)
            stop = start + dur
            stop += self._pause(w, start, stop)
            self.sched[tid] = (w, start, stop, dur)
            end[tid] = stop
            free[w] = stop

    def sim_now(self):
        return self._at if self._at is not None else (time.time() - self.t0) * self.speed

    def fetch(self):
        s = self.sim_now()
        now = self.wall0 + s
        tasks, mates = [], []
        done_ids = {tid for tid, (_, _, e, _) in self.sched.items() if e <= s}
        for tid, owner, needs, scope, _ in self.TASKS:
            tasks.append({"id": tid, "owner": owner if owner == "any" else f"{self.TEAM}-{owner}",
                          "done": tid in done_ids, "needs": needs,
                          "ready": tid not in done_ids and all(n in done_ids for n in needs),
                          "scope": scope, "owns": "read-only" if owner == "security" else None})
        total_spawn = {r: min([st for w, st, _, _ in self.sched.values() if w == r] + [10 ** 9]) for r, _ in self.ROLES}
        credited = 0.0
        for role, model in self.ROLES:
            title = f"{self.TEAM}-{role}"
            mine = sorted(((tid, v) for tid, v in self.sched.items() if v[0] == role), key=lambda x: x[1][1])
            cur = next(((tid, v) for tid, v in mine if v[1] <= s < v[2]), None)
            left = [tid for tid, v in mine if v[2] > s]
            state, ms, pct, step, task = "WORKING", "investigating", None, None, None
            if s < total_spawn[role] - 25:
                continue   # not spawned yet
            if cur:
                tid, (_, st, en, dur) = cur
                work = (s - st) - self._pause(role, st, s)
                pct = max(1, min(99, int(100 * work / dur)))
                credited += pct / 100
                task = tid
                step = f"{tid}: {self.STEPS[min(len(self.STEPS) - 1, pct * len(self.STEPS) // 100)]}"
                ms = "drafting" if pct > 80 else "investigating"
            elif left:
                state, ms, task = "IDLE", "investigating", left[0]
                step = f"{left[0]}: waiting on {', '.join(n for n in dict((t[0], t[2]) for t in self.TASKS)[left[0]] if n not in done_ids) or 'a peer'}"
            else:
                state, ms = "FINISHED", "reported"
            for r, a, n, st8 in self.INCIDENTS:
                if r == role and a * 60 <= s < (a + n) * 60 and state != "FINISHED":
                    state = st8
            last_change = max([v[1] for _, v in mine if v[1] <= s] + [total_spawn[role]])
            mates.append({"role": role, "title": title, "state": state, "milestone": ms, "step": step,
                          "pct": pct, "age_min": int((s - last_change) / 60) % 7 if state != "STALLED" else 11,
                          "elapsed_min": int(max(0, s - total_spawn[role]) / 60), "note": None, "task": task,
                          "backend": "demo", "ref": None, "layout": "pane", "model": model, "submodel": None,
                          "session_id": None, "cwd": None,
                          "branch": f"team/{self.TEAM}-{role}" if role in ("api", "ui", "tests") else None,
                          "report": None, "report_mtime": None, "status_mtime": None,
                          "report_text": self._report(role, done_ids)})
        total = len(self.TASKS)
        pct = int(100 * (len(done_ids) + credited) / total)
        live = {m["title"] for m in mates if m["state"] != "FINISHED"}
        pend = [t for t in tasks if not t["done"]]
        claimed = {m["task"] for m in mates if m["state"] != "FINISHED" and m.get("pct") is not None}
        prs = [f"https://github.com/acme/ingest/pull/{40 + i}" for i, t in enumerate(("T2", "T3", "T4", "T5")) if t in done_ids]
        return "ok", {"version": 1, "team": self.TEAM, "run": f".team/runs/2026-11-18-{self.TEAM}", "now": now,
                      "summary": {"done": len(done_ids), "total": total, "pct": pct, "est": True,
                                  "elapsed_min": int(s / 60), "eta_min": -1, "pending": len(pend),
                                  "unassigned": sum(1 for t in pend if t["ready"] and t["id"] not in claimed
                                                    and (t["owner"] == "any" or t["owner"] not in live)),
                                  "prs": len(prs)},
                      "prs": prs, "teammates": mates, "tasks": tasks, "demo": True}

    def _report(self, role, done_ids):
        mine = [t for t in self.TASKS if t[1] == role and t[0] in done_ids]
        if not mine:
            return None
        body = "\n".join(f"## {t[0]}\n\nFINDINGS:\n1. {t[3]}: done, evidence in `src/{role}.py:{40 + i * 7}`\n\n"
                         f"CONFIDENCE: high\n\nPARALLELISM: {2 + i % 3} subagents" for i, t in enumerate(mine))
        return f"# {role} report\n\n{body}\n"

    def transcripts(self, doc, now):
        out = {}
        s = self.sim_now()
        tools = [("Read", "src/retry.py"), ("Grep", "def backoff"), ("Bash", "pytest -q tests/test_retry.py"),
                 ("Agent", "map the ingestion call sites"), ("Edit", "retry.py"), ("Bash", "ruff check src")]
        for i, m in enumerate(doc["teammates"]):
            if m["state"] == "FINISHED":
                continue
            k = int(s / 37 + i)
            name, brief = tools[k % len(tools)]
            since = now - (s % 37) if m["state"] != "STALLED" else now - 11 * 60
            if m["state"] == "STALLED":
                name, brief = "Bash", "npm run e2e -- --project=chromium"
            ctx = int(30_000 + (s * (7 + i)) % 140_000)
            out[m["title"]] = {"tokens": int(s * (2100 + 300 * i)), "output": int(s * 40), "ctx": ctx,
                               "ctx_pct": round(100 * ctx / 200_000), "last_ts": now - 3, "tools": int(s / 20),
                               "pending": {"name": name, "brief": brief, "since": since}
                               if m["state"] in ("WORKING", "STALLED") else None,
                               "subagents": 2 if name == "Agent" else 0,
                               "recent": [(now - 30 * j, *tools[(k - j) % len(tools)]) for j in range(8)][::-1]}
        return out

    def show(self, role):
        return 0, [f"demo: would focus {self.TEAM}-{role}'s pane"]


# ── model: one status document in, one immutable view out (runs on the worker thread) ──
class View:
    __slots__ = ("doc", "now", "fc", "tx", "spark", "events", "fetched_at", "error")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))


def build_view(source, hist, doc, now):
    new = hist.observe(doc, now)
    tx = source.transcripts(doc, now)
    fc = forecast(doc, hist, now)
    spark = {m["title"]: hist.spark(m["title"]) for m in doc.get("teammates", [])}
    return View(doc=doc, now=now, fc=fc, tx=tx, spark=spark, events=new, fetched_at=time.time())


def alerts_of(view):
    """Rows for NEEDS YOU: the four alert states, an idle teammate while a ready task has no
    owner, and (new) a stalled teammate whose transcript shows a tool call still in flight."""
    doc, out = view.doc, []
    summary = doc.get("summary") or {}
    unassigned = summary.get("unassigned", 0)
    ready_owners = set(summary.get("ready_owners") or ())
    for m in doc.get("teammates", []):
        st = m["state"]
        tx = (view.tx or {}).get(m["title"]) or {}
        pend = tx.get("pending")
        if STATES.get(st, ("", "", "dim"))[2] == "alert":
            detail = m.get("note") or HINT.get(st, "")
            if st == "STALLED" and pend and pend.get("since"):
                detail = (f"{pend['name']} running for {fmt_dur(view.now - pend['since'])}"
                          f" ({pend['brief'][:40]}): likely a permission prompt in its pane")
            out.append((m, st, detail))
        elif st == "IDLE" and m["title"] in ready_owners:
            out.append((m, "IDLE", "with work pending: it holds a ready task"))
        elif st == "IDLE" and unassigned > 0:
            out.append((m, "IDLE", f"with work pending: {unassigned} ready task"
                                   f"{' has' if unassigned == 1 else 's have'} no owner; hand it one"))
    out.sort(key=lambda r: ORDER.index(r[1]) if r[1] in ORDER else 99)
    return out


# ── self-test: the stdlib layer, without Textual ───────────────────────────────────────
def selftest():
    ok = True

    def check(name, cond, info=""):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + name + ("" if cond else f" — {info}"))
        ok &= bool(cond)

    now = 1_000_000.0
    mk = lambda tid, owner, done=False, needs=(): {"id": tid, "owner": owner, "done": done, "needs": list(needs)}
    mate = lambda title, task, pct, el=10, st="WORKING": {"title": title, "role": title.split("-", 1)[1], "state": st,
                                                          "milestone": "investigating", "task": task, "pct": pct,
                                                          "elapsed_min": el, "step": None}
    # F1: two parallel tasks at 50% after 10 min each -> ~10 min left, nothing else pending
    doc = {"tasks": [mk("T1", "t-a"), mk("T2", "t-b")], "teammates": [mate("t-a", "T1", 50), mate("t-b", "T2", 50)],
           "summary": {"done": 0, "elapsed_min": 10}}
    fc = forecast(doc, History(), now)
    check("F1: two parallel halves -> ETA about 10 min", fc["eta"] and abs(fc["eta"] - 600) < 5, fc)
    # F2: a dependent task waits for its need, then runs one typical duration (20 min)
    doc["tasks"].append(mk("T3", "t-a", needs=["T2"]))
    fc = forecast(doc, History(), now)
    check("F2: T3 needs T2 -> starts at 10m, ends near 30m", abs(fc["per_task"]["T3"] - 1800) < 5, fc["per_task"])
    # F3: 'any' work goes to the teammate that frees up first
    doc = {"tasks": [mk("T1", "t-a"), mk("T2", "t-b"), mk("T3", "any")],
           "teammates": [mate("t-a", "T1", 90), mate("t-b", "T2", 10)], "summary": {"done": 0, "elapsed_min": 10}}
    fc = forecast(doc, History(), now)
    check("F3: 'any' task scheduled after the faster teammate", fc["per_task"]["T3"] < fc["per_task"]["T2"], fc["per_task"])
    # F4: no signal at all -> no ETA rather than a made-up one
    doc = {"tasks": [mk("T1", "t-a")], "teammates": [mate("t-a", "T1", None)], "summary": {"done": 0, "elapsed_min": 1}}
    check("F4: no % and nothing done -> no ETA", forecast(doc, History(), now)["eta"] is None)
    # F5: everything done -> 0; the range always brackets the estimate
    doc = {"tasks": [mk("T1", "t-a", True)], "teammates": [], "summary": {"done": 1}}
    check("F5: all done -> ETA 0", forecast(doc, History(), now)["eta"] == 0)
    doc = {"tasks": [mk(f"T{i}", "any") for i in range(1, 7)], "teammates": [mate("t-a", "T1", 40), mate("t-b", "T2", 60)],
           "summary": {"done": 0, "elapsed_min": 12}}
    fc = forecast(doc, History(), now)
    check("F6: lo <= eta <= hi", fc["lo"] <= fc["eta"] <= fc["hi"], fc)
    # F8: a teammate on its 2nd task (spawned 60 min ago, T1 done) at 50%: the 60 min is not T2's age
    doc = {"tasks": [mk("T1", "t-a", True), mk("T2", "t-a")], "teammates": [mate("t-a", "T2", 50, el=60)],
           "summary": {"done": 1, "elapsed_min": 60}}
    fc = forecast(doc, History(), now)
    check("F8: second task at 50% projects from the typical duration (~30 min), not spawn age (~60)",
          fc["eta"] is not None and abs(fc["eta"] - 1800) < 60, fc)
    # F7: a cycle in needs does not hang
    doc = {"tasks": [mk("T1", "any", needs=["T2"]), mk("T2", "any", needs=["T1"])], "teammates": [mate("t-a", None, None)],
           "summary": {"done": 1, "elapsed_min": 10}}
    check("F7: cyclic needs terminate", forecast(doc, History(), now)["eta"] is not None)

    # H1: history only times what it watched; a task done before attaching has no duration
    h = History()
    d1 = {"tasks": [mk("T1", "t-a", True), mk("T2", "t-a")], "teammates": [mate("t-a", "T2", 10)]}
    h.observe(d1, now)
    d2 = {"tasks": [mk("T1", "t-a", True), mk("T2", "t-a", True)], "teammates": [mate("t-a", "T2", 100)]}
    ev = h.observe(d2, now + 300)
    check("H1: T2's start is unknown (t-a already finished T1 before attaching): no duration recorded", h.durations() == [], h.durations())
    check("H2: a task finishing emits a done event", any("T2 done" in e[2] for e in ev), ev)
    h = History()   # a teammate on its first task: its spawn time is the task's start
    h.observe({"tasks": [mk("T2", "t-b")], "teammates": [mate("t-b", "T2", 10)]}, now)
    h.observe({"tasks": [mk("T2", "t-b", True)], "teammates": [mate("t-b", "T2", 100)]}, now + 300)
    check("H2b: first-task teammate keeps the spawn-based start", h.durations() == [300 + 600], h.durations())
    # H4: an unknown start stays unknown on later ticks, so the ETA keeps the typical path
    h = History()
    d = {"tasks": [mk("T1", "t-a", True), mk("T2", "t-a")], "teammates": [mate("t-a", "T2", 50, el=60)],
         "summary": {"done": 1, "elapsed_min": 60}}
    h.observe(d, now)
    h.observe(d, now + 5)
    fc = forecast(d, h, now + 5)
    check("H4: second tick keeps T2's start unknown", h.task_start.get("T2", 0) is None, h.task_start)
    check("H4b: ETA still from the typical duration (~30 min), not ~seconds",
          fc["eta"] is not None and abs(fc["eta"] - 1800) < 60, fc)
    h.observe({"tasks": [mk("T1", "t-a", True), mk("T2", "t-a", True)], "teammates": [mate("t-a", "T2", 100)]}, now + 300)
    check("H4c: T2 finishing records no truncated duration", h.durations() == [], h.durations())
    # H5: a done `any` task may be this teammate's, so its spawn age is not the task age
    h = History()
    h.observe({"tasks": [mk("T1", "any", True), mk("T2", "t-a")], "teammates": [mate("t-a", "T2", 10)]}, now)
    check("H5: after a done `any` task the start is unknown", h.task_start.get("T2", 0) is None, h.task_start)
    # H3: recent rate
    h = History()
    for i, p in enumerate((10, 20, 30)):
        h.observe({"tasks": [mk("T1", "t-a")], "teammates": [mate("t-a", "T1", p)]}, now + 60 * i)
    r = h.rate("t-a", "T1", 30, now + 120)
    check("H3: rate 20% over 120s", r and abs(r - 20 / 120) < 1e-6, r)

    # T1: transcript dedupe by message id, context from the newest, pending tools
    import tempfile
    root = tempfile.mkdtemp()
    os.makedirs(os.path.join(root, "projects", "-x"))
    sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    p = os.path.join(root, "projects", "-x", sid + ".jsonl")
    rows = [
        {"type": "assistant", "timestamp": "2026-11-18T10:00:00Z", "message": {"id": "m1", "model": "claude-x",
         "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000, "output_tokens": 5},
         "content": [{"type": "tool_use", "id": "u1", "name": "Bash", "input": {"command": "pytest -q"}}]}},
        {"type": "assistant", "timestamp": "2026-11-18T10:00:01Z", "message": {"id": "m1", "model": "claude-x",
         "usage": {"input_tokens": 10, "cache_read_input_tokens": 1000, "output_tokens": 50}, "content": []}},
        {"type": "user", "timestamp": "2026-11-18T10:00:30Z", "message": {"content": [{"type": "tool_result", "tool_use_id": "u1"}]}},
        {"type": "assistant", "timestamp": "2026-11-18T10:01:00Z", "message": {"id": "m2",
         "usage": {"input_tokens": 5, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 20, "output_tokens": 7},
         "content": [{"type": "tool_use", "id": "u2", "name": "Read", "input": {"file_path": "/a/b/c.py"}}]}},
    ]
    with open(p, "w") as fh:
        fh.write("\n".join(json.dumps(r) for r in rows[:2]) + "\n" + json.dumps(rows[2])[:20])   # torn last line
    tx = Transcript(sid, root=root)
    st = tx.poll(now)
    check("T1: torn line is buffered, not lost", st["pending"] and st["pending"]["name"] == "Bash", st)
    with open(p, "w") as fh:
        fh.write("\n".join(json.dumps(r) for r in rows) + "\n")
    tx2 = Transcript(sid, root=root)
    st = tx2.poll(now)
    check("T2: tokens deduped per message (1010+50, 3025+7)", st["tokens"] == 1010 + 50 + 3025 + 7, st["tokens"])
    check("T3: context = newest input incl. cache (3025)", st["ctx"] == 3025, st["ctx"])
    check("T4: finished tool cleared, open one pending", st["pending"]["name"] == "Read" and st["pending"]["brief"] == "c.py", st)
    tx3 = Transcript(sid, root=root, model_hint="system.ai.claude-x[1m]")
    tx3.ctx = 400_000
    check("C1: [1m] registry hint selects the 1M window (400k -> 40%)", tx3.stats(now)["ctx_pct"] == 40, tx3.stats(now))
    tx3.hint, tx3.ctx = "", 400_000
    check("C2: context over 200k implies the 1M window", tx3.stats(now)["ctx_pct"] == 40, tx3.stats(now))
    check("S1: short_model", short_model("claude-sonnet-4-6") == "sonnet 4.6" and short_model("opus") == "opus")
    idle = lambda: {"title": "t-a", "role": "a", "state": "IDLE"}
    al = alerts_of(View(doc={"teammates": [idle()], "summary": {"unassigned": 0, "ready_owners": ["t-a"]}}, now=now))
    check("A1: an idle teammate holding a ready task needs you", [r[1] for r in al] == ["IDLE"], al)
    al = alerts_of(View(doc={"teammates": [idle()], "summary": {"unassigned": 0, "ready_owners": []}}, now=now))
    check("A2: an idle teammate with no ready work does not", al == [], al)
    return 0 if ok else 1


# ══════════════════════════════════════════════════════════════════════════════════════
# UI (Textual)
# ══════════════════════════════════════════════════════════════════════════════════════
try:
    from rich.console import Group
    from rich.table import Table
    from rich.text import Text
    from textual import on, work
    from textual.app import App, ComposeResult
    from textual.binding import Binding
    from textual.css.query import NoMatches
    from textual.containers import Horizontal, Vertical, VerticalScroll
    from textual.screen import ModalScreen, Screen
    from textual.widget import Widget
    from textual.widgets import DataTable, Footer, Markdown, RichLog, Static, TabbedContent, TabPane
    HAVE_TEXTUAL = True
except ImportError:   # stdlib layer still usable (--selftest); the UI is not
    HAVE_TEXTUAL = False


def _rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def _mix(a, b, t):
    ra, rb = _rgb(a), _rgb(b)
    return "#%02x%02x%02x" % tuple(int(x + (y - x) * t) for x, y in zip(ra, rb))


if HAVE_TEXTUAL:
    EIGHTHS = " ▏▎▍▌▋▊▉█"
    SPARK = "▁▂▃▄▅▆▇█"

    def gbar(pct, width, c0=PAL["accent"], c1=PAL["done"], track=PAL["track"]):
        """A smooth bar: eighth-block precision, colour graded along its length, solid track."""
        width = max(1, width)
        pct = max(0.0, min(100.0, float(pct or 0)))
        exact = pct / 100 * width
        full, rem = int(exact), int((exact - int(exact)) * 8)
        t = Text()
        for i in range(width):
            col = _mix(c0, c1, i / max(1, width - 1))
            if i < full:
                t.append("█", style=f"{col} on {track}")
            elif i == full and rem:
                t.append(EIGHTHS[rem], style=f"{col} on {track}")
            else:
                t.append(" ", style=f"on {track}")
        return t

    def spark(values, width, color=PAL["active"]):
        vals = list(values)[-width:]
        if not vals:
            return Text("·" * min(width, 3), style=PAL["dim"])
        t = Text()
        for v in vals:
            v = max(0, min(100, v))
            t.append(SPARK[min(7, int(v / 100 * 7.999))], style=_mix(PAL["accent"], color, v / 100))
        return t

    def state_bits(m, tick):
        glyph, word, role = STATES.get(m["state"], ("?", m["state"].lower(), "dim"))
        if m["state"] == "WORKING":
            glyph = SPIN[tick % len(SPIN)]
            if m.get("milestone") in ("spawned", "investigating", "drafting"):
                word = m["milestone"]
        return glyph, word, PAL[role]

    def chip(glyph, text, color):
        return Text.assemble((f" {glyph} ", f"bold {color}"), (text + " ", PAL["text"]))

    def render_header(view, width, tick, closing=None, error=None):
        doc, fc = view.doc, view.fc or {}
        S = doc.get("summary") or {}
        age = time.time() - (view.fetched_at or time.time())
        now = view.now + (age if not doc.get("demo") else 0)
        run = os.path.basename(doc.get("run") or "") or "no run dir"
        g1 = Table.grid(expand=True)
        g1.add_column()
        g1.add_column(justify="right")
        g1.add_row(Text.assemble(("◆ ", f"bold {PAL['accent']}"), ("TEAM-MATES", "bold"),
                                 ("  ", ""), (doc.get("team", "?"), f"bold {PAL['active']}"),
                                 (f"  ·  {run}", PAL["dim"]), ("  ·  demo" if doc.get("demo") else "", PAL["warn"])),
                   Text(time.strftime("%H:%M:%S", time.localtime(now)), style="bold"))
        pct, est = overall_pct(doc)
        eta = fc.get("eta")
        if eta is not None:
            eta = max(0.0, eta - age)
        if eta == 0 and S.get("pending", 0) == 0 and S.get("total", 0) > 0:
            eta_t = Text("all tasks done", style=f"bold {PAL['done']}")
        elif eta is None:
            eta_t = Text("ETA —  (not enough signal yet)", style=PAL["dim"])
        else:
            band = ""
            if fc.get("lo") is not None and fc.get("hi") is not None and fc["hi"] - fc["lo"] >= 60:
                band = f" ({fmt_dur(max(0, fc['lo'] - age))}–{fmt_dur(max(0, fc['hi'] - age))})"
            eta_t = Text.assemble(("ETA ", PAL["dim"]), (f"~{fmt_dur(eta)}", f"bold {PAL['accent']}"),
                                  (band, PAL["dim"]),
                                  ("  ·  done ≈ ", PAL["dim"]),
                                  (time.strftime("%H:%M", time.localtime(now + eta)), "bold"))
        label = Text(f"  {'~' if est else ''}{pct}%  ", style="bold")
        barw = max(8, width - label.cell_len - eta_t.cell_len - 1)
        mates = doc.get("teammates", [])
        # Nothing working (all idle, stalled, waiting or finished): the bar stops looking alive.
        busy = any(m["state"] == "WORKING" for m in mates)
        bar = gbar(pct, barw) if busy else gbar(pct, barw, c0=PAL["dim"], c1=PAL["dim"])
        line2 = Text.assemble(bar, label, eta_t)
        n = lambda states: sum(1 for m in mates if m["state"] in states)
        alerts = len(alerts_of(view))
        tok = sum((v or {}).get("tokens") or 0 for v in (view.tx or {}).values())
        chips = Text()
        chips += chip("◐", f"{n(('WORKING',))} working", PAL["active"])
        if alerts:
            chips += chip("⚠", f"{alerts} need you", PAL["alert"])
        if n(("IDLE",)):
            chips += chip("◌", f"{n(('IDLE',))} idle", PAL["dim"])
        chips += chip("✓", f"{n(('FINISHED',))} finished", PAL["done"])
        if S.get("total"):
            chips += chip("▣", f"{S['done']}/{S['total']} tasks", PAL["accent"])
        if S.get("unassigned"):
            chips += chip("●", f"{S['unassigned']} unassigned", PAL["warn"])
        chips += chip("⏱", f"{fmt_dur((S.get('elapsed_min') or 0) * 60)} elapsed", PAL["dim"])
        if doc.get("prs"):
            chips += chip("⇡", f"{len(doc['prs'])} PR" + ("s" if len(doc["prs"]) != 1 else ""), PAL["done"])
        if tok:
            chips += chip("Σ", f"{fmt_tok(tok)} tok", PAL["dim"])
        chips.truncate(width, overflow="ellipsis")
        rows = [g1, line2, chips]
        if closing:
            rows.append(Text(f" ✓ all teammates finished — closing this pane in {closing}s "
                             "(TEAM_MONITOR_AUTOCLOSE=0 keeps it)", style=f"bold {PAL['done']}"))
        elif error:
            rows.append(Text(f" ! {error}", style=f"bold {PAL['warn']}"))
        return Group(*rows)

    def render_card(m, view, width, tick, compact=False):
        tx = (view.tx or {}).get(m["title"]) or {}
        glyph, word, color = state_bits(m, tick)
        width = max(10, width)
        top = Table.grid(expand=True)
        top.add_column(no_wrap=True, overflow="ellipsis")
        top.add_column(justify="right", no_wrap=True)
        left = Text.assemble((f"{glyph} ", f"bold {color}"), (word, f"bold {color}"))
        if m.get("task"):
            left.append(f"  {m['task']}", style=f"bold {PAL['text']}")
        el = m.get("elapsed_min")
        top.add_row(left, Text(fmt_dur(el * 60) if el is not None else "", style=PAL["dim"]))
        step = m.get("step") or ""
        step = re.sub(r"^\s*T\d+:\s*", "", step)
        if m.get("note"):
            step = f"{m['note']} · {step}" if step else m["note"]
        if not step and m["state"] in HINT:
            step = HINT[m["state"]]
        l2 = Text(step or "—", style=PAL["text"] if step else PAL["dim"], no_wrap=True, overflow="ellipsis")
        l2.truncate(width, overflow="ellipsis")
        pct = m.get("pct")
        if m["state"] == "FINISHED" or (m.get("milestone") == "reported" and pct is None):
            pct = 100
        eta = (view.fc or {}).get("per_mate", {}).get(m["title"])
        tail = Text.assemble((f" {pct:>3}%" if pct is not None else "   —", "bold"),
                             (f"  ~{fmt_dur(eta)}" if eta else "", PAL["accent"]))
        barw = max(4, width - tail.cell_len)
        if pct is None:
            l3 = Text.assemble(Text("╌" * barw, style=PAL["dim"]), tail)
        else:
            l3 = Text.assemble(gbar(pct, barw, c0=_mix(color, PAL["accent"], .5), c1=color), tail)
        if compact:   # short terminal: state line + bar only, so every teammate stays visible
            return Group(top, l3)
        meta = Text()
        if tx.get("ctx_pct") is not None:
            meta.append(f" ctx {tx['ctx_pct']}%", style=PAL["warn"] if tx["ctx_pct"] >= 80 else PAL["dim"])
        if tx.get("tokens"):
            meta.append(f" · {fmt_tok(tx['tokens'])}", style=PAL["dim"])
        spw = max(3, width - meta.cell_len - 1)
        l4 = Text.assemble(spark(view.spark.get(m["title"], []) if view.spark else [], spw, color), " ", meta)
        l4.truncate(width, overflow="ellipsis")
        pend = tx.get("pending")
        if pend:
            since = fmt_dur(view.now - pend["since"]) if pend.get("since") else ""
            l5 = Text.assemble(("⏳ ", PAL["warn"]), (pend["name"], "bold"), (f" {since}", PAL["dim"]),
                               (f"  {pend['brief']}", PAL["dim"]))
            if tx.get("subagents"):
                l5.append(f"  ⑂ {tx['subagents']} subagents", style=PAL["active"])
        elif m.get("branch"):
            l5 = Text.assemble(("⎇ ", PAL["dim"]), (m["branch"], PAL["dim"]))
        else:
            l5 = Text(short_model(m.get("model")) or "", style=PAL["dim"])
        l5.truncate(width, overflow="ellipsis")
        return Group(top, l2, l3, l4, l5)

    # ── widgets ──
    class HeaderPanel(Widget):
        DEFAULT_CSS = "HeaderPanel { height: auto; padding: 0 1; }"

        def __init__(self, **kw):
            super().__init__(**kw)
            self.view, self.tick, self.closing, self.error = None, 0, None, None

        def get_content_height(self, container, viewport, width):
            return 3 + (1 if (self.closing or self.error) else 0)

        def render(self):
            if not self.view:
                return Text.assemble(("◆ ", f"bold {PAL['accent']}"), ("TEAM-MATES", "bold"),
                                     ("  reading the team…", PAL["dim"]))
            return render_header(self.view, self.size.width, self.tick, self.closing, self.error)

    class MateCard(Widget, can_focus=True):
        DEFAULT_CSS = """
        MateCard { height: 7; border: round $panel-lighten-2; padding: 0 1; }
        MateCard.active { border: round #AF52DE; }
        MateCard.alert { border: round #FF453A; }
        MateCard.alert-blink { border: heavy #FF453A; }
        MateCard.done { border: round #30D158; }
        MateCard.dim { border: round #6E6E76; }
        MateCard:focus { border: double $accent; background: $boost; }
        """

        def __init__(self, title, **kw):
            super().__init__(**kw)
            self.mate_title, self.mate, self.view, self.tick, self.key = title, None, None, 0, ""

        def set_data(self, m, view, key, tick):
            self.mate, self.view, self.key, self.tick = m, view, key, tick
            self.styles.height = 4 if getattr(self.app, "compact", False) else 7
            role = STATES.get(m["state"], ("", "", "dim"))[2]
            for c in ("active", "alert", "done", "dim"):
                self.set_class(role == c, c)
            self.set_class(role == "alert" and tick % 2 == 0, "alert-blink")
            self.border_title = f"{key + ' · ' if key else ''}{m['role']}"
            self.border_subtitle = short_model(m.get("model"))
            self.refresh()

        def render(self):
            if not self.mate:
                return ""
            return render_card(self.mate, self.view, self.size.width, self.tick, getattr(self.app, "compact", False))

        def on_click(self, event):
            if self.has_focus or getattr(event, "chain", 1) >= 2:
                self.app.action_details()
            else:
                self.focus()

    class DetailScreen(Screen):
        BINDINGS = [Binding("escape,q", "app.pop_screen", "Back"), Binding("s", "show", "Show pane")]
        DEFAULT_CSS = """
        DetailScreen { background: $background; }
        #dhead { height: auto; padding: 0 1; border-bottom: solid $panel-lighten-2; }
        #dtabs { height: 1fr; }
        #report { padding: 0 1; }
        """

        def __init__(self, title):
            super().__init__()
            self.mate_title = title

        def compose(self) -> ComposeResult:
            yield Static(id="dhead")
            with TabbedContent(id="dtabs"):
                with TabPane("Report", id="t-report"):
                    yield VerticalScroll(Markdown("", id="report"))
                with TabPane("Activity", id="t-act"):
                    yield RichLog(id="act", markup=False, wrap=False, max_lines=500, min_width=20)
                with TabPane("Progress", id="t-hist"):
                    yield Static(id="hist")
                with TabPane("Info", id="t-info"):
                    yield DataTable(id="info", show_header=False, cursor_type="none")
            yield Footer()

        def on_mount(self):
            self.refresh_view(self.app.view)

        def _mate(self, view):
            return next((m for m in view.doc.get("teammates", []) if m["title"] == self.mate_title), None)

        def refresh_view(self, view):
            try:
                self._refresh_view(view)
            except NoMatches:   # tab panes mount after the screen; the next tick retries
                pass

        def _refresh_view(self, view):
            if not view:
                return
            m = self._mate(view)
            if not m:
                return
            head = Text.assemble((m["role"], f"bold {PAL['accent']}"), (f"  {m['title']}", PAL["dim"]),
                                 (f"  ·  {short_model(m.get('model'))}" if m.get("model") else "", PAL["dim"]),
                                 (f"  ·  ⎇ {m['branch']}" if m.get("branch") else "", PAL["dim"]),
                                 ("   esc back · s show its pane", PAL["dim"]))
            self.query_one("#dhead", Static).update(Group(head, render_card(m, view, max(20, self.size.width - 2), self.app.tick)))
            text = m.get("report_text")
            if text is None and m.get("report"):
                try:
                    with open(m["report"], encoding="utf-8", errors="replace") as fh:
                        text = fh.read()[-60_000:]
                except OSError:
                    text = None
            md = self.query_one("#report", Markdown)
            new = text or "*No report on disk yet.* It appears here once the teammate writes `reports/<role>.md`."
            if getattr(self, "_md", None) != new:
                self._md = new
                md.update(new)
            tx = (view.tx or {}).get(m["title"]) or {}
            log = self.query_one("#act", RichLog)
            log.clear()
            if not tx:
                log.write(Text("No transcript found for this session (finished, or not a Claude Code pane).", style=PAL["dim"]))
            for ts, name, brief in tx.get("recent", []):
                when = time.strftime("%H:%M:%S", time.localtime(ts)) if ts else "--:--:--"
                log.write(Text.assemble((when + "  ", PAL["dim"]), (f"{name:<8}", f"bold {PAL['accent']}"), " ", brief))
            if tx.get("pending"):
                p = tx["pending"]
                log.write(Text.assemble(("in flight  ", PAL["warn"]), (p["name"], "bold"), f"  {p['brief']}  ",
                                        (fmt_dur(view.now - p["since"]) if p.get("since") else "", PAL["dim"])))
            hist = self.app.hist
            samples = list(hist.samples.get(m["title"], ())) if hist else []
            rows = [Text.assemble(("Self-reported progress over time  ", "bold"),
                                  ("(each point is a status update)", PAL["dim"])),
                    spark([p for _, _, p in samples], max(10, self.size.width - 4),
                          PAL[STATES.get(m["state"], ("", "", "dim"))[2]]), Text("")]
            for t, k, p in samples[-18:][::-1]:
                rows.append(Text.assemble((time.strftime("%H:%M:%S", time.localtime(t)) + "  ", PAL["dim"]),
                                          (f"{k or '-':<5}", "bold"), gbar(p or 0, 20), f" {p}%"))
            self.query_one("#hist", Static).update(Group(*rows))
            info = self.query_one("#info", DataTable)
            info.clear(columns=True)
            info.add_columns("k", "v")
            for k, v in (("title", m["title"]), ("state", m["state"]), ("milestone", m.get("milestone")),
                         ("task", m.get("task")), ("model", m.get("model")), ("subagent model", m.get("submodel")),
                         ("session", m.get("session_id")), ("cwd", m.get("cwd")), ("branch", m.get("branch")),
                         ("pane", f"{m.get('backend')} {m.get('ref')}"), ("report", m.get("report")),
                         ("tokens", fmt_tok(tx.get("tokens"))), ("context", f"{fmt_tok(tx.get('ctx'))} ({tx.get('ctx_pct')}%)" if tx.get("ctx") else "—"),
                         ("tool calls", tx.get("tools"))):
                info.add_row(Text(k, style=PAL["dim"]), Text(str(v if v not in (None, "") else "—")))

        def action_show(self):
            m = self._mate(self.app.view)
            if m:
                self.app.show_pane(m)

    class HelpScreen(ModalScreen):
        BINDINGS = [Binding("escape,q,question_mark", "app.pop_screen", "Close")]
        DEFAULT_CSS = """
        HelpScreen { align: center middle; }
        #help { width: 84; height: auto; max-height: 90%; border: round $accent; background: $surface; padding: 1 2; }
        """

        def compose(self) -> ComposeResult:
            t = Table.grid(padding=(0, 2))
            t.add_column(style=f"bold {PAL['accent']}")
            t.add_column()
            for k, v in (("1-9", "bring that teammate's pane to the front (team.sh show)"),
                         ("↑↓←→ / tab", "move between teammate cards"),
                         ("enter / click", "open the teammate: report, tool activity, progress, info"),
                         ("s", "show the selected teammate's pane"),
                         ("r", "refresh now"), ("t", "next colour theme"), ("q", "quit (the team keeps running)")):
                t.add_row(k, v)
            s = Table.grid(padding=(0, 2))
            s.add_column()
            s.add_column()
            for tok, (g, w, role) in STATES.items():
                s.add_row(Text(f"{g} {w}", style=f"bold {PAL[role]}"), Text(HINT.get(tok, {
                    "WORKING": "doing its work", "IDLE": "turn ended, no report yet (waits on a peer or you)",
                    "UNKNOWN": "state cannot be read here", "FINISHED": "reported, verified and closed"}.get(tok, "")),
                    style=PAL["dim"]))
            notes = Text("Progress and ETA are estimates: each teammate reports its own %, and the ETA "
                         "schedules the open backlog over the live teammates, respecting needs:. Tokens and "
                         "context come from each teammate's Claude Code transcript.", style=PAL["dim"])
            yield Static(Group(Text("Keys", style="bold"), t, Text(""), Text("States", style="bold"), s,
                               Text(""), notes), id="help")

    class TeamMonitor(App):
        TITLE = "Team-mates monitor"
        CSS = """
        Screen { background: $background; }
        #alerts { height: auto; margin: 0 1; padding: 0 1; border: round #FF453A; display: none; }
        #alerts.on { display: block; }
        #cards-wrap { height: auto; max-height: 65%; }
        #cards { layout: grid; grid-size: 3; grid-gutter: 0 1; height: auto; padding: 0 1; }
        #finished { height: auto; padding: 0 2; color: $text-muted; display: none; }
        #finished.on { display: block; }
        #bottom { height: 1fr; min-height: 6; margin: 0 1; }
        #backlog { width: 3fr; border: round $panel-lighten-2; }
        #events { width: 2fr; border: round $panel-lighten-2; }
        #bottom.narrow #events { display: none; }
        """
        BINDINGS = [Binding("q", "quit", "Quit"), Binding("r", "refresh", "Refresh"),
                    Binding("enter", "details", "Details"), Binding("s", "show", "Show pane"),
                    Binding("t", "theme_next", "Theme"), Binding("question_mark", "help", "Help"),
                    Binding("left", "move(-1)", show=False), Binding("right", "move(1)", show=False),
                    Binding("up", "move(-3)", show=False), Binding("down", "move(3)", show=False)] + \
                   [Binding(str(i), f"key_pane({i})", show=False) for i in range(1, 10)]

        def __init__(self, source, hist, interval, autoclose=True, grace=4):
            super().__init__()
            self.source, self.hist, self.interval = source, hist, interval
            self.view, self.tick, self.cols, self.compact = None, 0, 3, False
            self.autoclose, self.grace = autoclose, grace
            self._saw_unfinished, self._closing_at, self._order = False, None, []
            self._alerted, self._seen_first = set(), False

        def compose(self) -> ComposeResult:
            yield HeaderPanel(id="hdr")
            yield Static(id="alerts")
            with VerticalScroll(id="cards-wrap"):
                yield Vertical(id="cards")
            yield Static(id="finished")
            with Horizontal(id="bottom"):
                yield DataTable(id="backlog", cursor_type="row", zebra_stripes=True)
                yield RichLog(id="events", markup=False, wrap=False, max_lines=400, min_width=20)
            yield Footer()

        def on_mount(self):
            theme = os.environ.get("TEAM_MONITOR_THEME", "tokyo-night")
            if theme in self.available_themes:
                self.theme = theme
            bl = self.query_one("#backlog", DataTable)
            bl.border_title = "Backlog"
            bl.add_columns("", "Task", "Owner", "Progress", "ETA", "Scope")
            ev = self.query_one("#events", RichLog)
            ev.border_title = "Events"
            for t, lvl, text in list(self.hist.events)[-50:]:
                self._log(t, lvl, text)
            self._relayout(self.size.width, self.size.height)
            self.action_refresh()
            self.set_interval(self.interval, self.action_refresh)
            self.set_interval(1.0, self._tick)

        # data
        def action_refresh(self):
            self._fetch()

        @work(thread=True, exclusive=True, group="fetch")
        def _fetch(self):
            kind, payload = self.source.fetch()
            if kind == "ok":
                now = payload.get("now") or time.time()
                try:
                    view = build_view(self.source, self.hist, payload, now)
                except Exception as e:   # never let one bad tick kill the pane
                    self.call_from_thread(self._error, f"monitor: {type(e).__name__}: {e}")
                    return
                self.call_from_thread(self._guarded, self._apply, view)
            elif kind == "gone":
                self.call_from_thread(self.exit, EXIT_TEAM_CLOSED)
            else:
                self.call_from_thread(self._guarded, self._error, f"status --json failed: {payload}")

        def _guarded(self, fn, *args):
            try:
                fn(*args)
            except NoMatches:   # a fetch that lands while the app tears down finds no widgets
                pass

        def _error(self, msg):
            hdr = self.query_one("#hdr", HeaderPanel)
            hdr.error = msg
            hdr.refresh(layout=True)

        def _apply(self, view):
            self.view = view
            hdr = self.query_one("#hdr", HeaderPanel)
            hdr.error = None
            for t, lvl, text in view.events:
                self._log(t, lvl, text)
            alerts = alerts_of(view)
            for m, st, detail in alerts:
                key = (m["title"], st)
                if key not in self._alerted and self._seen_first:   # no toasts for what was already there
                    self.notify(f"{m['role']}: {STATES.get(st, ('', st.lower()))[1]} — {detail[:80]}",
                                title="Needs you", severity="error", timeout=8)
            self._alerted = {(m["title"], st) for m, st, _ in alerts}
            self._seen_first = True
            self._render_all()
            mates = view.doc.get("teammates", [])
            allfin = bool(mates) and all(m["state"] == "FINISHED" for m in mates)
            if not allfin:
                self._saw_unfinished, self._closing_at = True, None
            elif self._saw_unfinished and self.autoclose and self._closing_at is None:
                self._closing_at = time.time() + self.grace
                self.set_timer(self.grace, self._close_if_still_done)

        def _close_if_still_done(self):
            if self._closing_at is not None:
                self.exit(EXIT_ALL_FINISHED)

        def _tick(self):
            self.tick += 1
            if self.view:
                self._guarded(self._render_all, True)
            if isinstance(self.screen, DetailScreen) and self.tick % 3 == 0:
                self.screen.refresh_view(self.view)

        # rendering
        def _sorted_live(self, view):
            mates = [m for m in view.doc.get("teammates", []) if m["state"] != "FINISHED"]
            alert_titles = [m["title"] for m, _, _ in alerts_of(view)]
            return sorted(mates, key=lambda m: (0 if m["title"] in alert_titles else 1,
                                                ORDER.index(m["state"]) if m["state"] in ORDER else 99, m["role"]))

        def _render_all(self, light=False):
            view = self.view
            hdr = self.query_one("#hdr", HeaderPanel)
            hdr.view, hdr.tick = view, self.tick
            hdr.closing = max(0, int(round(self._closing_at - time.time()))) if self._closing_at else None
            hdr.refresh(layout=True)
            live = self._sorted_live(view)
            cards = self.query_one("#cards", Vertical)
            have = {c.mate_title: c for c in cards.query(MateCard)}
            want = [m["title"] for m in live]
            if not light and list(have) != want:
                focused = self.focused.mate_title if isinstance(self.focused, MateCard) else None
                cards.remove_children()
                have = {t: MateCard(t) for t in want}
                cards.mount(*have.values())
                if focused in have:
                    self.call_after_refresh(have[focused].focus)
            self._order = want
            for i, m in enumerate(live):
                c = have.get(m["title"])
                if c:
                    c.set_data(m, view, str(i + 1) if i < 9 else "", self.tick)
            fin = [m for m in view.doc.get("teammates", []) if m["state"] == "FINISHED"]
            fw = self.query_one("#finished", Static)
            fw.set_class(bool(fin), "on")
            if fin:
                t = Text()
                for m in fin:
                    el = fmt_dur((m.get("elapsed_min") or 0) * 60)
                    t.append(" ✓ ", style=f"bold {PAL['done']}")
                    t.append(m["role"], style="bold")
                    t.append(f" {el}   ", style=PAL["dim"])
                if view.doc.get("prs"):
                    t.append(f"⇡ {len(view.doc['prs'])} PR(s): ", style=PAL["done"])
                    t.append("  ".join("#" + u.rsplit("/", 1)[-1] for u in view.doc["prs"]), style=PAL["dim"])
                fw.update(t)
            al = alerts_of(view)
            aw = self.query_one("#alerts", Static)
            aw.set_class(bool(al), "on")
            if al:
                aw.border_title = f"⚠ NEEDS YOU ({len(al)})"
                rows = Table.grid(expand=True, padding=(0, 1))
                rows.add_column(no_wrap=True)
                rows.add_column(no_wrap=True)
                rows.add_column(ratio=1, no_wrap=True, overflow="ellipsis")
                rows.add_column(justify="right", no_wrap=True)
                for m, st, detail in al:
                    g, w, role = STATES.get(st, ("?", st.lower(), "dim"))
                    if st == "IDLE":
                        g, w = "◌", "idle"
                    key = str(self._order.index(m["title"]) + 1) if m["title"] in self._order[:9] else ""
                    age = m.get("age_min")
                    rows.add_row(Text(f"[{key}]" if key else "   ", style=PAL["dim"]),
                                 Text.assemble((f"{g} ", f"bold {PAL['alert']}"), (f"{m['role']:<12}", "bold"),
                                               (w, f"bold {PAL['alert']}")),
                                 Text(detail, style=PAL["text"]),
                                 Text(f"{age}m" if age is not None else "", style=PAL["dim"]))
                aw.update(rows)
            if not light:
                self._render_backlog(view)

        def _render_backlog(self, view):
            bl = self.query_one("#backlog", DataTable)
            fc = view.fc or {}
            doing = {m.get("task"): m for m in view.doc.get("teammates", [])
                     if m["state"] not in GONE_STATES and m.get("task")}
            live = {m["title"] for m in view.doc.get("teammates", []) if m["state"] != "FINISHED"}
            team = view.doc.get("team", "")
            rows = []
            for t in view.doc.get("tasks", []):
                owner = t["owner"][len(team) + 1:] if t["owner"].startswith(team + "-") else t["owner"]
                m = doing.get(t["id"])
                if t["done"]:
                    rank, icon, prog = 3, Text("✓", style=PAL["done"]), Text("done", style=PAL["done"])
                elif m:
                    p = m.get("pct")
                    g, _, role = STATES.get(m["state"], ("?", "", "dim"))
                    rank, icon = 0, Text(g, style=PAL[role])
                    prog = Text.assemble(gbar(p or 0, 10, c0=PAL["accent"], c1=PAL["active"]), f" {p}%" if p is not None else " —")
                elif t.get("ready"):
                    unowned = t["owner"] == "any" or t["owner"] not in live
                    rank, icon = 1, Text("●", style=PAL["warn"] if unowned else PAL["accent"])
                    prog = Text("ready · no owner" if unowned else "ready", style=PAL["warn"] if unowned else PAL["accent"])
                else:
                    rank, icon = 2, Text("○", style=PAL["dim"])
                    prog = Text("after " + ", ".join(t["needs"]), style=PAL["dim"])
                e = fc.get("per_task", {}).get(t["id"])
                eta = Text(f"~{fmt_dur(e)}" if e and not t["done"] else "", style=PAL["accent"])
                rows.append((rank, task_num(t["id"]), t["id"], icon, Text(t["id"], style="bold"),
                             Text(owner, style=PAL["text"] if owner != "any" else PAL["warn"]), prog, eta,
                             Text(t.get("scope") or "", style=PAL["dim"] if t["done"] else PAL["text"])))
            rows.sort(key=lambda r: (r[0], r[1]))
            # Fit Scope to what is left of the panel, so the table never scrolls sideways.
            heads = ("", "Task", "Owner", "Progress", "ETA")
            fixed = sum(max([r[3 + i].cell_len for r in rows] + [len(heads[i])]) + 2 for i in range(5))
            room = max(12, (bl.size.width or 100) - fixed - 2 - 2 - 2)   # border, scrollbar, scope padding
            for r in rows:
                r[8].truncate(room, overflow="ellipsis")
            cur = bl.cursor_row
            bl.clear()
            for r in rows:
                bl.add_row(*r[3:], key=r[2])
            if rows and cur is not None and cur < len(rows):
                bl.move_cursor(row=cur)
            S = view.doc.get("summary") or {}
            bl.border_title = f"Backlog · {S.get('done', 0)}/{S.get('total', 0)} done" if S.get("total") else "Backlog · no T<n> tasks in tasks.md"
            meth = (view.fc or {}).get("method")
            bl.border_subtitle = {"observed": "ETA from observed task times", "projected": "ETA projected from self-reported %",
                                  "rough": "ETA rough: few signals yet"}.get(meth, "")

        def _log(self, t, lvl, text):
            ev = self.query_one("#events", RichLog)
            color = {"error": PAL["alert"], "success": PAL["done"], "warning": PAL["warn"]}.get(lvl, PAL["text"])
            ev.write(Text.assemble((time.strftime("%H:%M:%S", time.localtime(t)) + "  ", PAL["dim"]), (text, color)))

        # layout
        def on_resize(self, event):
            self._relayout(event.size.width, event.size.height)

        def _relayout(self, w, h):
            self.cols = max(1, min(4, (w - 2) // 40))
            compact = h < 30
            if compact != getattr(self, "compact", None):
                self.compact = compact
                for c in self._cards():
                    c.styles.height = 4 if compact else 7
                    c.refresh()
            try:
                self.query_one("#cards", Vertical).styles.grid_size_columns = self.cols
                self.query_one("#bottom", Horizontal).set_class(w < 100, "narrow")
                self.query_one("#bottom", Horizontal).display = h >= 26
            except Exception:
                pass

        # actions
        def _cards(self):
            return list(self.query_one("#cards", Vertical).query(MateCard))

        def action_move(self, delta):
            cards = self._cards()
            if not cards:
                return
            if delta in (3, -3):
                delta = self.cols if delta > 0 else -self.cols
            idx = cards.index(self.focused) if self.focused in cards else -1
            cards[max(0, min(len(cards) - 1, idx + delta))].focus()

        def _selected(self):
            if isinstance(self.focused, MateCard) and self.focused.mate:
                return self.focused.mate
            return None

        def action_details(self):
            m = self._selected()
            if m is None and self.view:
                live = self._sorted_live(self.view)
                m = live[0] if live else None
            if m:
                self.push_screen(DetailScreen(m["title"]))

        def action_key_pane(self, n):
            if self.view and n - 1 < len(self._order):
                title = self._order[n - 1]
                m = next((x for x in self.view.doc["teammates"] if x["title"] == title), None)
                if m:
                    self.show_pane(m)

        def action_show(self):
            m = self._selected()
            if m:
                self.show_pane(m)
            else:
                self.notify("Select a teammate card first (arrows or click).", timeout=3)

        @work(thread=True, group="show")
        def show_pane(self, m):
            rc, msg = self.source.show(m["role"])
            self.call_from_thread(self.notify, msg[0] or m["role"], title=f"show {m['role']}",
                                  severity="information" if rc == 0 else "warning", timeout=4)

        def action_theme_next(self):
            names = [n for n in ("tokyo-night", "catppuccin-mocha", "nord", "dracula", "gruvbox", "rose-pine",
                                 "textual-dark", "textual-light") if n in self.available_themes]
            if names:
                i = names.index(self.theme) if self.theme in names else -1
                self.theme = names[(i + 1) % len(names)]
                self.notify(f"theme: {self.theme}  (TEAM_MONITOR_THEME={self.theme} to keep it)", timeout=3)

        def action_help(self):
            self.push_screen(HelpScreen())


# ── entry point ─────────────────────────────────────────────────────────────────────
def main(argv=None):
    ap = argparse.ArgumentParser(description="Team-mates TUI monitor")
    ap.add_argument("--team")
    ap.add_argument("--team-sh", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "team.sh"))
    ap.add_argument("--interval", type=float, default=float(os.environ.get("TEAM_TUI_INTERVAL") or 5))
    ap.add_argument("--demo", action="store_true", help="play a synthetic team (nothing real is read)")
    ap.add_argument("--demo-speed", type=float, default=40.0)
    ap.add_argument("--demo-at", type=float, default=0.0, help="start the demo at this simulated minute")
    ap.add_argument("--screenshot", help="render one frame headless to this .svg and exit")
    ap.add_argument("--size", default="140x44", help="screenshot size, COLSxROWS")
    ap.add_argument("--open", choices=("details", "help"), help="screenshot: open this screen first")
    ap.add_argument("--walk", action="store_true",
                    help="headless: press every key and open every screen once; exit 1 on a crash")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        return selftest()
    if not HAVE_TEXTUAL:
        print("monitor_tui: Textual is not installed (pip install textual, or run with uv)", file=sys.stderr)
        return EXIT_NO_TEXTUAL
    if a.demo:
        source, hist, interval = DemoSource(speed=a.demo_speed, start_min=a.demo_at), History(), 1.0
        source.backfill(hist)
    else:
        if not a.team:
            ap.error("--team is required (or --demo)")
        source = LiveSource(a.team_sh, a.team)
        kind, doc = source.fetch()
        if kind == "gone":
            print(f"monitor_tui: no teammates recorded for {a.team}", file=sys.stderr)
            return EXIT_TEAM_CLOSED
        run = doc.get("run") if kind == "ok" else None
        hist = History(os.path.join(run, "monitor", "history.jsonl") if run else None)
        interval = max(1.0, a.interval)
    autoclose = os.environ.get("TEAM_MONITOR_AUTOCLOSE", "1") != "0"
    grace = float(os.environ.get("TEAM_MONITOR_CLOSE_GRACE") or 4)
    app = TeamMonitor(source, hist, interval, autoclose=autoclose and not a.demo, grace=grace)
    if a.walk:
        import asyncio

        async def walk():
            async with app.run_test(size=(140, 44)) as pilot:
                for _ in range(450):   # up to 90 s, the LiveSource.fetch timeout: a slow host takes many seconds
                    await pilot.pause(0.2)
                    if app.view:
                        break
                await pilot.pause(1.0)
                await pilot.press("right", "left", "down", "up")
                app._cards()[0].focus()
                await pilot.press("enter")                      # details; then every tab of it
                await pilot.pause(0.5)
                tabs = app.screen.query_one(TabbedContent)
                for tab in ("t-act", "t-hist", "t-info", "t-report"):
                    tabs.active = tab
                    await pilot.pause(0.3)
                await pilot.press("s", "escape", "question_mark", "escape", "t", "t", "r", "1", "2", "s")
                await pilot.pause(0.5)
                assert app.is_running and isinstance(app.screen, Screen), "the app stopped during the walk"
        try:
            asyncio.run(walk())
        except BaseException as e:   # a crash inside the app must fail the walk, not just print
            import traceback
            traceback.print_exc()
            print(f"monitor_tui --walk: FAILED: {type(e).__name__}: {e}", file=sys.stderr)
            return 1
        print("monitor_tui --walk: ok")
        return 0
    if a.screenshot:
        import asyncio
        cols, rows = (int(x) for x in a.size.lower().split("x"))

        async def shot():
            async with app.run_test(size=(cols, rows)) as pilot:
                for _ in range(450):   # up to 90 s, the LiveSource.fetch timeout: a slow host takes many seconds
                    await pilot.pause(0.2)
                    if app.view:
                        break
                await pilot.pause(1.5)
                if a.open == "details":
                    app.action_details()
                elif a.open == "help":
                    app.action_help()
                if a.open:
                    await pilot.pause(1.0)
                cards = app._cards()
                if cards and not a.open:
                    cards[0].focus()
                    await pilot.pause(0.3)
                app.save_screenshot(filename=os.path.basename(a.screenshot),
                                    path=os.path.dirname(os.path.abspath(a.screenshot)))
        asyncio.run(shot())
        return 0
    rc = app.run()
    if getattr(app, "_exception", None):   # a crash is not a quit: let status.sh fall back to the classic monitor
        return 1
    return rc if isinstance(rc, int) else EXIT_QUIT


if __name__ == "__main__":
    sys.exit(main())
