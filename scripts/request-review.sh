#!/usr/bin/env bash
# =============================================================================
# request-review.sh — Send review prompt to a reviewer subagent
# =============================================================================
# Usage: ./request-review.sh <session_id> <run_id> [review_scope]
#
# Sends a code review prompt to the reviewer agent.
# If review_scope is provided, it narrows what the reviewer should check.
# Default: check git diff and verify changes match the task.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
  orc_error "Usage: request-review.sh <session_id> <run_id> [review_scope]"
  exit 1
fi

SID="$1"
RUN_ID="$2"
REVIEW_SCOPE="${3:-}"

SESSION_DIR=$(get_session_dir "$SID")
RUN_DIR=$(get_run_dir "$SID" "$RUN_ID")

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

if [ ! -d "$RUN_DIR" ]; then
  orc_error "Run directory not found: $RUN_DIR"
  exit 1
fi

if [ ! -f "$RUN_DIR/.pane_id" ]; then
  orc_error "Pane ID not found for $RUN_ID"
  exit 1
fi

PANE_ID=$(cat "$RUN_DIR/.pane_id")

if ! pane_alive "$PANE_ID"; then
  orc_error "Reviewer pane $PANE_ID is dead"
  exit 1
fi

# ---------------------------------------------------------------------------
# Build review prompt
# ---------------------------------------------------------------------------

if [ -n "$REVIEW_SCOPE" ]; then
  SCOPE_TEXT="Focus your review on: $REVIEW_SCOPE"
else
  SCOPE_TEXT="Review the current git diff comprehensively."
fi

PROMPT=$(cat <<EOF
You are a code reviewer.

$SCOPE_TEXT

Steps:
1. Run \`git diff\` to see current changes.
2. Run \`git diff --staged\` to see staged changes.
3. Check that changes are consistent with the task described in \`$RUN_DIR/spec.md\`.
4. Look for:
   - Unrealistic assumptions
   - Security issues
   - Logic errors
   - Missing error handling
   - Changes outside the assigned scope
   - Unnecessary modifications

Write your findings:
- \`$RUN_DIR/result.json\` — structured verdict
- \`$RUN_DIR/handoff.md\` — human-readable review summary

result.json format:
{
  "run_id": "$RUN_ID",
  "role": "reviewer",
  "status": "completed",
  "verdict": "approve|request-changes|reject",
  "issues": [...],
  "suggested_fixes": [...],
  "residual_risks": [...]
}

After writing result files, create \`$RUN_DIR/DONE\`:
{
  "run_id": "$RUN_ID",
  "role": "reviewer",
  "status": "completed",
  "files": ["result.json", "handoff.md"],
  "completed_at": "<timestamp>"
}
EOF
)

# Save prompt for audit
echo "$PROMPT" > "$RUN_DIR/prompt.txt"

# ---------------------------------------------------------------------------
# Wait and send
# ---------------------------------------------------------------------------

if ! wait_for_prompt "$PANE_ID" 60; then
  orc_error "Reviewer pane not ready"
  exit 1
fi

send_prompt "$PANE_ID" "$PROMPT"

log_event "$SESSION_DIR" "info" "Review request sent to run $RUN_ID"
orc_ok "Review request sent to $RUN_ID"
