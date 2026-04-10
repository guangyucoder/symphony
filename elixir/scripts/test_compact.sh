#!/bin/bash
# Test thread/compact/start behavior on a real Codex app-server.
# Measures token usage before and after compact to determine retention ratio.

set -euo pipefail

WORKSPACE=$(mktemp -d)
TRACE_DIR=$(mktemp -d)
LOG="$TRACE_DIR/compact_test.log"

echo "Workspace: $WORKSPACE"
echo "Log: $LOG"

# Create a minimal workspace
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"
git init -b main > /dev/null 2>&1
git config user.name "test" && git config user.email "test@test.com"
echo "# test" > README.md
git add . && git commit -m "init" > /dev/null 2>&1

# Start codex app-server
FIFO_IN="$TRACE_DIR/codex_in"
FIFO_OUT="$TRACE_DIR/codex_out"
mkfifo "$FIFO_IN" "$FIFO_OUT"

codex --model gpt-5.4 app-server < "$FIFO_IN" > "$FIFO_OUT" 2>"$TRACE_DIR/stderr.log" &
CODEX_PID=$!

# Helper to send JSON-RPC and read response
send_and_read() {
  local msg="$1"
  local expect_id="$2"
  echo "$msg" > "$FIFO_IN"

  while IFS= read -r line; do
    echo "  << $line" >> "$LOG"
    if echo "$line" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('id')==$expect_id or d.get('method','').startswith('thread/tokenUsage') else 1)" 2>/dev/null; then
      echo "$line"
      return 0
    fi
  done < "$FIFO_OUT"
}

# Helper to send and not wait for specific response (fire-and-forget or notification)
send_only() {
  echo "$1" > "$FIFO_IN"
}

# Helper to read lines until we get what we want
read_until_method() {
  local method="$1"
  local timeout="${2:-30}"
  local deadline=$((SECONDS + timeout))

  while [ $SECONDS -lt $deadline ]; do
    if IFS= read -t 5 -r line < "$FIFO_OUT"; then
      echo "  << $line" >> "$LOG"
      local m=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('method',''))" 2>/dev/null || true)
      if [ "$m" = "$method" ]; then
        echo "$line"
        return 0
      fi
      # Capture token usage updates
      if [ "$m" = "thread/tokenUsage/updated" ]; then
        echo "TOKEN_UPDATE: $line" >> "$LOG"
      fi
    fi
  done
  echo "TIMEOUT waiting for $method" >&2
  return 1
}

read_until_id() {
  local target_id="$1"
  local timeout="${2:-30}"
  local deadline=$((SECONDS + timeout))

  while [ $SECONDS -lt $deadline ]; do
    if IFS= read -t 5 -r line < "$FIFO_OUT"; then
      echo "  << $line" >> "$LOG"
      local rid=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
      local m=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('method',''))" 2>/dev/null || true)
      if [ "$rid" = "$target_id" ]; then
        echo "$line"
        return 0
      fi
      # Capture token usage
      if [ "$m" = "thread/tokenUsage/updated" ]; then
        echo "TOKEN_UPDATE: $line" >> "$LOG"
      fi
    fi
  done
  echo "TIMEOUT waiting for id=$target_id" >&2
  return 1
}

# Drain all pending output and capture token usage
drain_and_get_usage() {
  local last_usage=""
  while IFS= read -t 3 -r line < "$FIFO_OUT" 2>/dev/null; do
    echo "  << $line" >> "$LOG"
    local m=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('method',''))" 2>/dev/null || true)
    if [ "$m" = "thread/tokenUsage/updated" ]; then
      last_usage="$line"
      echo "TOKEN_UPDATE: $line" >> "$LOG"
    fi
    if [ "$m" = "turn/completed" ]; then
      echo "TURN_COMPLETED" >> "$LOG"
      break
    fi
  done
  # Keep draining token updates
  while IFS= read -t 2 -r line < "$FIFO_OUT" 2>/dev/null; do
    echo "  << $line" >> "$LOG"
    local m=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('method',''))" 2>/dev/null || true)
    if [ "$m" = "thread/tokenUsage/updated" ]; then
      last_usage="$line"
    fi
  done
  echo "$last_usage"
}

extract_input_tokens() {
  echo "$1" | python3 -c "
import sys, json
d = json.load(sys.stdin)
usage = d.get('params', {}).get('tokenUsage', {}).get('total', {})
print(usage.get('inputTokens', usage.get('input_tokens', 0)))
"
}

cleanup() {
  kill "$CODEX_PID" 2>/dev/null || true
  wait "$CODEX_PID" 2>/dev/null || true
  rm -rf "$WORKSPACE" "$FIFO_IN" "$FIFO_OUT"
  echo ""
  echo "Full log: $LOG"
  echo "Stderr: $TRACE_DIR/stderr.log"
}
trap cleanup EXIT

echo "=== Step 1: Initialize ==="
echo '{"method":"initialize","id":1,"params":{"capabilities":{"experimentalApi":true},"clientInfo":{"name":"compact-test","version":"0.1.0"}}}' > "$FIFO_IN"
INIT_RESP=$(read_until_id 1 15)
echo "Init response: $INIT_RESP"

