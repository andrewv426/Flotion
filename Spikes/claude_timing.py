#!/usr/bin/env python3
"""Spike (build step 1a): time the locked-down `claude -p` invocation Flotion will use.

Measures, per configuration:
  spawn -> init event, spawn/send -> first text token, -> final result.
Also prints what the init event says about tools, so the lockdown can be checked.

Usage: python3 Spikes/claude_timing.py [claude-binary]
Each run sends one tiny prompt on the signed-in account.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

CLAUDE = sys.argv[1] if len(sys.argv) > 1 else "/opt/homebrew/bin/claude"
PROMPT = "Rewrite this sentence to be shorter: The meeting that we had yesterday was very long."
SYSTEM = "You are the writing assistant inside a notes app. Reply with the rewritten text only."

BASE = [
    CLAUDE, "-p",
    "--output-format", "stream-json", "--verbose", "--include-partial-messages",
    "--tools", "",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--disable-slash-commands",
    "--no-session-persistence",
    "--system-prompt", SYSTEM,
]


def child_env():
    # Simulate launch from the app, not from inside another Claude Code session.
    return {k: v for k, v in os.environ.items()
            if not k.startswith(("CLAUDE", "ANTHROPIC"))}


def read_events(proc, t0, marks, label):
    text = []
    for raw in proc.stdout:
        now = time.perf_counter()
        try:
            ev = json.loads(raw)
        except json.JSONDecodeError:
            continue
        kind = ev.get("type")
        if kind == "system" and ev.get("subtype") == "init":
            marks.setdefault("init", now - t0)
            marks["tools"] = ev.get("tools")
            marks["mcp"] = ev.get("mcp_servers")
            marks["model"] = ev.get("model")
        elif kind == "stream_event":
            delta = ev.get("event", {}).get("delta", {})
            if delta.get("type") == "text_delta":
                marks.setdefault("first_token", now - t0)
                text.append(delta.get("text", ""))
        elif kind == "result":
            marks["result"] = now - t0
            marks["is_error"] = ev.get("is_error")
            marks["error_text"] = ev.get("result") if ev.get("is_error") else None
            break
    marks["reply"] = "".join(text).strip()[:80]
    return marks


def cold(label, extra):
    cwd = tempfile.mkdtemp(prefix="flotion-spike-")
    t0 = time.perf_counter()
    proc = subprocess.Popen(BASE + extra + [PROMPT], cwd=cwd, env=child_env(),
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    marks = read_events(proc, t0, {}, label)
    proc.wait(timeout=30)
    report(label, marks, proc)


def warm(label, extra, settle=4.0):
    """Pre-spawn with streaming input, let it settle, then time from send."""
    cwd = tempfile.mkdtemp(prefix="flotion-spike-")
    proc = subprocess.Popen(BASE + extra + ["--input-format", "stream-json"], cwd=cwd,
                            env=child_env(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    time.sleep(settle)
    msg = {"type": "user", "message": {"role": "user", "content": PROMPT}}
    t0 = time.perf_counter()
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    marks = read_events(proc, t0, {}, label)
    proc.stdin.close()
    try:
        proc.wait(timeout=30)
    except subprocess.TimeoutExpired:
        proc.kill()
    report(label, marks, proc)


def ms(v):
    return f"{v * 1000:7.0f} ms" if isinstance(v, float) else "      n/a"


def report(label, m, proc):
    print(f"\n[{label}]")
    print(f"  model        {m.get('model')}")
    print(f"  init         {ms(m.get('init'))}")
    print(f"  first token  {ms(m.get('first_token'))}")
    print(f"  result       {ms(m.get('result'))}")
    print(f"  tools        {m.get('tools')}")
    print(f"  mcp servers  {m.get('mcp')}")
    print(f"  reply        {m.get('reply')!r}")
    if m.get("is_error") or "result" not in m:
        err = (proc.stderr.read() or "").strip()[:400]
        print(f"  ERROR        {m.get('error_text')!r} stderr={err!r}")


if __name__ == "__main__":
    cold("cold, default model", [])
    cold("cold, haiku, low effort", ["--model", "haiku", "--effort", "low"])
    warm("warm spare, haiku, low effort", ["--model", "haiku", "--effort", "low"])
    warm("warm spare, default model, low effort", ["--effort", "low"])
