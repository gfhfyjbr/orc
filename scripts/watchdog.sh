#!/usr/bin/env bash
# =============================================================================
# watchdog.sh — Monitor health of active runs
# =============================================================================
# Usage: ./watchdog.sh <session_dir> [check_interval] [run_timeout] [pane_silence]
#
# Runs in a loop, checking all active runs for:
#   - Overall timeout
#   - Dead panes
#   - Silent panes (no output for too long)
#
# Creates FAILED markers for timed-out or dead runs.
# Writes all events to event-log.jsonl.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  echo "Usage: watchdog.sh <session_dir> [check_interval] [run_timeout] [pane_silence]" >&2
  exit 1
fi

SESSION_DIR="$1"
CHECK_INTERVAL="${2:-10}"   # seconds between checks
RUN_TIMEOUT="${3:-300}"     # seconds until run is considered stuck
PANE_SILENCE="${4:-120}"    # seconds of pane silence = warning

# ---------------------------------------------------------------------------
# Main check function
# ---------------------------------------------------------------------------

check_run() {
  local run_dir="$1"
  local run_id
  run_id=$(basename "$run_dir")

  # Already finished?
  [ -f "$run_dir/DONE" ] && return 0
  [ -f "$run_dir/FAILED" ] && return 0

  # Must have spec.md to be a valid run
  [ -f "$run_dir/spec.md" ] || return 0

  # Check age of run (time since spec.md was created)
  local created
  if [[ "$OSTYPE" == "darwin"* ]]; then
    created=$(stat -f %m "$run_dir/spec.md" 2>/dev/null || echo 0)
  else
    created=$(stat -c %Y "$run_dir/spec.md" 2>/dev/null || echo 0)
  fi

  local now
  now=$(date +%s)
  local age=$(( now - created ))

  # Timeout check
  if [ "$age" -gt "$RUN_TIMEOUT" ]; then
    log_event "$SESSION_DIR" "error" "run $run_id exceeded timeout (${age}s > ${RUN_TIMEOUT}s)"
    cat > "$run_dir/FAILED" <<EOF
{
  "run_id": "$run_id",
  "status": "failed",
  "reason": "watchdog timeout after ${age}s",
  "failed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    return 1
  fi

  # Check if pane is alive
  if [ -f "$run_dir/.pane_id" ]; then
    local pane_id
    pane_id=$(cat "$run_dir/.pane_id")
    if ! pane_alive "$pane_id"; then
      log_event "$SESSION_DIR" "error" "run $run_id: pane $pane_id is dead"
      cat > "$run_dir/FAILED" <<EOF
{
  "run_id": "$run_id",
  "status": "failed",
  "reason": "pane $pane_id died unexpectedly",
  "failed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
      return 1
    fi
  fi

  # Check pane silence (warning only, not failure)
  if [ -f "$run_dir/transcript.log" ]; then
    local last_modified
    if [[ "$OSTYPE" == "darwin"* ]]; then
      last_modified=$(stat -f %m "$run_dir/transcript.log" 2>/dev/null || echo 0)
    else
      last_modified=$(stat -c %Y "$run_dir/transcript.log" 2>/dev/null || echo 0)
    fi
    local silence=$(( now - last_modified ))
    if [ "$silence" -gt "$PANE_SILENCE" ]; then
      log_event "$SESSION_DIR" "warn" "run $run_id: pane silent for ${silence}s"
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

log_event "$SESSION_DIR" "info" "Watchdog started (interval=${CHECK_INTERVAL}s, timeout=${RUN_TIMEOUT}s, silence=${PANE_SILENCE}s)"

while true; do
  # Check if session directory still exists
  if [ ! -d "$SESSION_DIR" ]; then
    echo "Session directory gone, watchdog exiting" >&2
    exit 0
  fi

  # Check all runs
  for run_dir in "$SESSION_DIR"/runs/run-*; do
    [ -d "$run_dir" ] || continue
    check_run "$run_dir" || true
  done

  sleep "$CHECK_INTERVAL"
done
