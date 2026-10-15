#!/usr/bin/env python3
"""Drive `todo mcp` over stdio like a real client: one request at a time.

Usage: scripts/mcp_smoke.py path/to/todo [--db PATH]
"""
import json, subprocess, sys

todo = sys.argv[1]
extra = sys.argv[2:]
p = subprocess.Popen([todo, *extra, "mcp", "--agent", "Smoke"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
nid = 0

def send(method, params=None, notify=False):
    global nid
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        nid += 1
        msg["id"] = nid
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    if notify:
        return None
    while True:
        m = json.loads(p.stdout.readline())
        if m.get("id") == nid:
            return m

def call(tool, /, **args):
    r = send("tools/call", {"name": tool, "arguments": args})["result"]
    text = r["content"][0]["text"]
    status = "ERR" if r.get("isError") else "ok "
    print(f"{status} {tool}: {text[:150].replace(chr(10), ' ')}")
    return text

send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}})
send("notifications/initialized", notify=True)
tools = [t["name"] for t in send("tools/list")["result"]["tools"]]
print("tools:", ", ".join(tools))
call("get_instructions", agent="Hermes")
call("start_run", agent="Hermes")
a = json.loads(call("upsert_task", source_ref="gmail:1", title="Submit expenses", priority=3, source="Gmail", summary="Closes Oct 20."))["task"]["id"]
call("upsert_task", source_ref="gmail:1", title="Submit September expenses")
b = json.loads(call("upsert_task", source_ref="slack:9", title="Answer CONNECT-210 triage", priority=1, source="Linear"))["task"]["id"]
call("reorder_tasks", ordered_ids=[b, a], rationales={b: "Unblocks triage", a: "Due in a week"})
call("save_source", name="Slack", kind="Messages", instructions="DMs and mentions that ask me for something")
call("save_source", name="slack", kind="Messages", instructions="DMs, mentions and #team threads")
call("save_source", name="Gmail", kind="Email", instructions="Email from people that needs a reply")
call("remove_source", name="Gmail")
sources = json.loads(call("list_sources"))
assert [s["name"] for s in sources] == ["slack"], sources
call("get_changes_since", since="0")
call("finish_run", summary="2 new, reordered")

# The user completes one task and rejects the other; the next run folds that into notes.
cli = [todo, *extra]
subprocess.run([*cli, "done", a], check=True, capture_output=True)
subprocess.run([*cli, "reject", b, "--reason", "Triage rota isn't mine"], check=True, capture_output=True)
prompt = call("get_instructions", agent="Hermes")
assert "REJECTED: \"Answer CONNECT-210 triage\"" in prompt and "my reason: Triage rota isn't mine" in prompt, prompt
assert "COMPLETED: \"Submit September expenses\"" in prompt, prompt
ids = [int(x.split()[0][1:]) for x in prompt.split("\n") if x.strip().startswith("#")]
assert len(ids) == 2, ids
saved = json.loads(call("save_learnings", notes=["Expense deadlines from Gmail matter", "Skip triage-rota pings"], processed_feedback_ids=ids))
assert saved == {"notes": 2, "feedback_remaining": 0}, saved
prompt = call("get_instructions", agent="Hermes")
assert "- Skip triage-rota pings" in prompt and "No new feedback" in prompt, prompt
p.stdin.close(); p.wait(timeout=5)
