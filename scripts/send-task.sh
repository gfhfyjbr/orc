#!/usr/bin/env bash
# =============================================================================
# send-task.sh — Send bootstrap prompt to a subagent via paste-buffer
# =============================================================================
# Usage: ./send-task.sh <session_id> <run_id> [timeout]
#
# Prerequisites:
#   - Agent pane must be spawned (spawn-agent.sh)
#   - spec.md must exist in the run directory
#
# Sends the bootstrap prompt using buffered paste (not line-by-line send-keys).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
  orc_error "Usage: send-task.sh <session_id> <run_id> [timeout]"
  exit 1
fi

SID="$1"
RUN_ID="$2"
TIMEOUT="${3:-60}"

SESSION_DIR=$(get_session_dir "$SID")
RUN_DIR=$(get_run_dir "$SID" "$RUN_ID")

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [ ! -d "$RUN_DIR" ]; then
  orc_error "Run directory not found: $RUN_DIR"
  exit 1
fi

if [ ! -f "$RUN_DIR/spec.md" ]; then
  orc_error "spec.md not found in $RUN_DIR"
  exit 1
fi

if [ ! -f "$RUN_DIR/.pane_id" ]; then
  orc_error "Pane ID not found. Was the agent spawned?"
  exit 1
fi

PANE_ID=$(cat "$RUN_DIR/.pane_id")

if ! pane_alive "$PANE_ID"; then
  orc_error "Agent pane $PANE_ID is dead"
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate bootstrap prompt
# ---------------------------------------------------------------------------
generate_bootstrap_prompt "$RUN_DIR"
orc_info "Bootstrap prompt generated: $RUN_DIR/prompt.txt"

# ---------------------------------------------------------------------------
# Wait for OpenCode to be ready
# ---------------------------------------------------------------------------
orc_info "Waiting for OpenCode readiness in pane $PANE_ID..."

if ! wait_for_prompt "$PANE_ID" "$TIMEOUT"; then
  orc_error "Agent pane $PANE_ID not ready after ${TIMEOUT}s"
  log_event "$SESSION_DIR" "error" "run $RUN_ID: pane not ready for prompt"
  exit 1
fi

# ---------------------------------------------------------------------------
# Send prompt via paste-buffer
# ---------------------------------------------------------------------------
orc_info "Sending bootstrap prompt to $RUN_ID..."

send_prompt_file "$PANE_ID" "$RUN_DIR/prompt.txt"

# Update status
cat > "$RUN_DIR/status.json" <<EOF
{
  "run_id": "$RUN_ID",
  "role": "$(jq -r '.role // "unknown"' "$RUN_DIR/.agent_meta.json" 2>/dev/null || echo "unknown")",
  "status": "running",
  "phase": "executing",
  "message": "Bootstrap prompt sent, agent is working",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log_event "$SESSION_DIR" "info" "run $RUN_ID: bootstrap prompt sent"
orc_ok "Task sent to $RUN_ID"
