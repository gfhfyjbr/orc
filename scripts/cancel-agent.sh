#!/usr/bin/env bash
# =============================================================================
# cancel-agent.sh — Cancel a single subagent run
# =============================================================================
# Usage: ./cancel-agent.sh <session_id> <run_id>
#
# Kills the agent's tmux pane and creates a FAILED marker.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
  orc_error "Usage: cancel-agent.sh <session_id> <run_id>"
  exit 1
fi

SID="$1"
RUN_ID="$2"

SESSION_DIR=$(get_session_dir "$SID")
RUN_DIR=$(get_run_dir "$SID" "$RUN_ID")

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

if [ ! -d "$RUN_DIR" ]; then
  orc_error "Run directory not found: $RUN_DIR"
  exit 1
fi

# Already finished?
if run_is_finished "$RUN_DIR"; then
  orc_warn "Run $RUN_ID is already finished"
  exit 0
fi

# ---------------------------------------------------------------------------
# Kill pane
# ---------------------------------------------------------------------------

if [ -f "$RUN_DIR/.pane_id" ]; then
  PANE_ID=$(cat "$RUN_DIR/.pane_id")
  orc_info "Killing pane $PANE_ID for $RUN_ID..."
  tmux kill-pane -t "$PANE_ID" 2>/dev/null || true

  # Remove pane from layout file so equalize_layout calculations stay accurate
  LAYOUT_FILE="$SESSION_DIR/.layout_panes"
  if [ -f "$LAYOUT_FILE" ]; then
    TEMP_LAYOUT="${LAYOUT_FILE}.tmp.$$"
    grep -v "^${PANE_ID}$" "$LAYOUT_FILE" > "$TEMP_LAYOUT" 2>/dev/null || true
    mv "$TEMP_LAYOUT" "$LAYOUT_FILE"
  fi
else
  orc_warn "No pane_id found for $RUN_ID"
fi

# ---------------------------------------------------------------------------
# Create FAILED marker
# ---------------------------------------------------------------------------

cat > "$RUN_DIR/FAILED" <<EOF
{
  "run_id": "$RUN_ID",
  "status": "cancelled",
  "reason": "manually cancelled by user or orchestrator",
  "cancelled_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# Update status
cat > "$RUN_DIR/status.json" <<EOF
{
  "run_id": "$RUN_ID",
  "role": "$(jq -r '.role // "unknown"' "$RUN_DIR/.agent_meta.json" 2>/dev/null || echo "unknown")",
  "status": "cancelled",
  "phase": "cancelled",
  "message": "Run was manually cancelled",
  "updated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log_event "$SESSION_DIR" "warn" "run $RUN_ID cancelled"
orc_ok "Run $RUN_ID cancelled"
