#!/usr/bin/env python3
"""
Test thread/compact/start behavior on a real Codex app-server.
Measures token usage before and after compact to determine retention ratio.
"""

import json
import subprocess
import sys
import tempfile
import os
import time
import threading
import queue

WORKSPACE = tempfile.mkdtemp(prefix="compact-test-")

# Bootstrap a minimal git repo
os.makedirs(WORKSPACE, exist_ok=True)
subprocess.run(["git", "init", "-b", "main"], cwd=WORKSPACE, capture_output=True)
subprocess.run(["git", "config", "user.name", "test"], cwd=WORKSPACE, capture_output=True)
subprocess.run(["git", "config", "user.email", "test@test.com"], cwd=WORKSPACE, capture_output=True)

# Create several files to give the model something to read
for i in range(5):
    with open(os.path.join(WORKSPACE, f"file_{i}.txt"), "w") as f:
        f.write(f"# File {i}\n" + "".join(f"Content line {j}\n" for j in range(20)))

with open(os.path.join(WORKSPACE, "README.md"), "w") as f:
    f.write("# Test Project\nThis is a test project for compact verification.\n" * 10)

subprocess.run(["git", "add", "."], cwd=WORKSPACE, capture_output=True)
subprocess.run(["git", "commit", "-m", "init"], cwd=WORKSPACE, capture_output=True)

print(f"Workspace: {WORKSPACE}")

