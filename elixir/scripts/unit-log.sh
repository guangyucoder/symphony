#!/usr/bin/env bash
# Pretty-print unit logs for a ticket.
# Usage: ./scripts/unit-log.sh ENT-140 [stage]
# Examples:
#   ./scripts/unit-log.sh ENT-140          # all stages
#   ./scripts/unit-log.sh ENT-140 verify   # only verify stages

set -euo pipefail

TICKET="${1:?Usage: unit-log.sh <TICKET_ID> [stage]}"
STAGE="${2:-}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/code/symphony-workspaces}"
UNITS_DIR="$WORKSPACE_ROOT/$TICKET/.symphony/units"

if [ ! -d "$UNITS_DIR" ]; then
  echo "No unit logs found at $UNITS_DIR"
  exit 1
fi

for logfile in "$UNITS_DIR"/*.jsonl; do
  [ -f "$logfile" ] || continue
  basename=$(basename "$logfile")

  # Filter by stage if specified
  if [ -n "$STAGE" ] && ! echo "$basename" | grep -qi "$STAGE"; then
    continue
  fi

  echo ""
  echo "━━━ $basename ━━━"
  python3 -c "
import sys, json

COLORS = {
    'prompt': '\033[36m',     # cyan
    'tool_call': '\033[33m',  # yellow
    'command': '\033[32m',    # green
    'file_change': '\033[35m',# magenta
    'reasoning': '\033[90m',  # gray
    'closeout': '\033[1m',    # bold
    'error': '\033[31m',      # red
    'turn_event': '\033[34m', # blue
}
RESET = '\033[0m'

for line in open('$logfile'):
    line = line.strip()
    if not line: continue
    try:
        d = json.loads(line)
        t = d.get('type', '?')
        ts = d.get('ts', '')[:19]
        color = COLORS.get(t, '')

        if t == 'prompt':
            text = d.get('text', '')[:200]
            print(f'{color}{ts}  PROMPT  {text}...{RESET}')
        elif t == 'tool_call':
            name = d.get('name', '?')
            args = d.get('args', '')[:100]
            failed = ' FAILED' if d.get('failed') else ''
            print(f'{color}{ts}  TOOL    {name}{failed}  {args}{RESET}')
        elif t == 'command':
            cmd = d.get('cmd', '?')[:120]
            print(f'{color}{ts}  CMD     {cmd}{RESET}')
        elif t == 'file_change':
            path = d.get('path', '?')
            print(f'{color}{ts}  FILE    {path}{RESET}')
        elif t == 'reasoning':
            summary = d.get('summary', '')[:200]
            print(f'{color}{ts}  THINK   {summary}{RESET}')
        elif t == 'closeout':
            result = d.get('result', '?')
            tokens = d.get('total_tokens', '?')
            print(f'{color}{ts}  CLOSE   {result}  tokens={tokens}{RESET}')
        elif t == 'error':
            msg = d.get('message', '')[:200]
            print(f'{color}{ts}  ERROR   {msg}{RESET}')
        elif t == 'turn_event':
            event = d.get('event', '?')
            print(f'{color}{ts}  TURN    {event}{RESET}')
        else:
            print(f'{ts}  {t}  {json.dumps(d)}')
    except:
        pass
" 2>/dev/null
done

echo ""
echo "━━━ Summary ━━━"
echo "Total unit log files: $(ls "$UNITS_DIR"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')"
echo "Location: $UNITS_DIR"