echo '{"method":"initialized","params":{}}' > "$FIFO_IN"

echo ""
echo "=== Step 2: Start thread ==="
echo "{\"method\":\"thread/start\",\"id\":2,\"params\":{\"approvalPolicy\":\"never\",\"sandbox\":\"danger-full-access\",\"cwd\":\"$WORKSPACE\"}}" > "$FIFO_IN"
THREAD_RESP=$(read_until_id 2 15)
THREAD_ID=$(echo "$THREAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['thread']['id'])")
echo "Thread ID: $THREAD_ID"

echo ""
echo "=== Step 3: Turn 1 — build up context ==="
# Ask the model to do several file reads to build up context
TURN1_PROMPT="Read the following files and summarize each: README.md. Then list all files in the current directory. Then read README.md again. Write a short summary of what you found."
echo "{\"method\":\"turn/start\",\"id\":3,\"params\":{\"threadId\":\"$THREAD_ID\",\"input\":[{\"type\":\"text\",\"text\":\"$TURN1_PROMPT\"}],\"cwd\":\"$WORKSPACE\",\"approvalPolicy\":\"never\",\"sandboxPolicy\":{\"type\":\"dangerFullAccess\",\"networkAccess\":false}}}" > "$FIFO_IN"

TURN1_START=$(read_until_id 3 15)
echo "Turn 1 started"

# Wait for turn/completed and collect token usage
echo "Waiting for turn 1 to complete..."
LAST_USAGE_T1=$(drain_and_get_usage)

if [ -n "$LAST_USAGE_T1" ]; then
  INPUT_TOKENS_BEFORE=$(extract_input_tokens "$LAST_USAGE_T1")
  echo "Input tokens BEFORE compact: $INPUT_TOKENS_BEFORE"
else
  echo "WARNING: No token usage captured for turn 1"
  INPUT_TOKENS_BEFORE=0
fi

echo ""
echo "=== Step 4: Compact thread ==="
echo "{\"method\":\"thread/compact/start\",\"id\":5,\"params\":{\"threadId\":\"$THREAD_ID\"}}" > "$FIFO_IN"
COMPACT_RESP=$(read_until_id 5 30)
echo "Compact response: $COMPACT_RESP"

echo ""
echo "=== Step 5: Turn 2 — measure post-compact context ==="
TURN2_PROMPT="What files exist in the current directory?"
echo "{\"method\":\"turn/start\",\"id\":6,\"params\":{\"threadId\":\"$THREAD_ID\",\"input\":[{\"type\":\"text\",\"text\":\"$TURN2_PROMPT\"}],\"cwd\":\"$WORKSPACE\",\"approvalPolicy\":\"never\",\"sandboxPolicy\":{\"type\":\"dangerFullAccess\",\"networkAccess\":false}}}" > "$FIFO_IN"

TURN2_START=$(read_until_id 6 15)
echo "Turn 2 started"

echo "Waiting for turn 2 to complete..."
LAST_USAGE_T2=$(drain_and_get_usage)

if [ -n "$LAST_USAGE_T2" ]; then
  INPUT_TOKENS_AFTER=$(extract_input_tokens "$LAST_USAGE_T2")
  echo "Input tokens AFTER compact (cumulative): $INPUT_TOKENS_AFTER"
else
  echo "WARNING: No token usage captured for turn 2"
  INPUT_TOKENS_AFTER=0
fi

echo ""
echo "=== Results ==="
echo "Input tokens before compact (end of turn 1): $INPUT_TOKENS_BEFORE"
echo "Input tokens after compact (end of turn 2): $INPUT_TOKENS_AFTER"

if [ "$INPUT_TOKENS_BEFORE" -gt 0 ] && [ "$INPUT_TOKENS_AFTER" -gt 0 ]; then
  # The delta for turn 2 = total_after - total_before
  # This delta includes the compacted context + turn 2's own work
  TURN2_DELTA=$((INPUT_TOKENS_AFTER - INPUT_TOKENS_BEFORE))
  echo "Turn 2 input delta: $TURN2_DELTA"
  echo ""
  echo "To estimate retention ratio: compare Turn 2's first-call input"
  echo "against Turn 1's last-call input (which would be the pre-compact context)"
fi

# Also dump all TOKEN_UPDATE lines for manual analysis
echo ""
echo "=== All token usage events ==="
grep "TOKEN_UPDATE" "$LOG" | while IFS= read -r line; do
  raw="${line#TOKEN_UPDATE: }"
  echo "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
total = d.get('params', {}).get('tokenUsage', {}).get('total', {})
last = d.get('params', {}).get('tokenUsage', {}).get('last', {})
turn = d.get('params', {}).get('turnId', '?')
inp_total = total.get('inputTokens', total.get('input_tokens', '?'))
inp_last = last.get('inputTokens', last.get('input_tokens', '?'))
out_total = total.get('outputTokens', total.get('output_tokens', '?'))
print(f'  turn={turn}  total_input={inp_total}  last_input={inp_last}  total_output={out_total}')
" 2>/dev/null || echo "  (parse error)"
done
