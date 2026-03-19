#!/usr/bin/env bash
# =============================================================================
# resume-main.sh — Send follow-up prompt to main agent after subagent completes
# =============================================================================
# Usage: ./resume-main.sh <session_id> <run_id> [session_name]
#
# Reads the DONE or FAILED marker from the run directory and sends
# an appropriate follow-up prompt to the main agent pane.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
  orc_error "Usage: resume-main.sh <session_id> <run_id> [session_name]"
  exit 1
fi

SID="$1"
RUN_ID="$2"

SESSION_DIR=$(get_session_dir "$SID")
RUN_DIR=$(get_run_dir "$SID" "$RUN_ID")
SESSION_NAME="${3:-$(resolve_session_name "$SID")}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [ ! -d "$RUN_DIR" ]; then
  orc_error "Run directory not found: $RUN_DIR"
  exit 1
fi

if [ ! -f "$SESSION_DIR/.main_pane_id" ]; then
  orc_error "Main pane ID not found"
  exit 1
fi

MAIN_PANE=$(cat "$SESSION_DIR/.main_pane_id")

if ! pane_alive "$MAIN_PANE"; then
  orc_error "Main pane $MAIN_PANE is dead"
  exit 1
fi

# ---------------------------------------------------------------------------
# Build follow-up prompt
# ---------------------------------------------------------------------------

PROMPT=""

if [ -f "$RUN_DIR/DONE" ]; then
  ROLE=$(jq -r '.role // "unknown"' "$RUN_DIR/DONE" 2>/dev/null || echo "unknown")
  PROMPT=$(cat <<EOF
<<<ORC_FOLLOW_UP>>>
Subagent run \`$RUN_ID\` completed (role: $ROLE).
Status: completed.

Read the results:
- \`$RUN_DIR/handoff.md\`
- \`$RUN_DIR/result.json\`

Use this as input context.
If needed, update plan.json with new tasks or prepare the final answer.
<<<END_ORC_FOLLOW_UP>>>
EOF
)
elif [ -f "$RUN_DIR/FAILED" ]; then
  REASON=$(jq -r '.reason // "unknown"' "$RUN_DIR/FAILED" 2>/dev/null || echo "unknown")
  PROMPT=$(cat <<EOF
<<<ORC_FOLLOW_UP>>>
Subagent run \`$RUN_ID\` failed.
Reason: $REASON.

Read \`$RUN_DIR/FAILED\` for details.
Decide: retry (write a new run in plan.json) or continue without this result.
<<<END_ORC_FOLLOW_UP>>>
EOF
)
else
  orc_error "Run $RUN_ID has no DONE or FAILED marker"
  exit 1
fi

# ---------------------------------------------------------------------------
# Save follow-up prompt for audit
# ---------------------------------------------------------------------------
echo "$PROMPT" > "$RUN_DIR/followup-prompt.txt"

# ---------------------------------------------------------------------------
# Wait for main pane readiness
# ---------------------------------------------------------------------------
orc_info "Waiting for main agent readiness..."

if ! wait_for_prompt "$MAIN_PANE" 120; then
  orc_error "Main pane not ready after 120s"
  log_event "$SESSION_DIR" "error" "main pane not ready for follow-up from $RUN_ID"
  exit 1
fi

# ---------------------------------------------------------------------------
# Send follow-up via paste-buffer
# ---------------------------------------------------------------------------
orc_info "Sending follow-up to main agent for $RUN_ID..."

send_prompt "$MAIN_PANE" "$PROMPT"

log_event "$SESSION_DIR" "info" "Follow-up for run $RUN_ID sent to main agent"
orc_ok "Main agent resumed with results from $RUN_ID"
