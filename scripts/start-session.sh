#!/usr/bin/env bash
# =============================================================================
# start-session.sh — Bootstrap tmux session with main agent
# =============================================================================
# Usage: ./start-session.sh [session_name] [workdir]
#
# Creates:
#   - tmux session with left pane (main agent) and right worker zone
#   - .orchestrator/sessions/<session_id>/ directory structure
#   - Starts watchdog in background
#   - Sends system prompt to main agent
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
# If session name is provided, use it; otherwise auto-generate a unique one
if [ -n "${1:-}" ]; then
  SESSION_NAME="$1"
else
  SESSION_NAME=$(generate_tmux_name "orc")
fi
WORKDIR="${2:-$(pwd)}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Check tmux is available
if ! command -v tmux &>/dev/null; then
  orc_error "tmux is not installed. Please install tmux first."
  exit 1
fi

# Check jq is available
if ! command -v jq &>/dev/null; then
  orc_error "jq is not installed. Please install jq first."
  exit 1
fi

# Check opencode is available
if ! command -v opencode &>/dev/null; then
  orc_warn "opencode not found in PATH. Make sure it's available when agents start."
fi

# With auto-generated names this shouldn't happen, but check anyway
if session_exists "$SESSION_NAME"; then
  orc_error "tmux session '$SESSION_NAME' already exists. Use a different name or abort it first."
  exit 1
fi

# ---------------------------------------------------------------------------
# Create session directory structure
# ---------------------------------------------------------------------------
SID=$(generate_session_id)
SESSION_DIR="$WORKDIR/$ORC_DIR/sessions/$SID"
mkdir -p "$SESSION_DIR/runs"

# ---------------------------------------------------------------------------
# Create git worktree for session isolation
# ---------------------------------------------------------------------------
WORKTREE_PATH="$WORKDIR"
WORKTREE_BRANCH=""

if git -C "$WORKDIR" rev-parse --is-inside-work-tree &>/dev/null; then
  WORKTREE_BRANCH=$(get_session_branch "$SID")
  WORKTREE_PATH=$(create_session_worktree "$SID" "$WORKDIR")
  log_event "$SESSION_DIR" "info" "Worktree: $WORKTREE_PATH (branch: $WORKTREE_BRANCH)"
fi

# Save session metadata (with worktree info)
cat > "$SESSION_DIR/session.json" <<EOF
{
  "session_id": "$SID",
  "session_name": "$SESSION_NAME",
  "workdir": "$WORKDIR",
  "worktree_path": "$WORKTREE_PATH",
  "worktree_branch": "$WORKTREE_BRANCH",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "active"
}
EOF

# Initialize event log
log_event "$SESSION_DIR" "info" "Session $SID created"

# Save latest session pointer for convenience (kept for backward compat)
echo "$SID" > "$WORKDIR/$ORC_DIR/latest-session"

# Register in active-sessions directory (supports multiple concurrent sessions)
register_active_session "$WORKDIR" "$SID"

orc_info "Session ID: $SID"
orc_info "Session dir: $SESSION_DIR"
if [ "$WORKTREE_PATH" != "$WORKDIR" ]; then
  orc_info "Worktree: $WORKTREE_PATH"
  orc_info "Branch: $WORKTREE_BRANCH"
fi

# ---------------------------------------------------------------------------
# Create tmux session
# ---------------------------------------------------------------------------

# Create session with main window — full viewport, no splits
# Each subagent will get its own WINDOW (via orc_agent spawn)
# Use 220x55 for more vertical headroom (50 was too tight for 4-row grid with separators)
tmux new-session -d -s "$SESSION_NAME" -n main -x 220 -y 55

tmux select-pane -t "$SESSION_NAME":main.0 -T "orc:main"

# Start opencode in main window (gets full viewport)
# Use worktree path if available for file isolation
tmux send-keys -t "$SESSION_NAME":main.0 "cd $WORKTREE_PATH && OPENCODE_MESSAGE_QUEUE_MODE=hold opencode" Enter

# Go back to main window
tmux select-window -t "$SESSION_NAME":main

# Save pane ID
MAIN_PANE_ID=$(tmux display-message -t "$SESSION_NAME":main.0 -p '#{pane_id}')

echo "$MAIN_PANE_ID" > "$SESSION_DIR/.main_pane_id"

log_event "$SESSION_DIR" "info" "tmux session created: $SESSION_NAME"
log_event "$SESSION_DIR" "info" "Main pane: $MAIN_PANE_ID"

# ---------------------------------------------------------------------------
# Start watchdog
# ---------------------------------------------------------------------------
nohup "$SCRIPT_DIR/watchdog.sh" "$SESSION_DIR" 10 300 120 \
  > "$SESSION_DIR/watchdog.log" 2>&1 &
WATCHDOG_PID=$!
echo "$WATCHDOG_PID" > "$SESSION_DIR/.watchdog_pid"
log_event "$SESSION_DIR" "info" "Watchdog started: PID $WATCHDOG_PID"

# ---------------------------------------------------------------------------
# Wait for OpenCode to start, then send system prompt
# ---------------------------------------------------------------------------
orc_info "Waiting for OpenCode to start in main pane..."
sleep 5  # Give opencode time to initialize its TUI

if wait_for_prompt "$MAIN_PANE_ID" 30; then
  # Write the full system prompt to a file (not inline — too large for paste-buffer)
  SYSTEM_PROMPT_FILE="$SCRIPT_DIR/../templates/prompts/main-agent-system.md"
  INIT_PROMPT_FILE="$SESSION_DIR/init-prompt.md"

  if [ -f "$SYSTEM_PROMPT_FILE" ]; then
    orc_info "Writing system prompt to file..."

    # Build the combined system + session-specific prompt as a file
    cat "$SYSTEM_PROMPT_FILE" > "$INIT_PROMPT_FILE"
    cat >> "$INIT_PROMPT_FILE" <<INITEOF

---

## SESSION INFO

- Session ID: $SID
- Your pane ID: $MAIN_PANE_ID
- Working directory: $WORKTREE_PATH
- Project root: $WORKDIR
- Session branch: $WORKTREE_BRANCH

## QUICK REFERENCE

\`\`\`bash
# Spawn subagent (non-blocking):
./orc_agent spawn explorer "map the project structure"
./orc_agent spawn researcher "compare X vs Y"

# Batch spawn (parallel — & runs in background, wait collects all):
./orc_agent spawn explorer "goal" & ./orc_agent spawn researcher "goal2" & wait

# Reply to a specific agent pane:
./orc_agent reply <pane_id> "follow-up message"

# List agents:
./orc_agent list
\`\`\`

Subagent replies arrive as new messages prefixed with their run_id.
INITEOF

    # Send a SHORT, forceful prompt
    SHORT_PROMPT="Read \`$INIT_PROMPT_FILE\` now. You are an ORCHESTRATOR. You delegate ALL work via \`./orc_agent spawn <role> \"goal\"\`. NEVER read files or do work yourself. Subagent replies will arrive as messages."
    send_prompt "$MAIN_PANE_ID" "$SHORT_PROMPT"
    log_event "$SESSION_DIR" "info" "System prompt file written, short init sent to main agent"
  else
    orc_warn "System prompt template not found at $SYSTEM_PROMPT_FILE"
  fi
else
  orc_warn "Could not detect OpenCode readiness. Main agent may need manual prompt."
fi

# ---------------------------------------------------------------------------
# Output — session_id to stdout (for scripting), everything else to stderr
# ---------------------------------------------------------------------------
orc_ok "Session started: $SID (tmux: $SESSION_NAME)"
printf '%s\n' "$SID"