# Start codex app-server
proc = subprocess.Popen(
    ["codex", "--model", "gpt-5.4", "--config", "model_reasoning_effort=low", "app-server"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    cwd=WORKSPACE,
    text=True,
    bufsize=1,
)

# Background reader thread
msg_queue = queue.Queue()
token_events = []

all_events = []  # capture everything for analysis

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            data = json.loads(line)
            msg_queue.put(data)
            all_events.append(data)
            # Track token usage events
            method = data.get("method", "")
            if method == "thread/tokenUsage/updated":
                token_events.append(data)
        except json.JSONDecodeError:
            pass  # ignore non-JSON output

t = threading.Thread(target=reader, daemon=True)
t.start()


def send(msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


def wait_for_id(target_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg = msg_queue.get(timeout=2)
            if msg.get("id") == target_id:
                return msg
        except queue.Empty:
            continue
    raise TimeoutError(f"Timeout waiting for id={target_id}")


def wait_for_method(target_method, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg = msg_queue.get(timeout=2)
            if msg.get("method") == target_method:
                return msg
        except queue.Empty:
            continue
    raise TimeoutError(f"Timeout waiting for method={target_method}")


def drain(timeout=3):
    """Drain remaining messages after turn/completed."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg_queue.get(timeout=1)
        except queue.Empty:
            break


def get_last_token_usage():
    if not token_events:
        return None
    last = token_events[-1]
    total = last.get("params", {}).get("tokenUsage", {}).get("total", {})
    return {
        "input": total.get("inputTokens", total.get("input_tokens", 0)),
        "output": total.get("outputTokens", total.get("output_tokens", 0)),
        "total": total.get("totalTokens", total.get("total_tokens", 0)),
    }


def get_last_input_delta():
    if not token_events:
        return None
    last = token_events[-1]
    delta = last.get("params", {}).get("tokenUsage", {}).get("last", {})
    return delta.get("inputTokens", delta.get("input_tokens", 0))


try:
    # Step 1: Initialize
    print("=== Step 1: Initialize ===")
    send({
        "method": "initialize",
        "id": 1,
        "params": {
            "capabilities": {"experimentalApi": True},
            "clientInfo": {"name": "compact-test", "version": "0.1.0"},
        },
    })
    resp = wait_for_id(1, timeout=15)
    print(f"  Init OK")
    send({"method": "initialized", "params": {}})

    # Step 2: Start thread
    print("\n=== Step 2: Start thread ===")
    send({
        "method": "thread/start",
        "id": 2,
        "params": {
            "approvalPolicy": "never",
            "sandbox": "danger-full-access",
            "cwd": WORKSPACE,
        },
    })
    resp = wait_for_id(2, timeout=15)
    thread_id = resp["result"]["thread"]["id"]
    print(f"  Thread ID: {thread_id}")

    # Step 3: Turn 1 — build up context with several tool calls
    print("\n=== Step 3: Turn 1 (build context) ===")
    prompt = (
        "Do the following steps one by one:\n"
        "1. Run: cat file_0.txt\n"
        "2. Run: cat file_1.txt\n"
        "3. Run: cat file_2.txt\n"
        "4. Run: cat file_3.txt\n"
        "5. Run: cat file_4.txt\n"
        "6. Run: cat README.md\n"
        "7. Run: wc -l *.txt\n"
        "8. Run: ls -la\n"
        "9. Run: cat file_0.txt file_1.txt file_2.txt\n"
        "10. Run: cat file_3.txt file_4.txt README.md\n"
        "11. Summarize everything you found.\n"
        "Execute each command separately."
    )
    send({
        "method": "turn/start",
        "id": 3,
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": prompt}],
            "cwd": WORKSPACE,
            "approvalPolicy": "never",
            "sandboxPolicy": {"type": "dangerFullAccess", "networkAccess": False},
        },
    })
    wait_for_id(3, timeout=15)
    print("  Turn 1 started, waiting for completion...")

    # Auto-approve any tool calls while waiting for turn/completed
    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            msg = msg_queue.get(timeout=2)
        except queue.Empty:
            continue

        method = msg.get("method", "")
        msg_id = msg.get("id")

        if method == "turn/completed":
            print("  Turn 1 completed")
            break
        elif method == "turn/failed":
            print(f"  Turn 1 FAILED: {msg}")
            sys.exit(1)
        elif method in (
            "item/commandExecution/requestApproval",
            "execCommandApproval",
            "applyPatchApproval",
            "item/fileChange/requestApproval",
        ):
            send({"id": msg_id, "result": {"decision": "acceptForSession"}})
        elif method == "item/tool/requestUserInput":
            # Auto-answer
            questions = msg.get("params", {}).get("questions", [])
            answers = {}
            for q in questions:
                qid = q.get("id", "")
                options = q.get("options", [])
                approve = next((o["label"] for o in options if "approve" in o.get("label", "").lower()), None)
                if approve:
                    answers[qid] = {"answers": [approve]}
                else:
                    answers[qid] = {"answers": ["Non-interactive session"]}
            send({"id": msg_id, "result": {"answers": answers}})

    drain(3)

    usage_before = get_last_token_usage()
    print(f"\n  Token usage after Turn 1:")
    print(f"    Cumulative input tokens:  {usage_before['input']:,}")
    print(f"    Cumulative output tokens: {usage_before['output']:,}")
    print(f"    Last input delta:         {get_last_input_delta():,}")

    # Record how many token events we had in turn 1
    turn1_event_count = len(token_events)

    # Step 4: Compact
    print("\n=== Step 4: Compact thread ===")
    send({
        "method": "thread/compact/start",
        "id": 5,
        "params": {"threadId": thread_id},
    })

    try:
        compact_resp = wait_for_id(5, timeout=60)
        if "error" in compact_resp:
            print(f"  Compact ERROR: {compact_resp['error']}")
        else:
            print(f"  Compact OK: {json.dumps(compact_resp.get('result', {}))}")
    except TimeoutError:
        print("  Compact TIMEOUT (API may not be supported)")

    drain(3)

    # Step 5: Turn 2 — measure post-compact context with real tool calls
    print("\n=== Step 5: Turn 2 (post-compact) ===")
    turn2_prompt = (
        "Do the following steps:\n"
        "1. Run: ls -la\n"
        "2. Run: cat README.md\n"
        "3. Run: wc -l *.txt\n"
        "4. Summarize what you found.\n"
        "Execute each command separately."
    )
    send({
        "method": "turn/start",
        "id": 6,
        "params": {
            "threadId": thread_id,
            "input": [{"type": "text", "text": turn2_prompt}],
            "cwd": WORKSPACE,
            "approvalPolicy": "never",
            "sandboxPolicy": {"type": "dangerFullAccess", "networkAccess": False},
        },
    })
    wait_for_id(6, timeout=15)
    print("  Turn 2 started, waiting for completion...")

    deadline = time.time() + 120
    while time.time() < deadline:
        try:
            msg = msg_queue.get(timeout=2)
        except queue.Empty:
            continue

        method = msg.get("method", "")
        msg_id = msg.get("id")

        if method == "turn/completed":
            print("  Turn 2 completed")
            break
        elif method == "turn/failed":
            print(f"  Turn 2 FAILED: {msg}")
            break
        elif method in (
            "item/commandExecution/requestApproval",
            "execCommandApproval",
            "applyPatchApproval",
            "item/fileChange/requestApproval",
        ):
            send({"id": msg_id, "result": {"decision": "acceptForSession"}})
        elif method == "item/tool/requestUserInput":
            questions = msg.get("params", {}).get("questions", [])
            answers = {}
            for q in questions:
                qid = q.get("id", "")
                options = q.get("options", [])
                approve = next((o["label"] for o in options if "approve" in o.get("label", "").lower()), None)
                if approve:
                    answers[qid] = {"answers": [approve]}
                else:
                    answers[qid] = {"answers": ["Non-interactive session"]}
            send({"id": msg_id, "result": {"answers": answers}})

    drain(3)

    usage_after = get_last_token_usage()
    print(f"\n  Token usage after Turn 2:")
    print(f"    Cumulative input tokens:  {usage_after['input']:,}")
    print(f"    Cumulative output tokens: {usage_after['output']:,}")

    # Analysis
    print("\n" + "=" * 60)
    print("=== COMPACT ANALYSIS ===")
    print("=" * 60)

    turn1_input = usage_before["input"]
    total_input = usage_after["input"]
    turn2_input = total_input - turn1_input

    # Get the first token event from turn 2 (first API call after compact)
    turn2_events = token_events[turn1_event_count:]
    if turn2_events:
        first_t2_delta = turn2_events[0].get("params", {}).get("tokenUsage", {}).get("last", {})
        first_t2_input = first_t2_delta.get("inputTokens", first_t2_delta.get("input_tokens", 0))
        last_t1_delta = token_events[turn1_event_count - 1].get("params", {}).get("tokenUsage", {}).get("last", {})
        last_t1_input = last_t1_delta.get("inputTokens", last_t1_delta.get("input_tokens", 0))

        print(f"\nTurn 1 last API call input:  {last_t1_input:,} tokens")
        print(f"Turn 2 first API call input: {first_t2_input:,} tokens")

        if last_t1_input > 0:
            ratio = first_t2_input / last_t1_input
            reduction = 1 - ratio
            print(f"\nCompact retention ratio:    {ratio:.1%}")
            print(f"Compact reduction:          {reduction:.1%}")
            print(f"\nApplying to ENT-132 model (12M baseline):")
            # Using the model from our analysis with this measured r
            # Rough estimate: savings ≈ 1 - (ratio * 0.5 + 0.5) for multi-turn
            # More precise: use the formula
            estimated_savings = max(0, 1 - (0.27 + 0.73 * ratio))
            estimated_after = 12_000_000 * (1 - estimated_savings)
            print(f"  Estimated optimized total: ~{estimated_after/1_000_000:.1f}M tokens")
            print(f"  Estimated savings:         ~{estimated_savings:.0%}")
    else:
        print("No token events captured for Turn 2")

    print(f"\nAll token usage events ({len(token_events)} total):")
    for i, evt in enumerate(token_events):
        total = evt.get("params", {}).get("tokenUsage", {}).get("total", {})
        last = evt.get("params", {}).get("tokenUsage", {}).get("last", {})
        turn = evt.get("params", {}).get("turnId", "?")
        inp_t = total.get("inputTokens", total.get("input_tokens", "?"))
        inp_l = last.get("inputTokens", last.get("input_tokens", "?"))
        cached_t = total.get("cachedInputTokens", total.get("cached_input_tokens", 0))
        cached_l = last.get("cachedInputTokens", last.get("cached_input_tokens", 0))
        ctx_win = evt.get("params", {}).get("tokenUsage", {}).get("modelContextWindow", "?")
        marker = " <-- Turn 1 end" if i == turn1_event_count - 1 else ""
        marker = " <-- Turn 2 start" if i == turn1_event_count else marker
        print(f"  [{i:3d}] turn={turn}  total_in={inp_t:>8}  last_in={inp_l:>8}  total_cached={cached_t:>8}  last_cached={cached_l:>8}  ctx_win={ctx_win}{marker}")

    # Dump all event methods for debugging
    print(f"\nAll event methods ({len(all_events)} total):")
    for i, evt in enumerate(all_events):
        m = evt.get("method", f"response(id={evt.get('id', '?')})")
        # For token usage, show compact summary
        if m == "thread/tokenUsage/updated":
            total = evt.get("params", {}).get("tokenUsage", {}).get("total", {})
            inp = total.get("inputTokens", total.get("input_tokens", "?"))
            print(f"  [{i:3d}] {m}  input={inp}")
        else:
            print(f"  [{i:3d}] {m}")

finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    import shutil
    shutil.rmtree(WORKSPACE, ignore_errors=True)
