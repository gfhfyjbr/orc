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

  # Sync working files from main tree into worktree.
  # Worktree is created from HEAD commit, so any uncommitted changes
  # (new agents, modified scripts, tools/plugins) would be missing.
  # rsync ensures the worktree always has the latest state.
  if [ "$WORKTREE_PATH" != "$WORKDIR" ]; then
    # .opencode/ — agents, tools, plugins
    [ -d "$WORKDIR/.opencode" ] && rsync -a --delete "$WORKDIR/.opencode/" "$WORKTREE_PATH/.opencode/"
    # scripts/ — lib.sh, watchdog, spawn-agent etc.
    [ -d "$WORKDIR/scripts" ] && rsync -a --delete "$WORKDIR/scripts/" "$WORKTREE_PATH/scripts/"
    # orc_agent, orc — main executables
    [ -f "$WORKDIR/orc_agent" ] && cp -f "$WORKDIR/orc_agent" "$WORKTREE_PATH/orc_agent"
    [ -f "$WORKDIR/orc" ] && cp -f "$WORKDIR/orc" "$WORKTREE_PATH/orc"
    # templates/ — prompt templates and role specs
    [ -d "$WORKDIR/templates" ] && rsync -a --delete "$WORKDIR/templates/" "$WORKTREE_PATH/templates/"
    # opencode.json — project config
    [ -f "$WORKDIR/opencode.json" ] && cp -f "$WORKDIR/opencode.json" "$WORKTREE_PATH/opencode.json"
    # AGENTS.md — instructions
    [ -f "$WORKDIR/AGENTS.md" ] && cp -f "$WORKDIR/AGENTS.md" "$WORKTREE_PATH/AGENTS.md"
    # .orchestrator/ — symlink so subagents can access sessions/runs locally
    if [ ! -e "$WORKTREE_PATH/.orchestrator" ]; then
      ln -s "$WORKDIR/.orchestrator" "$WORKTREE_PATH/.orchestrator"
    fi
    log_event "$SESSION_DIR" "info" "Synced orc files from main tree to worktree"
  fi
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

# Register in active-sessions directory (supports multiple concurrent sessions)
register_active_session "$WORKDIR" "$SID" "$WORKTREE_PATH"

# Save latest session pointer for convenience (backward compat for scripts
# that haven't been updated to use active-sessions/ yet)
echo "$SID" > "$WORKDIR/$ORC_DIR/latest-session"

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

# Set ORC_SESSION_ID in tmux session environment — all panes/windows in this
# tmux session inherit it, so orc_agent can resolve the correct session
# even when multiple sessions run in parallel.
tmux set-environment -t "$SESSION_NAME" ORC_SESSION_ID "$SID"

# Start opencode in main window as orchestrator agent (gets full viewport)
# --agent orc-orchestrator gives it the orchestrator role natively via opencode's agent system
tmux send-keys -t "$SESSION_NAME":main.0 "cd $WORKTREE_PATH && export ORC_SESSION_ID=$SID && OPENCODE_MESSAGE_QUEUE_MODE=hold opencode --agent orc-orchestrator" Enter

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

# No init-prompt needed — the orc-orchestrator agent definition in
# .opencode/agents/orc-orchestrator.md provides all instructions natively.
# OpenCode loads it automatically via --agent orc-orchestrator.
log_event "$SESSION_DIR" "info" "Orchestrator agent started via --agent orc-orchestrator"

# ---------------------------------------------------------------------------
# Output — session_id to stdout (for scripting), everything else to stderr
# ---------------------------------------------------------------------------
orc_ok "Session started: $SID (tmux: $SESSION_NAME)"
printf '%s\n' "$SID"
