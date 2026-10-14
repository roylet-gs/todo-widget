#!/usr/bin/env python3
"""End-to-end tests for Todo Widget.

Launches the real app (build/TodoWidget.app) in e2e mode against a throwaway database and
preference suite, seeds it through the real `todo` CLI and `todo mcp` server, drives it through
the e2e command channel (see app/Sources/TodoWidget/E2E.swift), asserts on its state, and saves
window snapshots to e2e/tmp/<spec>--<name>.png.

Usage:
  python3 e2e/run.py                 # all specs
  python3 e2e/run.py drawer sticky   # specs whose name contains any of these words
  python3 e2e/run.py --build         # rebuild build/TodoWidget.app first
  python3 e2e/run.py --list

No dependencies beyond Python 3 and the built app. Your real data and settings are not touched.
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "TodoWidget.app"
APP_BIN = APP / "Contents" / "MacOS" / "TodoWidget"
TODO = APP / "Contents" / "MacOS" / "todo"
OUT = ROOT / "e2e" / "tmp"

SPECS: list = []


def spec(fn):
    SPECS.append(fn)
    return fn


class Failure(AssertionError):
    pass


def expect(cond, msg):
    if not cond:
        raise Failure(msg)


# ---------------------------------------------------------------------------
# Seeding through the real CLI and MCP server
# ---------------------------------------------------------------------------

class Mcp:
    """Minimal stdio MCP client for `todo mcp` (one request at a time, like a real agent)."""

    def __init__(self, env, agent):
        self.p = subprocess.Popen([str(TODO), "mcp", "--agent", agent], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, text=True, env=env)
        self.n = 0
        self.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "e2e", "version": "0"}})
        self.send("notifications/initialized", notify=True)

    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            self.n += 1
            msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        while True:
            m = json.loads(self.p.stdout.readline())
            if m.get("id") == self.n:
                return m

    def call(self, name, **args):
        r = self.send("tools/call", {"name": name, "arguments": args})["result"]
        if r.get("isError"):
            raise Failure(f"MCP {name} failed: {r['content'][0]['text']}")
        return json.loads(r["content"][0]["text"]) if r["content"][0]["text"].startswith("{") else r["content"][0]["text"]

    def close(self):
        self.p.stdin.close()
        self.p.wait(timeout=10)


def agent_run(env, agent, summary, tasks):
    m = Mcp(env, agent)
    m.call("start_run", agent=agent)
    for t in tasks:
        m.call("upsert_task", **t)
    m.call("finish_run", summary=summary)
    m.close()


def seed(env, db):
    todo = lambda *a: subprocess.run([str(TODO), *a], env=env, check=True, capture_output=True)
    todo("sources", "add", "Slack", "--kind", "Messages", "--instructions", "DMs and mentions that ask me for something")
    todo("sources", "add", "Gmail", "--kind", "Email", "--instructions", "Email from people that needs a reply")
    todo("add", "Update the estimate on CDI-88", "--due", "Fri", "--source", "Linear")
    agent_run(env, "Claude Code", "3 new from Slack, GitHub and Calendar", [
        dict(source_ref="slack:sam-q4", title="Reply to Sam about the Q4 export format", priority=1, due="Today",
             source="Slack", source_url="https://slack.com/", source_from="Sam · #cde-ops · 8:40",
             excerpt="Hey, can we lock the Q4 export format today? We freeze the pipeline tomorrow morning.",
             summary="Sam needs a yes or no on CSV vs Parquet before their pipeline freeze.",
             rationale="A direct ask with a same-day deadline that blocks another team."),
        dict(source_ref="gh:412", title="Review PR #412: connections retry logic", priority=1, source="GitHub",
             summary="Two-file change to retry backoff; you are the only reviewer."),
        dict(source_ref="cal:thu", title="Prep notes for Thursday customer call", priority=2, due="Thu", source="Calendar"),
    ])
    agent_run(env, "Hermes", "2 new from Linear and Gmail", [
        dict(source_ref="linear:CONNECT-210", title="Answer the triage question on CONNECT-210", priority=2, source="Linear"),
        dict(source_ref="gmail:expenses", title="Submit September expenses", priority=3, due="Oct 20", source="Gmail"),
    ])
    # Show the seeded runs in the "what changed" strip (as if not yet seen).
    with sqlite3.connect(db) as c:
        c.execute("INSERT INTO settings (key, value) VALUES ('last_seen_at', '0') "
                  "ON CONFLICT(key) DO UPDATE SET value = excluded.value")


# ---------------------------------------------------------------------------
# Driving the app
# ---------------------------------------------------------------------------

class App:
    def __init__(self, name):
        self.name = name
        self.dir = OUT / "run" / name
        shutil.rmtree(self.dir, ignore_errors=True)
        self.dir.mkdir(parents=True)
        self.db = self.dir / "todo.db"
        self.env = {**os.environ, "TODO_DB": str(self.db), "TODO_E2E_DIR": str(self.dir)}
        self.n = 0
        self.proc = None
        self.shots: list[str] = []

    def start(self, seeded=True):
        if seeded:
            seed(self.env, self.db)
        self.proc = subprocess.Popen([str(APP_BIN)], env=self.env,
                                     stdout=open(self.dir / "app.log", "w"), stderr=subprocess.STDOUT)
        self.wait_for(lambda: (self.dir / "ready.json").exists(), "app did not become ready", timeout=15)
        return self

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.cmd("quit", timeout=3)
            except Failure:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def cmd(self, command, timeout=10, **args):
        self.n += 1
        cid = f"{self.n:05d}"
        tmp = self.dir / f"{cid}.cmd.json.tmp"
        tmp.write_text(json.dumps({"cmd": command, **args}))
        tmp.rename(self.dir / f"{cid}.cmd.json")
        res = self.dir / f"{cid}.res.json"
        self.wait_for(res.exists, f"no response to '{command}'", timeout=timeout)
        out = json.loads(res.read_text())
        if not out.get("ok"):
            raise Failure(f"command '{command}' failed: {out.get('error')}")
        return out

    def state(self):
        return self.cmd("state")

    def wait_for(self, fn, msg, timeout=5.0):
        end = time.time() + timeout
        while time.time() < end:
            if self.proc is not None and self.proc.poll() is not None:
                raise Failure(f"app exited ({self.proc.returncode}); see {self.dir / 'app.log'}")
            v = fn()
            if v:
                return v
            time.sleep(0.05)
        raise Failure(msg)

    def wait_state(self, pred, msg, timeout=5.0):
        last = {}

        def check():
            nonlocal last
            last = self.state()
            return pred(last)

        try:
            self.wait_for(check, msg, timeout)
        except Failure:
            raise Failure(f"{msg} (last state: {json.dumps({k: last.get(k) for k in ('open', 'drawerOpen', 'edge', 'tabFrame', 'recentRuns')})[:600]})")
        return last

    def settle(self, seconds=0.45):
        """Let animations (drawer slide, tab snap) finish before asserting on frames or snapshotting."""
        time.sleep(seconds)

    def snapshot(self, window, label):
        self.settle()
        name = f"{self.name}--{label}"
        path = self.cmd("snapshot", window=window, name=name)["path"]
        dest = OUT / f"{name}.png"
        shutil.move(path, dest)
        self.shots.append(dest.name)
        return dest


def titles(tasks):
    return [t["title"] for t in tasks]


# ---------------------------------------------------------------------------
# Specs
# ---------------------------------------------------------------------------

@spec
def drawer_shows_seeded_tasks(app: App):
    app.cmd("open_drawer")
    s = app.wait_state(lambda s: s["drawerOpen"], "drawer did not open")
    open_titles = titles(s["open"])
    expect(len(open_titles) == 6, f"expected 6 open tasks, got {open_titles}")
    expect(open_titles[0] == "Update the estimate on CDI-88", f"user task should be on top, got {open_titles[0]}")
    expect(s["unread"] == 5, f"agent-added tasks should be unread: {s['unread']}")
    actors = [r["actor"] for r in s["recentRuns"]]
    expect(actors == ["Claude Code", "Hermes"], f"what-changed strip runs: {actors}")
    chips = {t["title"]: t["chip"] for t in s["open"]}
    expect(chips["Submit September expenses"] == "new", f"new chip missing: {chips}")
    app.cmd("set_pref", key="appearance", value="light")
    app.snapshot("drawer", "light")
    app.cmd("set_pref", key="appearance", value="dark")
    app.snapshot("drawer", "dark")
    app.snapshot("tab", "tab")


@spec
def task_detail_done_and_undo(app: App):
    app.cmd("open_drawer")
    s = app.cmd("select", title="Reply to Sam")
    expect(s["selected"] == "Reply to Sam about the Q4 export format", f"selected: {s['selected']}")
    s = app.wait_state(lambda s: not next(t for t in s["open"] if t["title"].startswith("Reply to Sam"))["unread"],
                       "opening a task should mark it read")
    app.snapshot("drawer", "detail")
    app.cmd("back")
    app.cmd("toggle_done", title="Review PR #412")
    s = app.wait_state(lambda s: "Review PR #412: connections retry logic" in titles(s["done"]), "task not marked done")
    expect(s["toast"] and s["toast"].startswith("Completed"), f"toast: {s['toast']}")
    app.snapshot("drawer", "after-done")
    app.cmd("undo")
    app.wait_state(lambda s: "Review PR #412: connections retry logic" in titles(s["open"]), "undo did not reopen the task")


@spec
def drag_to_reorder_marks_user_ranked(app: App):
    app.cmd("open_drawer")
    app.cmd("move", title="Submit September expenses", index=0)
    s = app.wait_state(lambda s: s["open"][0]["title"] == "Submit September expenses", "move did not reorder")
    expect(s["open"][0]["userRanked"], "moved task should be marked as placed by the user")
    app.cmd("undo")
    app.wait_state(lambda s: s["open"][0]["title"] == "Update the estimate on CDI-88", "undo did not restore order")


@spec
def live_update_from_agent(app: App):
    app.cmd("open_drawer")
    agent_run(app.env, "E2E Agent", "1 new from Slack", [
        dict(source_ref="slack:live", title="Live task from an agent run", priority=1, source="Slack"),
    ])
    s = app.wait_state(lambda s: "Live task from an agent run" in titles(s["open"]),
                       "app did not pick up the MCP change", timeout=5)
    t = next(t for t in s["open"] if t["title"] == "Live task from an agent run")
    expect(t["unread"] and t["addedBy"] == "E2E Agent", f"live task: {t}")
    expect("E2E Agent" in [r["actor"] for r in s["recentRuns"]], f"run strip: {s['recentRuns']}")
    app.snapshot("drawer", "live-update")


@spec
def sticky_tab_drag_snaps_to_edges(app: App):
    s = app.state()
    screen, tab0 = s["screen"], s["tabFrame"]
    expect(s["edge"] == "right", f"default edge: {s['edge']}")
    expect(abs(tab0["x"] + tab0["w"] - (screen["x"] + screen["w"])) < 1, f"tab not flush right: {tab0} in {screen}")

    # Small pull: resists (moves a fraction) and stays attached; releasing puts it back.
    app.cmd("drag_begin")
    s = app.cmd("drag_move", dx=-8, dy=0)
    moved = tab0["x"] - s["tabFrame"]["x"]
    expect(not s["tabFree"], "should still be stuck after 8pt")
    expect(0 < moved < 5, f"stuck tab should move a fraction of 8pt, moved {moved:.1f}")
    app.cmd("drag_end")
    app.settle()
    s = app.state()
    expect(abs(s["tabFrame"]["x"] - tab0["x"]) < 1 and s["edge"] == "right", f"released early should spring back: {s['tabFrame']}")

    # Past the break distance it pops free; dropping on the left half snaps to the left edge.
    app.cmd("drag_begin")
    s = app.cmd("drag_move", dx=-30, dy=0)
    expect(s["tabFree"], "should break free past the snap distance")
    app.cmd("drag_move", dx=-(screen["w"] - 120), dy=-80)
    app.cmd("drag_end")
    s = app.wait_state(lambda s: s["edge"] == "left" and not s["tabFree"], "tab did not snap to the left edge", timeout=3)
    expect(abs(s["tabFrame"]["x"] - screen["x"]) < 1, f"tab not flush left: {s['tabFrame']}")
    app.snapshot("tab", "left-edge")
    app.cmd("open_drawer")
    app.settle()
    s = app.state()
    expect(abs(s["drawerFrame"]["x"] - (screen["x"] + 10)) < 2, f"drawer should open from the left: {s['drawerFrame']}")
    app.snapshot("drawer", "left-drawer")


@spec
def click_outside_closes_unless_pinned(app: App):
    app.cmd("open_drawer")
    app.cmd("click_outside")
    app.wait_state(lambda s: not s["drawerOpen"], "unpinned drawer should close on outside click")
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    app.cmd("click_outside")
    app.settle()
    expect(app.state()["drawerOpen"], "pinned drawer should stay open")


@spec
def settings_tabs(app: App):
    for tab in ["general", "sources", "prompt", "schedules", "agents", "history"]:
        s = app.cmd("settings", tab=tab)
        expect(s["settingsOpen"], f"settings did not open on {tab}")
        app.snapshot("settings", tab)
    app.cmd("close_settings")


@spec
def setup_flow(app: App):
    for step, label in enumerate(["welcome", "placement", "sources", "agents", "schedule", "done"]):
        s = app.cmd("setup", step=step)
        expect(s["setupOpen"], "setup window did not open")
        app.snapshot("setup", f"{step}-{label}")
    app.cmd("close_setup")


# ---------------------------------------------------------------------------

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if "--list" in flags:
        print("\n".join(f.__name__ for f in SPECS))
        return 0
    if "--build" in flags or not APP_BIN.exists():
        subprocess.run([str(ROOT / "scripts" / "bundle-app.sh")], check=True)

    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    selected = [f for f in SPECS if not args or any(a in f.__name__ for a in args)]
    results = []
    for fn in selected:
        app = App(fn.__name__)
        t0 = time.time()
        status, error = "pass", None
        try:
            app.start()
            fn(app)
        except Exception as e:  # noqa: BLE001 — report every failure, keep going
            status = "fail"
            error = str(e) if isinstance(e, Failure) else traceback.format_exc()
            try:
                app.snapshot("drawer", "FAILURE")
            except Exception:  # noqa: BLE001
                pass
        finally:
            app.stop()
        dur = time.time() - t0
        results.append({"spec": fn.__name__, "status": status, "seconds": round(dur, 1), "error": error, "screenshots": app.shots})
        mark = "✅" if status == "pass" else "❌"
        print(f"{mark} {fn.__name__} ({dur:.1f}s)" + (f"\n   {error}" if error else ""))

    (OUT / "results.json").write_text(json.dumps(results, indent=2))
    passed = sum(r["status"] == "pass" for r in results)
    print(f"\n{passed}/{len(results)} specs passed · screenshots in {OUT.relative_to(ROOT)}/")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
