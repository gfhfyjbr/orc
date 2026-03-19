#!/usr/bin/env bash
# =============================================================================
# recover-session.sh — Diagnose and recover session state after crash
# =============================================================================
# Usage: ./recover-session.sh <session_id>
#
# Scans all runs and reports their status.
# Identifies stuck runs (no DONE/FAILED marker).
# Does NOT automatically restart anything — only shows state and options.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  orc_error "Usage: recover-session.sh <session_id>"
  exit 1
fi

SID="$1"
SESSION_DIR=$(get_session_dir "$SID")

if [ ! -d "$SESSION_DIR" ]; then
  orc_error "Session directory not found: $SESSION_DIR"
  exit 1
fi

# ---------------------------------------------------------------------------
# Session info
# ---------------------------------------------------------------------------

echo "=== Session Recovery ==="
echo "Session ID: $SID"
echo "Session dir: $SESSION_DIR"
echo ""

# Show session metadata if available
if [ -f "$SESSION_DIR/session.json" ]; then
  echo "Session metadata:"
  jq '.' "$SESSION_DIR/session.json" 2>/dev/null || echo "  (corrupted)"
  echo ""
fi

# ---------------------------------------------------------------------------
# Scan runs
# ---------------------------------------------------------------------------

total=0; done=0; failed=0; stuck=0

echo "=== Run Status ==="

for run_dir in "$SESSION_DIR"/runs/run-*; do
  [ -d "$run_dir" ] || continue
  total=$((total + 1))
  RUN_ID=$(basename "$run_dir")

  if [ -f "$run_dir/DONE" ]; then
    done=$((done + 1))
    local_role=$(jq -r '.role // "?"' "$run_dir/DONE" 2>/dev/null || echo "?")
    echo "  [DONE]   $RUN_ID ($local_role)"
  elif [ -f "$run_dir/FAILED" ]; then
    failed=$((failed + 1))
    local_reason=$(jq -r '.reason // "unknown"' "$run_dir/FAILED" 2>/dev/null || echo "unknown")
    echo "  [FAILED] $RUN_ID — $local_reason"
  else
    stuck=$((stuck + 1))
    echo "  [STUCK]  $RUN_ID — no DONE/FAILED marker"

    # Show additional diagnostics for stuck runs
    if [ -f "$run_dir/.pane_id" ]; then
      local_pane=$(cat "$run_dir/.pane_id")
      if pane_alive "$local_pane"; then
        echo "           Pane $local_pane is ALIVE"
      else
        echo "           Pane $local_pane is DEAD"
      fi
    fi

    if [ -f "$run_dir/status.json" ]; then
      local_status=$(jq -r '.status // "?" | . + " (" + (.phase // "?") + ")"' "$run_dir/status.json" 2>/dev/null || echo "?")
      echo "           Last status: $local_status"
    fi
  fi
done

echo ""
echo "Total: $total | Done: $done | Failed: $failed | Stuck: $stuck"

# ---------------------------------------------------------------------------
# Plan status
# ---------------------------------------------------------------------------

echo ""
echo "=== Plan Status ==="

if [ -f "$SESSION_DIR/plan.json" ]; then
  local_task_count=$(jq '.tasks | length' "$SESSION_DIR/plan.json" 2>/dev/null || echo "?")
  echo "Plan exists: $local_task_count tasks"
  jq -r '.tasks[] | "  - \(.run_id) (\(.role)): \(.goal)"' "$SESSION_DIR/plan.json" 2>/dev/null || echo "  (corrupted plan)"
else
  echo "No plan.json found"
fi

# ---------------------------------------------------------------------------
# Watchdog status
# ---------------------------------------------------------------------------

echo ""
echo "=== Watchdog Status ==="

if [ -f "$SESSION_DIR/.watchdog_pid" ]; then
  WATCHDOG_PID=$(cat "$SESSION_DIR/.watchdog_pid")
  if kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    echo "Watchdog is RUNNING (PID: $WATCHDOG_PID)"
  else
    echo "Watchdog is DEAD (was PID: $WATCHDOG_PID)"
  fi
else
  echo "No watchdog PID file found"
fi

# ---------------------------------------------------------------------------
# Recent events
# ---------------------------------------------------------------------------

echo ""
echo "=== Recent Events (last 10) ==="

if [ -f "$SESSION_DIR/event-log.jsonl" ]; then
  tail -10 "$SESSION_DIR/event-log.jsonl" | while IFS= read -r line; do
    ts=$(echo "$line" | jq -r '.ts // "?"' 2>/dev/null || echo "?")
    level=$(echo "$line" | jq -r '.level // "?"' 2>/dev/null || echo "?")
    msg=$(echo "$line" | jq -r '.msg // "?"' 2>/dev/null || echo "?")
    printf "  [%s] %s: %s\n" "$ts" "$level" "$msg"
  done
else
  echo "  No event log found"
fi

# ---------------------------------------------------------------------------
# Recommendations
# ---------------------------------------------------------------------------

if [ "$stuck" -gt 0 ]; then
  echo ""
  echo "=== Recommendations ==="
  echo "Stuck runs detected. Options:"
  echo ""
  echo "  1. Retry: re-spawn agent with same spec"
  echo "     for each stuck run-NNN:"
  echo "       $SCRIPT_DIR/spawn-agent.sh $SID run-NNN <role>"
  echo "       $SCRIPT_DIR/send-task.sh $SID run-NNN"
  echo ""
  echo "  2. Cancel: mark as FAILED and move on"
  echo "     $SCRIPT_DIR/cancel-agent.sh $SID <run_id>"
  echo ""
  echo "  3. Resume main: send follow-up to main agent with partial results"
  echo "     $SCRIPT_DIR/resume-main.sh $SID <run_id>"
  echo ""
  echo "  4. Abort: kill everything"
  echo "     $SCRIPT_DIR/abort-session.sh $SID"
fi
