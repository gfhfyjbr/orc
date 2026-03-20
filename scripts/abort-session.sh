#!/usr/bin/env bash
# =============================================================================
# abort-session.sh — Stop the entire orchestration session
# =============================================================================
# Usage: ./abort-session.sh <session_id> [session_name]
#
# Kills:
#   - watchdog process
#   - all agent panes
#   - the tmux session
#
# Marks all unfinished runs as cancelled.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 1 ]; then
  orc_error "Usage: abort-session.sh <session_id> [session_name]"
  exit 1
fi

SID="$1"

SESSION_DIR=$(get_session_dir "$SID")
SESSION_NAME="${2:-$(resolve_session_name "$SID")}"

if [ ! -d "$SESSION_DIR" ]; then
  orc_error "Session directory not found: $SESSION_DIR"
  exit 1
fi

# ---------------------------------------------------------------------------
# Kill watchdog
# ---------------------------------------------------------------------------

if [ -f "$SESSION_DIR/.watchdog_pid" ]; then
  WATCHDOG_PID=$(cat "$SESSION_DIR/.watchdog_pid")
  orc_info "Killing watchdog (PID: $WATCHDOG_PID)..."
  kill "$WATCHDOG_PID" 2>/dev/null || true
  rm -f "$SESSION_DIR/.watchdog_pid"
fi

# ---------------------------------------------------------------------------
# Kill orchestrate.sh if running
# ---------------------------------------------------------------------------

if [ -f "$SESSION_DIR/.orchestrate_pid" ]; then
  ORC_PID=$(cat "$SESSION_DIR/.orchestrate_pid")
  orc_info "Killing orchestrate loop (PID: $ORC_PID)..."
  kill "$ORC_PID" 2>/dev/null || true
  rm -f "$SESSION_DIR/.orchestrate_pid"
fi

# ---------------------------------------------------------------------------
# Mark all unfinished runs as cancelled
# ---------------------------------------------------------------------------

cancelled=0
for run_dir in "$SESSION_DIR"/runs/run-*; do
  [ -d "$run_dir" ] || continue
  [ -f "$run_dir/DONE" ] && continue
  [ -f "$run_dir/FAILED" ] && continue

  RUN_ID=$(basename "$run_dir")
  cat > "$run_dir/FAILED" <<EOF
{
  "run_id": "$RUN_ID",
  "status": "cancelled",
  "reason": "session aborted",
  "cancelled_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  cancelled=$((cancelled + 1))
done

if [ "$cancelled" -gt 0 ]; then
  orc_info "Marked $cancelled runs as cancelled"
fi

# ---------------------------------------------------------------------------
# Update session metadata
# ---------------------------------------------------------------------------

if [ -f "$SESSION_DIR/session.json" ]; then
  local_tmp=$(mktemp)
  jq '.status = "aborted" | .aborted_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "$SESSION_DIR/session.json" > "$local_tmp" && mv "$local_tmp" "$SESSION_DIR/session.json"
fi

# ---------------------------------------------------------------------------
# Kill tmux session
# ---------------------------------------------------------------------------

if session_exists "$SESSION_NAME"; then
  orc_info "Killing tmux session '$SESSION_NAME'..."
  tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Clean up worktree (but keep the branch for history)
# ---------------------------------------------------------------------------

WORKDIR=$(jq -r '.workdir // ""' "$SESSION_DIR/session.json" 2>/dev/null || echo "")
if [ -n "$WORKDIR" ]; then
  cleanup_session_worktree "$SID" "$WORKDIR"
  deregister_active_session "$WORKDIR" "$SID"
fi

log_event "$SESSION_DIR" "warn" "session $SID aborted"
orc_ok "Session $SID aborted. All runs marked as cancelled. Branch kept for history."
