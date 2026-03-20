#!/usr/bin/env bash
# LEGACY — replaced by orc_agent spawn. Not used in production.
# =============================================================================
# spawn-agent.sh — Create a new tmux pane for a subagent and start OpenCode
# =============================================================================
# Usage: ./spawn-agent.sh <session_id> <run_id> <role> [session_name]
#
# Creates a new pane in the right worker zone, starts opencode,
# sets up pipe-pane for transcript logging.
#
# Outputs the pane_id to stdout.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 3 ]; then
  orc_error "Usage: spawn-agent.sh <session_id> <run_id> <role> [session_name]"
  exit 1
fi

SID="$1"
RUN_ID="$2"
ROLE="$3"

SESSION_DIR=$(get_session_dir "$SID")
RUN_DIR=$(get_run_dir "$SID" "$RUN_ID")
SESSION_NAME="${4:-$(resolve_session_name "$SID")}"
WORKDIR=$(jq -r '.workdir' "$SESSION_DIR/session.json" 2>/dev/null || pwd)

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if ! session_exists "$SESSION_NAME"; then
  orc_error "tmux session '$SESSION_NAME' does not exist"
  exit 1
fi

if [ ! -d "$SESSION_DIR" ]; then
  orc_error "Session directory not found: $SESSION_DIR"
  exit 1
fi

# Check concurrent agent limit
ACTIVE=$(count_active_agents "$SESSION_DIR")
if [ "$ACTIVE" -ge "$MAX_CONCURRENT_AGENTS" ]; then
  orc_error "Max concurrent agents reached ($MAX_CONCURRENT_AGENTS). Wait for running agents to finish."
  exit 2
fi

# Create run directory if not exists
mkdir -p "$RUN_DIR"

# ---------------------------------------------------------------------------
# Create new pane in worker zone
# ---------------------------------------------------------------------------

# Read the worker zone pane to split from
if [ ! -f "$SESSION_DIR/.worker_zone_pane_id" ]; then
  orc_error "Worker zone pane ID not found. Session may be corrupted."
  exit 1
fi

WORKER_ZONE=$(cat "$SESSION_DIR/.worker_zone_pane_id")

# Find an existing worker pane to split from, or use the worker zone
# Strategy: split the worker zone vertically (top-bottom) for new agents
SPLIT_TARGET="$WORKER_ZONE"

# Check if worker zone pane is still alive
if ! pane_alive "$WORKER_ZONE"; then
  orc_warn "Worker zone pane is dead. Trying to find alternative..."
  # Try to use the second pane in main window
  SPLIT_TARGET=$(tmux list-panes -t "$SESSION_NAME":main -F '#{pane_id}' | tail -1)
fi

# Create new pane by splitting the target vertically
tmux split-window -t "$SPLIT_TARGET" -v "bash"

# Get the new pane's ID (it's now the active pane)
NEW_PANE_ID=$(tmux display-message -t "$SESSION_NAME":main -p '#{pane_id}')

# Set pane title for identification
tmux select-pane -t "$NEW_PANE_ID" -T "wrk:${ROLE}:${RUN_ID}"

# ---------------------------------------------------------------------------
# Start OpenCode in the new pane
# ---------------------------------------------------------------------------
tmux send-keys -t "$NEW_PANE_ID" "cd $WORKDIR && opencode --agent orc-$ROLE" Enter

# ---------------------------------------------------------------------------
# Set up transcript logging via pipe-pane
# ---------------------------------------------------------------------------
tmux pipe-pane -t "$NEW_PANE_ID" -o "cat >> $RUN_DIR/transcript.log"

# ---------------------------------------------------------------------------
# Save metadata
# ---------------------------------------------------------------------------
echo "$NEW_PANE_ID" > "$RUN_DIR/.pane_id"

cat > "$RUN_DIR/.agent_meta.json" <<EOF
{
  "run_id": "$RUN_ID",
  "role": "$ROLE",
  "pane_id": "$NEW_PANE_ID",
  "session_name": "$SESSION_NAME",
  "spawned_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Initialize status
cat > "$RUN_DIR/status.json" <<EOF
{
  "run_id": "$RUN_ID",
  "role": "$ROLE",
  "status": "spawned",
  "phase": "initializing",
  "message": "Agent pane created, waiting for OpenCode to start",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log_event "$SESSION_DIR" "info" "run $RUN_ID spawned (role: $ROLE, pane: $NEW_PANE_ID)"

# Select main pane back so user stays in main view
tmux select-pane -t "$(cat "$SESSION_DIR/.main_pane_id" 2>/dev/null || echo "$SESSION_NAME":main.0)"

orc_ok "Agent $RUN_ID ($ROLE) spawned in pane $NEW_PANE_ID"

# Output pane_id for scripting
printf '%s\n' "$NEW_PANE_ID"
