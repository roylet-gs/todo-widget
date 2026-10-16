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

    def call(self, tool, /, **args):
        r = self.send("tools/call", {"name": tool, "arguments": args})["result"]
        if r.get("isError"):
            raise Failure(f"MCP {tool} failed: {r['content'][0]['text']}")
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
    todo("add", "Update the estimate on CDI-88", "-p", "1", "--due", "Fri", "--source", "Linear")
    agent_run(env, "Claude Code", "3 new from Slack, GitHub and Calendar", [
        dict(source_ref="slack:sam-q4", title="Reply to Sam about the Q4 export format", priority=1, due="Today",
             source="Slack", source_url="https://acme.slack.com/archives/C0123/p1700000000000100", source_from="Sam · #cde-ops · 8:40",
             excerpt="Hey, can we lock the Q4 export format today? We freeze the pipeline tomorrow morning.",
             summary="Sam needs a yes or no on CSV vs Parquet before their pipeline freeze.",
             rationale="A direct ask with a same-day deadline that blocks another team."),
        dict(source_ref="gh:412", title="Review PR #412: connections retry logic", priority=1, source="GitHub",
             source_url="https://github.com/acme/app/pull/412", source_label="PR #412",
             summary="Two-file change to retry backoff; you are the only reviewer."),
        dict(source_ref="cal:thu", title="Prep notes for Thursday customer call", priority=2, due="Thu", source="Calendar"),
    ])
    agent_run(env, "Hermes", "2 new from Linear and Gmail", [
        dict(source_ref="linear:CONNECT-210", title="Answer the triage question on CONNECT-210", priority=2, source="Linear",
             source_url="https://linear.app/acme/issue/CONNECT-210/retry-triage"),
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

    def cmd(self, command, /, timeout=10, **args):
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


def to_list(app: App):
    """The drawer opens in quick add; ↓ steps onto the list (no-op offscreen, where the field may not take focus)."""
    app.settle()
    s = app.state()
    if s["typing"]:
        s = app.cmd("key", key="down")
        expect(s["handled"] and not s["typing"], f"down should leave quick add: {s['handled']} typing={s['typing']}")
    return s


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
    # Pinned so a stray click elsewhere on the Mac can't close the drawer (which also clears the selection).
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    s = app.cmd("select", title="Reply to Sam")
    expect(s["selected"] == "Reply to Sam about the Q4 export format", f"selected: {s['selected']}")
    s = app.wait_state(lambda s: not next(t for t in s["open"] if t["title"].startswith("Reply to Sam"))["unread"],
                       "opening a task should mark it read")
    app.snapshot("drawer", "detail")
    s = app.state()
    expect(s["drawerOpen"] and s["selected"] == "Reply to Sam about the Q4 export format",
           f"detail should still be showing before marking done: open={s['drawerOpen']} selected={s['selected']}")
    s = app.cmd("toggle_done", title="Reply to Sam")
    expect(s["selected"] is None, f"marking done from the detail should go back to the list: {s['selected']}")
    app.cmd("undo")
    app.wait_state(lambda s: "Reply to Sam about the Q4 export format" in titles(s["open"]), "undo did not reopen")
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
    expect(s["open"][0]["priority"] == 1, f"dragging a P3 task into the P1 group should make it P1: {s['open'][0]}")
    expect(s["toast"] == "Moved “Submit September expenses” to P1", f"toast: {s['toast']}")
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
def agent_done_section(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    # The user completes one task; an agent completes another through the MCP.
    app.cmd("toggle_done", title="Prep notes")
    m = Mcp(app.env, "Hermes")
    m.call("start_run", agent="Hermes")
    task = next(t for t in json.loads(m.call("list_tasks")) if t["title"].startswith("Review PR #412"))
    m.call("complete_task", id=task["id"], reason="PR merged")
    m.call("finish_run", summary="1 done")
    m.close()
    s = app.wait_state(lambda s: "Review PR #412: connections retry logic" in titles(s["agentDone"]),
                       "agent-completed task should be in the agent done section")
    expect(titles(s["done"]) == ["Prep notes for Thursday customer call"], f"user done: {titles(s['done'])}")
    expect(s["agentDoneExpanded"] and not s["doneExpanded"], "agent done section open, user done section collapsed")
    app.snapshot("drawer", "agent-done")
    # Both clear like any done task once they're old enough.
    with sqlite3.connect(app.db) as c:
        c.execute("UPDATE tasks SET done_at = 1 WHERE status = 'done'")
    app.cmd("close_drawer")
    app.cmd("open_drawer")
    app.wait_state(lambda s: not s["agentDone"] and not s["done"], "done tasks of both kinds should clear")


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
def drawer_resizes_from_inner_edge(app: App):
    app.cmd("open_drawer")
    app.settle()
    s = app.state()
    screen, f0 = s["screen"], s["drawerFrame"]
    right = screen["x"] + screen["w"]
    expect(abs(f0["w"] - 400) < 1, f"default width: {f0}")
    # Docked right, the inner edge is the left one: dragging it left widens the drawer.
    app.cmd("resize_begin")
    app.cmd("resize_move", dx=-200)
    s = app.cmd("resize_end")
    f = s["drawerFrame"]
    expect(abs(f["w"] - 600) < 1 and abs(s["drawerWidth"] - 600) < 1, f"drawer should be 600 wide: {f}")
    expect(abs(f["x"] + f["w"] - (right - 10)) < 2, f"drawer should stay against the right edge: {f}")
    app.snapshot("drawer", "wide")
    # It can't be squeezed below the minimum.
    app.cmd("resize_begin")
    app.cmd("resize_move", dx=1000)
    s = app.cmd("resize_end")
    expect(abs(s["drawerFrame"]["w"] - 340) < 1, f"drawer should stop at its minimum: {s['drawerFrame']}")


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
    for tab in ["general", "themes", "keyboard", "sources", "prompt", "schedule", "learning", "history"]:
        s = app.cmd("settings", tab=tab)
        expect(s["settingsOpen"], f"settings did not open on {tab}")
        app.snapshot("settings", tab)
    app.cmd("close_settings")


@spec
def settings_handoff(app: App):
    # Unpinned: opening Settings collapses the drawer, and the app turns regular (Dock icon, app menu) meanwhile.
    app.cmd("open_drawer")
    s = app.cmd("settings")
    expect(s["settingsOpen"], "settings did not open")
    s = app.wait_state(lambda s: not s["drawerOpen"], "unpinned drawer should collapse when settings opens")
    expect(s["activationPolicy"] == "regular", f"policy while settings open: {s['activationPolicy']}")
    expect(s["appMenuHasSettings"], "app menu should offer Settings…")
    app.cmd("close_settings")
    app.wait_state(lambda s: s["activationPolicy"] == "accessory", "should go back to menu-bar-only once settings closes")
    # Pinned: the drawer stays open and Settings sits at (at least) its level, ordered above it.
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    s = app.cmd("settings")
    app.settle()
    s = app.state()
    expect(s["drawerOpen"], "pinned drawer should stay open when settings opens")
    expect(s["settingsLevel"] >= s["drawerLevel"], f"settings level {s['settingsLevel']} below drawer {s['drawerLevel']}")
    app.snapshot("settings", "over-pinned-drawer")
    app.cmd("close_settings")


@spec
def keyboard_navigate_and_open(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    s = app.cmd("open_drawer")
    s = to_list(app)
    order = titles(s["open"])
    expect(s["highlighted"] == order[0], f"opening should highlight the first task: {s['highlighted']}")
    app.cmd("key", key="down")
    s = app.cmd("key", key="down")
    expect(s["highlighted"] == order[2], f"two downs: {s['highlighted']} (handled={s['handled']} typing={s['typing']})")
    app.snapshot("drawer", "highlighted")
    s = app.cmd("key", key="up")
    expect(s["highlighted"] == order[1], f"up: {s['highlighted']}")
    s = app.cmd("key", key="down", modifiers=["command"])
    expect(s["highlighted"] == order[-1], f"cmd-down should go to the last task: {s['highlighted']}")
    s = app.cmd("key", key="up", modifiers=["command"])
    expect(s["highlighted"] == order[0], f"cmd-up should go to the first task: {s['highlighted']}")
    app.cmd("key", key="down")
    s = app.cmd("key", key="return")
    expect(s["selected"] == order[1], f"return should open the highlighted task: {s['selected']}")
    app.settle()
    app.snapshot("drawer", "detail-keys")
    s = app.cmd("key", key="escape")
    expect(s["selected"] is None and s["highlighted"] == order[1], f"esc back keeps highlight: {s['highlighted']}")
    s = app.cmd("key", key="?")
    expect(s["shortcutsOpen"], "? should open the shortcuts sheet")
    app.settle()
    app.snapshot("drawer", "shortcuts")
    s = app.cmd("key", key="escape")
    expect(not s["shortcutsOpen"] and s["drawerOpen"],
           f"esc should close the sheet, not the drawer: sheet={s['shortcutsOpen']} open={s['drawerOpen']} handled={s['handled']} typing={s['typing']}")
    s = app.cmd("key", key="escape")
    expect(not s["drawerOpen"], "esc on the list should close the drawer")


@spec
def keyboard_open_source(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    app.cmd("open_drawer")
    to_list(app)
    # From the list: highlight the Slack task and open its source without opening the detail.
    app.cmd("select", title="Sam about the Q4")
    app.cmd("key", key="escape")
    s = app.cmd("key", key="o")
    opened = s["lastOpened"] or ""
    expect(s["handled"] and s["selected"] is None, f"o on the list should not open the detail: {s['selected']}")
    expect(opened in ("web:https://acme.slack.com/archives/C0123/p1700000000000100",
                      "app:com.tinyspeck.slackmacgap https://acme.slack.com/archives/C0123/p1700000000000100"),
           f"slack link: {opened}")
    # From the detail: the Linear link goes to the desktop app's scheme when it's installed.
    app.cmd("select", title="CONNECT-210")
    app.settle()
    app.snapshot("drawer", "detail-source")
    s = app.cmd("key", key="o")
    opened = s["lastOpened"] or ""
    expect(s["handled"] and s["selected"] and "CONNECT-210" in s["selected"], f"o in the detail keeps it open: {s['selected']}")
    expect(opened in ("web:https://linear.app/acme/issue/CONNECT-210/retry-triage",
                      "app:com.linear linear://acme/issue/CONNECT-210/retry-triage"),
           f"linear link: {opened}")
    # A task without a link lets the key through.
    app.cmd("select", title="Thursday customer call")
    s = app.cmd("key", key="o")
    expect(not s["handled"], "o on a task without a source link should do nothing")


@spec
def keyboard_done_delete_undo(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    s = app.cmd("open_drawer")
    s = to_list(app)
    order = titles(s["open"])
    s = app.cmd("key", key="space")
    s = app.wait_state(lambda s: order[0] in titles(s["done"]), "space should mark the first task done")
    expect(s["highlighted"] == order[1], f"highlight should move to the next task: {s['highlighted']}")
    app.cmd("key", key="delete")
    s = app.wait_state(lambda s: order[1] not in titles(s["open"]), "delete should remove the highlighted task")
    expect(s["highlighted"] == order[2], f"highlight after delete: {s['highlighted']}")
    s = app.cmd("key", key="z", modifiers=["command"])
    s = app.wait_state(lambda s: order[1] in titles(s["open"]), "cmd-z should restore the deleted task")
    # Move the highlighted task up with the keyboard.
    app.cmd("key", key="up", modifiers=["option", "command"])
    app.wait_state(lambda s: titles(s["open"]).index(order[2]) == 0, "opt-cmd-up should move the task up")
    # Done section and detail actions.
    s = app.cmd("key", key="d", modifiers=["command"])
    expect(s["doneExpanded"], "cmd-d should expand done tasks")
    s = app.cmd("key", key="up", modifiers=["command"])
    s = app.cmd("key", key="return")
    expect(s["selected"] is not None, "return should open the task")
    title = s["selected"]
    s = app.cmd("key", key="space")
    expect(s["selected"] is None, "marking done from the detail should go back to the list")
    app.wait_state(lambda s: title in titles(s["done"]), "space in detail should mark it done")


@spec
def keyboard_text_field_passthrough(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    s = app.cmd("open_drawer")
    n = len(s["open"])
    s = app.cmd("focus_quick_add")
    app.settle()
    s = app.state()
    if not s["typing"]:
        print("    (quick add did not take focus offscreen; skipping passthrough checks)")
        return
    s = app.cmd("key", key="space")
    expect(not s["handled"] and len(s["open"]) == n, "space in quick add should type, not mark done")
    s = app.cmd("key", key="delete")
    expect(not s["handled"], "delete in quick add should edit text, not delete a task")
    s = app.cmd("key", key="escape")
    expect(s["handled"] and not s["drawerOpen"], "esc in quick add should collapse the drawer")


@spec
def quick_add_focused_on_open(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    s = app.cmd("open_drawer")
    order = titles(s["open"])
    app.settle()
    s = app.state()
    if not s["typing"]:
        print("    (quick add did not take focus offscreen; skipping focus checks)")
        return
    app.cmd("type_quick_add", text="Book the dentist")
    app.settle()
    app.snapshot("drawer", "quick-add-focused")
    s = app.cmd("key", key="escape")
    expect(s["handled"] and not s["drawerOpen"], "esc in quick add should collapse the drawer")
    app.cmd("open_drawer")
    app.settle()
    s = app.state()
    expect(s["typing"], "reopening should focus quick add again")
    expect(s["quickAddDraft"] == "Book the dentist", f"draft should survive closing: {s['quickAddDraft']!r}")
    s = app.cmd("key", key="down")
    expect(s["handled"] and not s["typing"], "down should leave quick add")
    expect(s["highlighted"] == order[0], f"down should land on the first task: {s['highlighted']}")
    app.settle()
    app.snapshot("drawer", "on-list")
    s = app.cmd("key", key="down")
    expect(s["highlighted"] == order[1], f"next down moves down the list: {s['highlighted']}")
    expect(s["quickAddDraft"] == "Book the dentist", "leaving the field keeps the draft")
    # Back into quick add from further down: ↓ still goes to the first task, not where the cursor was.
    app.cmd("key", key="n", modifiers=["command"])
    app.settle()
    s = app.cmd("key", key="down")
    expect(not s["typing"] and s["highlighted"] == order[0], f"down from quick add goes to the first task: {s['highlighted']}")
    s = app.cmd("key", key="return")
    expect(s["selected"] == order[0], f"return on the list opens the task: {s['selected']}")


@spec
def keyboard_global_toggle(app: App):
    ctrl = ["control"]
    s = app.cmd("modifier_events", modifier="command", events=["down", "up", "down", "up"])
    expect(not s["drawerOpen"], "a plain double-tap cmd should do nothing by default")
    s = app.cmd("modifier_events", modifier="command", holding=ctrl, events=["down", "up", "down", "up"])
    expect(s["drawerOpen"], "ctrl + double-tap cmd should open the drawer")
    s = app.cmd("modifier_events", modifier="command", holding=ctrl, events=["down", "up", "down", "up"])
    expect(not s["drawerOpen"], "ctrl + double-tap cmd again should close it")
    s = app.cmd("modifier_events", modifier="command", holding=ctrl, events=["down", "key", "up", "down", "up"])
    expect(not s["drawerOpen"], "ctrl-cmd-C then a tap is not a double tap")
    expect(s["keymap"]["toggleWidget"] == "⌃ + double-tap ⌘", f"keymap: {s['keymap']['toggleWidget']}")
    s = app.cmd("modifier_events", modifier="option", events=["down", "up", "down", "up"])
    expect(not s["drawerOpen"], "double-tap option should do nothing by default")
    app.cmd("set_keybinding", action="toggleWidget", doubleTap="option")
    s = app.cmd("modifier_events", modifier="option", events=["down", "up", "down", "up"])
    expect(s["drawerOpen"], "double-tap option should toggle once bound")
    expect(s["keymap"]["toggleWidget"] == "Double-tap ⌥", f"keymap: {s['keymap']['toggleWidget']}")


@spec
def keyboard_footer_toggle_hint(app: App):
    # The footer tells you how to hide the widget, and gives that hint up first when the drawer is narrow.
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("set_pref", key="drawerWidth", value=400)
    app.cmd("open_drawer")
    app.settle()
    app.snapshot("drawer", "footer-toggle")
    app.cmd("set_pref", key="drawerWidth", value=340)
    app.settle()
    app.snapshot("drawer", "footer-narrow")
    app.cmd("set_keybinding", action="toggleWidget", doubleTap="option")
    app.cmd("set_pref", key="drawerWidth", value=480)
    app.settle()
    app.snapshot("drawer", "footer-toggle-option")


@spec
def keyboard_rebind(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    s = app.cmd("open_drawer")
    s = to_list(app)
    order = titles(s["open"])
    app.cmd("set_keybinding", action="toggleDone", key="x")
    s = app.cmd("key", key="space")
    expect(not s["handled"] and order[0] in titles(s["open"]), "space should no longer mark done")
    s = app.cmd("key", key="x")
    expect(s["handled"], "x should be handled once bound")
    s = app.wait_state(lambda s: order[0] in titles(s["done"]), "x should mark done once bound")
    expect(s["keymap"]["toggleDone"] == "X", f"keymap: {s['keymap']['toggleDone']}")
    app.snapshot("drawer", "rebound")
    app.cmd("settings", tab="keyboard")
    app.snapshot("settings", "keyboard-rebound")
    app.cmd("close_settings")
    app.cmd("set_pref", key="showKeyHints", value=False)
    app.snapshot("drawer", "no-hints")
    s = app.cmd("reset_keymap")
    expect(s["keymap"]["toggleDone"] == "Space", "reset should restore Space")


@spec
def update_failure(app: App):
    # A failed Homebrew upgrade must give the button back and say why, not hang on "Updating…".
    app.cmd("open_drawer")
    s = app.cmd("simulate_update", latest="99.0.0", brew="/usr/bin/false")
    expect(s["update"]["available"], "update banner should be offered")
    app.settle()
    app.snapshot("drawer", "update-available")
    app.cmd("update_now")
    s = app.wait_state(lambda s: not s["update"]["updating"] and s["update"]["error"], "update never finished")
    expect("Update failed" in s["update"]["error"], f"unexpected error: {s['update']['error']}")
    app.settle()
    app.snapshot("drawer", "update-failed")


@spec
def theme_presets(app: App):
    s = app.cmd("state")
    presets = s["themes"]
    expect(len(presets) >= 8, f"expected at least 8 preset themes, got {presets}")
    app.cmd("open_drawer")
    app.wait_state(lambda s: s["drawerOpen"], "drawer did not open")
    for t in presets:
        for appearance in ["light", "dark"]:
            app.cmd("set_pref", key="appearance", value=appearance)
            s = app.cmd("set_pref", key="theme", value=t)
            expect(s["theme"] == t, f"theme did not switch to {t}")
            app.snapshot("drawer", f"{t}-{appearance}")
    # A theme made for dark switches the appearance when picked.
    app.cmd("set_pref", key="appearance", value="light")
    s = app.cmd("set_pref", key="theme", value="midnight")
    expect(s["appearance"] == "dark", f"midnight should switch to dark, got {s['appearance']}")
    app.cmd("set_pref", key="appearance", value="system")
    s = app.cmd("set_pref", key="theme", value="default")
    expect(s["theme"] == "default", "could not return to the default theme")


@spec
def theme_builder(app: App):
    s = app.cmd("settings", tab="themes")
    expect(s["settingsOpen"], "settings did not open on themes")
    app.snapshot("settings", "themes-presets")
    palette = {"accent": "#7A3EC8", "background": "#F1E9FB", "text": "#24123D", "priority": "#D2491F", "done": "#4C9F70"}
    dark = {"accent": "#A57BF0", "background": "#1C1428", "text": "#EDE4FA", "priority": "#FF8A5C", "done": "#5CC08A"}
    theme = {"id": "custom-e2e", "name": "Lavender", "light": palette, "dark": dark}
    s = app.cmd("save_theme", theme=theme)
    expect(s["theme"] == "custom-e2e", f"custom theme not selected: {s['theme']}")
    expect(s["customThemes"] == ["custom-e2e"], f"custom theme not saved: {s['customThemes']}")
    # Reopen so the pane picks up the selected custom theme in the builder.
    app.cmd("set_pref", key="appearance", value="light")
    app.cmd("settings", tab="themes")
    app.snapshot("settings", "themes-builder")
    app.cmd("close_settings")
    app.cmd("open_drawer")
    app.wait_state(lambda s: s["drawerOpen"], "drawer did not open")
    app.snapshot("drawer", "custom-theme")
    s = app.cmd("delete_theme", id="custom-e2e")
    expect(s["customThemes"] == [], "custom theme not deleted")
    expect(s["theme"] == "default", f"deleting the active theme should fall back to default, got {s['theme']}")


@spec
def setup_flow(app: App):
    for step, label in enumerate(["welcome", "theme", "connect", "sources", "schedule", "done"]):
        s = app.cmd("setup", step=step)
        expect(s["setupOpen"], "setup window did not open")
        app.snapshot("setup", f"{step}-{label}")
    app.cmd("close_setup")


@spec
def sources_managed_by_agent(app: App):
    # Starts from the discovery step with no sources, as a fresh setup would.
    for s in app.state()["sources"]:
        subprocess.run([str(TODO), "sources", "rm", s["name"]], env=app.env, check=True, capture_output=True)
    app.wait_state(lambda s: s["sources"] == [], "sources not cleared")
    app.cmd("setup", step=3)
    app.snapshot("setup", "waiting-for-agent")

    m = Mcp(app.env, "Discovery Bot")
    m.call("start_run", agent="Discovery Bot")
    m.call("save_source", name="Slack", kind="Messages", instructions="DMs and threads in #cde-ops that ask me for something")
    m.call("save_source", name="Linear", kind="Issues", instructions="Issues assigned to me in CDI and CONNECT")
    s = app.wait_state(lambda s: [x["name"] for x in s["sources"]] == ["Slack", "Linear"], "app did not show the agent's sources", timeout=5)
    app.snapshot("setup", "sources-discovered")

    m.call("remove_source", name="slack")
    m.call("finish_run", summary="Set up 1 source")
    m.close()
    s = app.wait_state(lambda s: [x["name"] for x in s["sources"]] == ["Linear"], "removal did not show up")
    # Agents aren't registered anywhere: the name only appears as the actor on its run.
    with sqlite3.connect(app.db) as c:
        actors = [r[0] for r in c.execute("SELECT DISTINCT actor FROM groups WHERE kind = 'run'")]
        tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type = 'table'")]
    expect("Discovery Bot" in actors, f"run actors: {actors}")
    expect(not any("agent" in t for t in tables), f"unexpected agent table: {tables}")
    expect("own name" in s["discoveryPrompt"] and "{{" not in s["discoveryPrompt"], "discovery prompt should be agent-agnostic")
    app.cmd("close_setup")
    app.cmd("settings", tab="sources")
    app.snapshot("settings", "sources")


@spec
def sources_edited_in_settings(app: App):
    app.cmd("settings", tab="sources")
    app.snapshot("settings", "sources-before")
    cli_sources = lambda: json.loads(subprocess.run([str(TODO), "--json", "sources"], env=app.env, check=True,
                                                    capture_output=True, text=True).stdout)

    expect(app.cmd("edit_source", name="Gmail", new_name="Email", instructions="Replies from customers")["saved"], "rename failed")
    expect(app.cmd("edit_source", name="Slack", enabled=False)["saved"], "disable failed")
    s = app.wait_state(lambda s: [(x["name"], x["enabled"]) for x in s["sources"]] == [("Slack", False), ("Email", True)],
                       "edits did not show up")
    expect(s["sources"][1]["instructions"] == "Replies from customers", f"instructions: {s['sources']}")
    expect([(x["name"], x["enabled"]) for x in cli_sources()] == [("Slack", False), ("Email", True)], "edits did not reach the database")

    # Agents find sources by name, so a clash is refused and nothing changes.
    expect(not app.cmd("edit_source", name="Email", new_name="slack")["saved"], "duplicate name was accepted")
    expect([x["name"] for x in app.state()["sources"]] == ["Slack", "Email"], "a refused rename changed the source")
    app.snapshot("settings", "sources-edited")

    app.cmd("delete_source", name="Slack")
    app.wait_state(lambda s: [x["name"] for x in s["sources"]] == ["Email"], "delete did not show up")
    m = Mcp(app.env, "Checker")
    text = m.call("get_instructions", agent="Checker")
    m.close()
    listed = [x["name"] for x in json.loads(text.split("\nsources:\n")[1].split("\nopen_tasks")[0])]
    expect(listed == ["Email"] and "- Email (Email): Replies from customers" in text, f"agents still see the old sources: {listed}")
    app.snapshot("settings", "sources-deleted")


@spec
def learning_from_feedback(app: App):
    app.cmd("set_pref", key="pinned", value=True)  # stray real clicks would otherwise close it
    app.cmd("open_drawer")
    # Completing an agent's task is positive feedback; your own tasks don't count.
    app.cmd("toggle_done", title="Prep notes for Thursday")
    app.cmd("toggle_done", title="Update the estimate on CDI-88")
    s = app.wait_state(lambda s: len(s["done"]) == 2, "tasks not marked done")
    expect([(f["kind"], f["title"]) for f in s["feedback"]] == [("good", "Prep notes for Thursday customer call")],
           f"feedback after completing: {s['feedback']}")

    # Only agents' tasks can be rejected.
    s = app.cmd("begin_reject", title="Update the estimate")
    expect(s["rejecting"] is None, f"the user's own task opened the reject panel: {s['rejecting']}")

    # The reject panel, filled in; Return rejects.
    s = app.cmd("reject", title="Review PR #412", reason="Bot PRs don't need my review", confirm=False)
    expect(s["rejecting"] == "Review PR #412: connections retry logic", f"reject panel: {s['rejecting']}")
    app.settle()
    app.snapshot("drawer", "reject-panel")
    s = app.cmd("key", key="return")
    expect(s["handled"], "return should confirm the reject")
    s = app.wait_state(lambda s: "Review PR #412: connections retry logic" not in titles(s["open"]), "reject did not remove the task")
    expect(s["rejecting"] is None and s["toast"] and s["toast"].startswith("Rejected"), f"after reject: {s['rejecting']} {s['toast']}")
    rejected = [f for f in s["feedback"] if f["kind"] == "rejected"]
    expect(rejected and rejected[0]["reason"] == "Bot PRs don't need my review" and rejected[0]["addedBy"] == "Claude Code",
           f"rejected feedback: {s['feedback']}")
    app.snapshot("drawer", "rejected")
    p = s["runPrompt"]
    expect('REJECTED: "Review PR #412: connections retry logic"' in p and "my reason: Bot PRs don't need my review" in p, f"run prompt: {p}")
    expect('COMPLETED: "Prep notes for Thursday customer call"' in p, f"run prompt: {p}")

    # Undo brings the task back and drops its feedback.
    app.cmd("undo")
    s = app.wait_state(lambda s: "Review PR #412: connections retry logic" in titles(s["open"]), "undo did not restore the task")
    expect([f["kind"] for f in s["feedback"]] == ["good"], f"feedback after undo: {s['feedback']}")
    app.cmd("redo")
    app.wait_state(lambda s: len(s["feedback"]) == 2, "redo did not bring the rejection back")

    # ⇧⌫ opens the panel on the highlighted agent task; Esc cancels.
    s = to_list(app)
    agent = next(t["title"] for t in s["open"] if t["addedBy"] != "You")
    while app.state()["highlighted"] != agent:
        s = app.cmd("key", key="down")
    s = app.cmd("key", key="delete", modifiers=["shift"])
    expect(s["handled"] and s["rejecting"] == agent, f"shift-delete: handled={s['handled']} rejecting={s['rejecting']}")
    s = app.cmd("key", key="escape")
    expect(s["handled"] and s["rejecting"] is None and agent in titles(s["open"]), f"esc should cancel: {s['rejecting']}")

    # Your own note, then the Learning pane with feedback waiting.
    app.cmd("add_learning", text="Never add tasks from #random")
    app.cmd("settings", tab="learning")
    app.settle()
    app.snapshot("settings", "learning-pending")

    # The next run folds the feedback into notes, which clears it.
    m = Mcp(app.env, "Claude Code")
    prompt = m.call("get_instructions", agent="Claude Code")
    expect("- Never add tasks from #random (written by me)" in prompt, f"user note missing from prompt: {prompt}")
    ids = [int(line.split()[0][1:]) for line in prompt.splitlines() if line.strip().startswith("#")]
    expect(len(ids) == 2, f"feedback ids in prompt: {ids}")
    m.call("save_learnings", notes=["Never add tasks from #random", "Skip review requests on bot PRs",
                                    "Prep for external customer calls is wanted"], processed_feedback_ids=ids)
    m.close()
    s = app.wait_state(lambda s: s["feedback"] == [] and len(s["learnings"]) == 3, "notes not saved or feedback not cleared", timeout=5)
    expect([l["author"] for l in s["learnings"]] == ["You", "Claude Code", "Claude Code"], f"note authors: {s['learnings']}")
    app.settle()
    app.snapshot("settings", "learning-notes")
    app.cmd("close_settings")


@spec
def schedule_prompt_is_hourly(app: App):
    p = app.state()["schedulePrompt"]
    expect("every hour, on the hour, Monday to Friday from 09:00 to 17:00" in p, f"default schedule: {p}")
    expect("get_instructions" in p and "never reuse" in p and "own name" in p, "schedule prompt must fetch instructions every run")
    expect("{{" not in p, f"unfilled placeholder: {p}")
    s = app.cmd("set_schedule", weekdaysOnly=False, startHour=8, endHour=18, intervalMinutes=60)
    expect("every hour, on the hour, every day from 08:00 to 18:00" in s["schedulePrompt"], s["schedulePrompt"])
    app.cmd("settings", tab="schedule")
    app.snapshot("settings", "schedule")


@spec
def edit_labels_and_escape_cancels(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    app.cmd("select", title="Prep notes")
    s = app.cmd("key", key="e")
    s = app.wait_state(lambda s: s["editing"], "e should enter edit mode")
    app.snapshot("drawer", "editor")
    s = app.cmd("key", key="escape")
    expect(not s["editing"], "Esc should cancel the edit")
    expect(s["selected"] == "Prep notes for Thursday customer call", f"Esc in the editor should stay on the task: {s['selected']}")
    s = app.cmd("key", key="escape")
    expect(s["selected"] is None, "a second Esc goes back to the list")


@spec
def priority_without_edit_mode(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    app.cmd("select", title="Prep notes")
    app.snapshot("drawer", "priority-chip")
    s = app.cmd("key", key="1")
    expect(s["handled"], "1 should be handled in the detail")
    app.wait_state(lambda s: next(t for t in s["open"] if t["title"].startswith("Prep notes"))["priority"] == 1, "1 should set P1")
    app.cmd("back")
    app.cmd("set_priority", title="Submit September", priority=1)
    s = app.wait_state(lambda s: next(t for t in s["open"] if t["title"].startswith("Submit"))["priority"] == 1, "set_priority")
    expect(titles(s["open"]).index("Submit September expenses") < titles(s["open"]).index("Answer the triage question on CONNECT-210"),
           f"a P1 task sorts above the P2 ones: {titles(s['open'])}")
    app.snapshot("drawer", "priority-groups")
    app.cmd("set_order_by_priority", on=False)
    s = app.wait_state(lambda s: not s["orderByPriority"], "setting should turn off")
    expect(titles(s["open"])[-1] == "Submit September expenses", f"without priority order the rank order returns: {titles(s['open'])}")


@spec
def description_and_link_names(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    app.cmd("update", title="Prep notes", summary="Agenda in https://example.com/agenda and [last call notes](https://example.com/notes).")
    app.wait_state(lambda s: next(t for t in s["open"] if t["title"].startswith("Prep notes"))["summary"].startswith("Agenda in"),
                   "description should be saved")
    app.cmd("select", title="Prep notes")
    app.snapshot("drawer", "description-links")
    s = app.cmd("select", title="Review PR #412")
    t = next(t for t in s["open"] if t["title"].startswith("Review PR #412"))
    expect(t["sourceLink"] == "PR #412", f"the agent's link name should label the link: {t}")
    t = next(t for t in s["open"] if t["title"].startswith("Answer the triage"))
    expect(t["sourceLink"] == "Open in Linear", f"without a name the link falls back to the source: {t}")
    app.snapshot("drawer", "link-name")


@spec
def search_filters_the_list(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    s = app.cmd("key", key="f", modifiers=["command"])
    expect(s["searching"], "⌘F should open search")
    s = app.cmd("search", query="slack")
    expect(s["shown"] == ["Reply to Sam about the Q4 export format"], f"search by source: {s['shown']}")
    s = app.cmd("search", query="backoff")
    expect(s["shown"] == ["Review PR #412: connections retry logic"], f"search by description: {s['shown']}")
    s = app.cmd("search", query="TRIAGE")
    expect(s["shown"] == ["Answer the triage question on CONNECT-210"], f"search by title, any case: {s['shown']}")
    app.snapshot("drawer", "results")
    s = app.cmd("search", query="nothing like this")
    expect(s["shown"] == [], f"no matches: {s['shown']}")
    app.snapshot("drawer", "no-matches")
    s = app.cmd("key", key="escape")
    expect(not s["searching"] and s["query"] == "" and len(s["shown"]) == 6, f"Esc closes search: {s['searching']} {s['shown']}")


@spec
def agents_cannot_complete_when_protected(app: App):
    s = app.cmd("set_protect_tasks", on=True)
    expect(s["protectTasks"], "protection should turn on")
    expect("turned off agents completing or deleting" in s["runPrompt"], "the run prompt should tell agents")
    m = Mcp(app.env, "E2E Agent")
    m.call("start_run", agent="E2E Agent")
    tasks = json.loads(m.send("tools/call", {"name": "list_tasks", "arguments": {}})["result"]["content"][0]["text"])
    task_id = next(t["id"] for t in tasks if t["title"].startswith("Submit September"))
    for tool in ("complete_task", "delete_task"):
        r = m.send("tools/call", {"name": tool, "arguments": {"id": task_id, "reason": "resolved"}})["result"]
        expect(r.get("isError"), f"{tool} should be refused: {r}")
    m.call("finish_run", summary="nothing")
    m.close()
    s = app.wait_state(lambda s: "Submit September expenses" in titles(s["open"]), "task should still be open")
    app.cmd("set_protect_tasks", on=False)
    app.cmd("settings", tab="general")
    app.snapshot("settings", "general")


@spec
def hover_gives_the_drawer_the_keyboard(app: App):
    app.cmd("set_pref", key="pinned", value=True)
    app.cmd("open_drawer")
    app.cmd("click_outside")
    s = app.cmd("hover", inside=True)
    expect(s["drawerKey"], "hovering should make the drawer key")


@spec
def done_tick_animation(app: App):
    app.cmd("open_drawer")
    app.cmd("toggle_done", title="Prep notes")
    app.wait_state(lambda s: "Prep notes for Thursday customer call" in titles(s["done"]), "task not marked done")
    app.snapshot("drawer", "after-tick")


# ---------------------------------------------------------------------------

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if "--vm" in flags:  # run the whole thing inside a macOS VM, off your screen
        rest = [a for a in sys.argv[1:] if a != "--vm"]
        os.execv(str(ROOT / "scripts" / "e2e-vm.sh"), [str(ROOT / "scripts" / "e2e-vm.sh"), *rest])
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
