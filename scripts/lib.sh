#!/usr/bin/env bash
# =============================================================================
# lib.sh — Shared functions for opencode-orc orchestration
# =============================================================================
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib.sh"
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
ORC_DIR=".orchestrator"
DEFAULT_SESSION="opencode-orc"
MAX_CONCURRENT_AGENTS=3
VALID_ROLES='["researcher","explorer","reviewer","summarizer","verifier","coder"]'

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Portable locking (mkdir-based, works on macOS + Linux without flock)
# ---------------------------------------------------------------------------

# Acquire a lock using atomic mkdir.
# Usage: acquire_lock <lock_path> [timeout_seconds]
# Creates <lock_path>/ directory as lock. Writes PID to <lock_path>/pid.
# Retries with backoff until timeout. Detects stale locks via PID liveness.
# Returns 0 on success, 1 on timeout.
acquire_lock() {
  local lock_path="$1"
  local timeout="${2:-10}"
  local elapsed=0
  local sleep_interval=0.1

  while [ "$elapsed" -lt "$timeout" ]; do
    if mkdir "$lock_path" 2>/dev/null; then
      # Lock acquired — record our PID for stale detection
      echo $$ > "$lock_path/pid"
      return 0
    fi

    # Lock exists — check if holder is still alive (stale lock detection)
    if [ -f "$lock_path/pid" ]; then
      local holder_pid
      holder_pid=$(cat "$lock_path/pid" 2>/dev/null || echo "")
      if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
        # Holder is dead — remove stale lock and retry immediately
        rm -rf "$lock_path" 2>/dev/null || true
        continue
      fi
    fi

    sleep "$sleep_interval"
    elapsed=$((elapsed + 1))
    # Back off: 0.1 -> 0.2 -> 0.5 -> 1s
    case "$elapsed" in
      [1-3]) sleep_interval=0.2 ;;
      [4-6]) sleep_interval=0.5 ;;
      *)     sleep_interval=1 ;;
    esac
  done

  return 1  # Timeout
}

# Release a lock.
# Usage: release_lock <lock_path>
release_lock() {
  local lock_path="$1"
  rm -rf "$lock_path" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Print colored message to stderr
orc_info()  { printf "${BLUE}[orc]${NC} %s\n" "$*" >&2; }
orc_ok()    { printf "${GREEN}[orc]${NC} %s\n" "$*" >&2; }
orc_warn()  { printf "${YELLOW}[orc]${NC} %s\n" "$*" >&2; }
orc_error() { printf "${RED}[orc]${NC} %s\n" "$*" >&2; }

# Write structured event to session's event-log.jsonl
# Usage: log_event <session_dir> <level> <message>
# Uses jq for safe JSON construction (no injection via special chars).
log_event() {
  local session_dir="$1"
  local level="$2"
  local msg="$3"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -c -n --arg ts "$ts" --arg level "$level" --arg msg "$msg" \
    '{"ts":$ts,"level":$level,"msg":$msg}' \
    >> "$session_dir/event-log.jsonl"
}

# ---------------------------------------------------------------------------
# Session ID generation
# ---------------------------------------------------------------------------

# Generate a session ID based on timestamp
# Format: session-YYYYMMDD-HHMMSS
generate_session_id() {
  printf 'session-%s' "$(date +%Y%m%d-%H%M%S)"
}

# Generate next run ID for a session (race-condition safe).
# Uses atomic mkdir to claim the run directory — two parallel calls
# will never get the same ID.
# Usage: generate_run_id <session_dir>
generate_run_id() {
  local session_dir="$1"
  local runs_dir="$session_dir/runs"
  mkdir -p "$runs_dir"

  # Find current max to start from (optimization, not for correctness)
  local max_num=0
  if [ -d "$runs_dir" ]; then
    for d in "$runs_dir"/run-*; do
      [ -d "$d" ] || continue
      local num
      num=$(basename "$d" | sed 's/run-//' | sed 's/^0*//')
      num=${num:-0}
      if [ "$num" -gt "$max_num" ]; then
        max_num="$num"
      fi
    done
  fi

  # Atomically claim the next available run directory via mkdir
  local candidate=$((max_num + 1))
  local run_id
  while true; do
    run_id=$(printf 'run-%03d' "$candidate")
    if mkdir "$runs_dir/$run_id" 2>/dev/null; then
      # Successfully claimed this ID
      printf '%s' "$run_id"
      return 0
    fi
    # Directory already exists (race or pre-existing) — try next
    candidate=$((candidate + 1))
  done
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# Get the project root (where .orchestrator/ lives)
# Walks up from CWD looking for .orchestrator/ or .git/ (supports git worktrees)
get_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.orchestrator" ]; then
      printf '%s' "$dir"
      return 0
    fi
    # Support both regular repos (.git is dir) and worktrees (.git is file)
    if [ -d "$dir/.git" ] || [ -f "$dir/.git" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  # Fallback to CWD
  printf '%s' "$PWD"
}

# Resolve session directory
# Usage: get_session_dir <session_id>
get_session_dir() {
  local sid="$1"
  printf '%s/%s/sessions/%s' "$(get_project_root)" "$ORC_DIR" "$sid"
}

# Resolve run directory
# Usage: get_run_dir <session_id> <run_id>
get_run_dir() {
  local sid="$1"
  local run_id="$2"
  printf '%s/runs/%s' "$(get_session_dir "$sid")" "$run_id"
}

# ---------------------------------------------------------------------------
# Session name resolution
# ---------------------------------------------------------------------------

# Read tmux session name from session.json
# Falls back to DEFAULT_SESSION if not found
# Usage: resolve_session_name <session_id>
resolve_session_name() {
  local sid="$1"
  local session_dir
  session_dir=$(get_session_dir "$sid")

  if [ -f "$session_dir/session.json" ]; then
    local name
    name=$(jq -r '.session_name // ""' "$session_dir/session.json" 2>/dev/null || echo "")
    if [ -n "$name" ]; then
      printf '%s' "$name"
      return 0
    fi
  fi

  printf '%s' "$DEFAULT_SESSION"
}

# Generate a unique tmux session name that doesn't conflict
# Usage: generate_tmux_name [prefix]
generate_tmux_name() {
  local prefix="${1:-orc}"
  local num=1

  while tmux has-session -t "${prefix}-${num}" 2>/dev/null; do
    num=$((num + 1))
  done

  printf '%s-%d' "$prefix" "$num"
}

# ---------------------------------------------------------------------------
# tmux helpers
# ---------------------------------------------------------------------------

# Check if a tmux session exists
# Usage: session_exists <session_name>
session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# Check if a tmux pane is alive
# Usage: pane_alive <pane_id>
pane_alive() {
  tmux display-message -t "$1" -p '#{pane_id}' >/dev/null 2>&1
}

# Wait for a pane to show an input prompt (i.e., OpenCode is ready for input)
# Uses capture-pane to check last N lines for known prompt markers.
# Usage: wait_for_prompt <pane_id> [timeout_seconds]
wait_for_prompt() {
  local pane="$1"
  local timeout="${2:-60}"
  local elapsed=0

  while [ "$elapsed" -lt "$timeout" ]; do
    local content
    content=$(tmux capture-pane -t "$pane" -p -S -5 2>/dev/null || echo "")

    # OpenCode shows "Ask anything..." in the input area when ready
    if echo "$content" | grep -qE '(Ask anything|ctrl\+p commands|MCP /status)'; then
      return 0
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  orc_warn "Pane $pane not ready after ${timeout}s"
  return 1
}

# Count currently active (non-DONE, non-FAILED) worker panes
# Usage: count_active_agents <session_dir>
count_active_agents() {
  local session_dir="$1"
  local count=0

  for run_dir in "$session_dir"/runs/run-*; do
    [ -d "$run_dir" ] || continue
    [ -f "$run_dir/DONE" ] && continue
    [ -f "$run_dir/FAILED" ] && continue
    [ -f "$run_dir/.done_time" ] && continue
    if [ -f "$run_dir/.pane_id" ]; then
      local pid
      pid=$(cat "$run_dir/.pane_id")
      if pane_alive "$pid"; then
        count=$((count + 1))
      fi
    fi
  done

  printf '%d' "$count"
}

# ---------------------------------------------------------------------------
# Buffered prompt sending (Section 8.3 of PLAN)
# ---------------------------------------------------------------------------

# Sanitize prompt text — strip ANSI escape sequences
# Usage: sanitize_prompt <text>
sanitize_prompt() {
  printf '%s' "$1" | tr -d '\033'
}

# Send a prompt to a pane via send-keys -l (literal)
# OpenCode TUI doesn't receive paste-buffer properly, so we use
# send-keys with literal flag which works with TUI input fields.
# Usage: send_prompt <pane_id> <prompt_text>
send_prompt() {
  local pane="$1"
  local prompt="$2"
  local sanitized
  sanitized=$(sanitize_prompt "$prompt")

  # send-keys -l sends text literally (no key interpretation)
  tmux send-keys -t "$pane" -l "$sanitized"
  sleep 0.3
  tmux send-keys -t "$pane" Enter
}

# Send prompt from file — sends a short "read this file" command instead
# of dumping the entire file content (TUI can't handle large pastes)
# Usage: send_prompt_file <pane_id> <file_path>
send_prompt_file() {
  local pane="$1"
  local file="$2"

  if [ ! -f "$file" ]; then
    orc_error "Prompt file not found: $file"
    return 1
  fi

  # Send a short command to read the file, not the file contents
  send_prompt "$pane" "Read the file \`$file\` and follow the instructions inside."
}

# ---------------------------------------------------------------------------
# Plan validation (Section 28.2 of PLAN)
# ---------------------------------------------------------------------------

# Validate plan.json structure and content
# Usage: validate_plan <plan_file>
validate_plan() {
  local plan="$1"

  # Check file exists and is valid JSON
  if [ ! -f "$plan" ]; then
    orc_error "Plan file not found: $plan"
    return 1
  fi

  if ! jq empty "$plan" 2>/dev/null; then
    orc_error "Plan file is not valid JSON: $plan"
    return 1
  fi

  # Check required fields
  if ! jq -e '.session_id' "$plan" >/dev/null 2>&1; then
    orc_error "Plan missing session_id"
    return 1
  fi

  if ! jq -e '.tasks' "$plan" >/dev/null 2>&1; then
    orc_error "Plan missing tasks array"
    return 1
  fi

  local task_count
  task_count=$(jq '.tasks | length' "$plan")
  if [ "$task_count" -eq 0 ]; then
    orc_error "Plan has no tasks"
    return 1
  fi

  # Validate each task has required fields
  local missing
  missing=$(jq -r '.tasks[] | select(.run_id == null or .role == null or .goal == null) | .run_id // "unknown"' "$plan")
  if [ -n "$missing" ]; then
    orc_error "Tasks missing required fields (run_id, role, goal): $missing"
    return 1
  fi

  # Check all roles are from the valid pool
  local bad_roles
  bad_roles=$(jq -r --argjson valid "$VALID_ROLES" \
    '.tasks[].role | select(. as $r | $valid | index($r) | not)' "$plan")
  if [ -n "$bad_roles" ]; then
    orc_error "Invalid roles in plan: $bad_roles"
    return 1
  fi

  # Check run_id format (run-NNN)
  local bad_ids
  bad_ids=$(jq -r '.tasks[].run_id | select(test("^run-[0-9]+$") | not)' "$plan")
  if [ -n "$bad_ids" ]; then
    orc_error "Invalid run_id format (expected run-NNN): $bad_ids"
    return 1
  fi

  # Check output_files are within .orchestrator/
  local bad_paths
  bad_paths=$(jq -r '.tasks[].output_files[]? | select(startswith(".orchestrator/") | not)' "$plan" 2>/dev/null)
  if [ -n "$bad_paths" ]; then
    orc_error "Invalid output paths (must be under .orchestrator/): $bad_paths"
    return 1
  fi

  orc_ok "Plan validated successfully ($task_count tasks)"
  return 0
}

# ---------------------------------------------------------------------------
# Run status helpers
# ---------------------------------------------------------------------------

# Check if a run is complete (DONE marker or .done_time exists)
# Usage: run_is_done <run_dir>
run_is_done() {
  [ -f "$1/DONE" ] || [ -f "$1/.done_time" ]
}

# Check if a run has failed (FAILED marker exists)
# Usage: run_is_failed <run_dir>
run_is_failed() {
  [ -f "$1/FAILED" ]
}

# Check if a run is finished (either DONE, .done_time, or FAILED)
# Usage: run_is_finished <run_dir>
run_is_finished() {
  [ -f "$1/DONE" ] || [ -f "$1/.done_time" ] || [ -f "$1/FAILED" ]
}

# Wait for a run to finish (DONE or FAILED marker)
# Usage: wait_for_run <run_dir> [timeout_seconds]
wait_for_run() {
  local run_dir="$1"
  local timeout="${2:-300}"
  local elapsed=0
  local run_id
  run_id=$(basename "$run_dir")

  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -f "$run_dir/DONE" ] || [ -f "$run_dir/.done_time" ]; then
      orc_ok "Run $run_id completed"
      return 0
    fi
    if [ -f "$run_dir/FAILED" ]; then
      local reason
      reason=$(jq -r '.reason // "unknown"' "$run_dir/FAILED" 2>/dev/null || echo "unknown")
      orc_error "Run $run_id failed: $reason"
      return 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  # Timeout — create FAILED marker from watchdog
  orc_error "Run $run_id timed out after ${timeout}s"
  cat > "$run_dir/FAILED" <<EOF
{
  "run_id": "$run_id",
  "status": "failed",
  "reason": "timeout after ${timeout}s",
  "failed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  return 1
}

# REMOVED: generate_spec and generate_bootstrap_prompt (legacy file-based protocol, replaced by orc_agent done)

# ---------------------------------------------------------------------------
# Active session registry (replaces singleton latest-session)
# ---------------------------------------------------------------------------

# Register a session as active.
# Creates a file in .orchestrator/active-sessions/ named by SID.
# Usage: register_active_session <project_root> <session_id>
register_active_session() {
  local root="$1"
  local sid="$2"
  local active_dir="$root/$ORC_DIR/active-sessions"
  mkdir -p "$active_dir"
  echo "$$" > "$active_dir/$sid"
}

# Deregister a session (called on abort/finish).
# Usage: deregister_active_session <project_root> <session_id>
deregister_active_session() {
  local root="$1"
  local sid="$2"
  rm -f "$root/$ORC_DIR/active-sessions/$sid" 2>/dev/null || true
}

# List all active session IDs.
# Usage: list_active_sessions <project_root>
list_active_sessions() {
  local root="$1"
  local active_dir="$root/$ORC_DIR/active-sessions"
  [ ! -d "$active_dir" ] && return
  for f in "$active_dir"/session-*; do
    [ -f "$f" ] || continue
    basename "$f"
  done
}

# ---------------------------------------------------------------------------
# Git worktree helpers
# ---------------------------------------------------------------------------

# Get the session branch name for a given session ID.
# Format: orc/<session_id>
# Usage: get_session_branch <session_id>
get_session_branch() {
  local sid="$1"
  printf 'orc/%s' "$sid"
}

# Create a git worktree for a session.
# Creates branch orc/<session_id> from current HEAD and sets up worktree.
# Usage: create_session_worktree <session_id> <project_root>
# Returns: worktree path on stdout, 0 on success, 1 on failure
create_session_worktree() {
  local sid="$1"
  local project_root="$2"
  local branch
  branch=$(get_session_branch "$sid")
  local worktree_dir="$project_root/$ORC_DIR/worktrees/$sid"

  # Check if git is available and we're in a repo
  if ! git -C "$project_root" rev-parse --is-inside-work-tree &>/dev/null; then
    orc_warn "Not a git repository — skipping worktree creation"
    printf '%s' "$project_root"
    return 0
  fi

  # If worktree already exists, just return its path
  if [ -d "$worktree_dir" ]; then
    orc_info "Worktree already exists: $worktree_dir"
    printf '%s' "$worktree_dir"
    return 0
  fi

  # Create the branch from current HEAD (if it doesn't exist)
  if ! git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git -C "$project_root" branch "$branch" HEAD 2>/dev/null || {
      orc_warn "Failed to create branch $branch — using project root"
      printf '%s' "$project_root"
      return 0
    }
  fi

  # Create the worktree
  mkdir -p "$(dirname "$worktree_dir")"
  if git -C "$project_root" worktree add "$worktree_dir" "$branch" 2>/dev/null; then
    orc_ok "Created worktree: $worktree_dir (branch: $branch)"
    printf '%s' "$worktree_dir"
    return 0
  else
    orc_warn "Failed to create worktree — using project root"
    printf '%s' "$project_root"
    return 0
  fi
}

# Remove a git worktree for a session.
# Usage: cleanup_session_worktree <session_id> <project_root>
cleanup_session_worktree() {
  local sid="$1"
  local project_root="$2"
  local worktree_dir="$project_root/$ORC_DIR/worktrees/$sid"

  if [ ! -d "$worktree_dir" ]; then
    return 0
  fi

  if git -C "$project_root" rev-parse --is-inside-work-tree &>/dev/null; then
    git -C "$project_root" worktree remove "$worktree_dir" --force 2>/dev/null || {
      orc_warn "git worktree remove failed — removing directory manually"
      rm -rf "$worktree_dir" 2>/dev/null || true
      # Prune stale worktree entries
      git -C "$project_root" worktree prune 2>/dev/null || true
    }
  else
    rm -rf "$worktree_dir" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Git commit/push helpers for sessions
# ---------------------------------------------------------------------------

# Commit all changes in a worktree/directory with a session-scoped message.
# Usage: session_commit <workdir> <message>
# Returns: 0 if committed (or nothing to commit), 1 on error
session_commit() {
  local workdir="$1"
  local message="$2"

  if ! git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
    orc_warn "Not a git repository — skipping commit"
    return 0
  fi

  # Check if there are any changes to commit
  if git -C "$workdir" diff --quiet HEAD 2>/dev/null && \
     git -C "$workdir" diff --staged --quiet 2>/dev/null && \
     [ -z "$(git -C "$workdir" ls-files --others --exclude-standard 2>/dev/null)" ]; then
    orc_info "Nothing to commit"
    return 0
  fi

  # Stage all changes (including untracked)
  git -C "$workdir" add -A 2>/dev/null || {
    orc_error "git add failed"
    return 1
  }

  # Commit
  git -C "$workdir" commit -m "$message" --no-verify 2>/dev/null || {
    # Could be "nothing to commit" after add — not an error
    orc_info "git commit returned non-zero (possibly nothing staged)"
    return 0
  }

  orc_ok "Committed: $message"
  return 0
}

# Push the session branch to remote.
# Usage: session_push <workdir> [remote]
# Returns: 0 on success, 1 on failure
session_push() {
  local workdir="$1"
  local remote="${2:-origin}"

  if ! git -C "$workdir" rev-parse --is-inside-work-tree &>/dev/null; then
    orc_warn "Not a git repository — skipping push"
    return 0
  fi

  local branch
  branch=$(git -C "$workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [ -z "$branch" ]; then
    orc_error "Cannot determine current branch"
    return 1
  fi

  # Check if remote exists
  if ! git -C "$workdir" remote get-url "$remote" &>/dev/null; then
    orc_warn "Remote '$remote' not found — skipping push"
    return 0
  fi

  git -C "$workdir" push "$remote" "$branch" 2>/dev/null || {
    # Try with --set-upstream for new branches
    git -C "$workdir" push -u "$remote" "$branch" 2>/dev/null || {
      orc_error "git push failed"
      return 1
    }
  }

  orc_ok "Pushed branch $branch to $remote"
  return 0
}

# ---------------------------------------------------------------------------
# Dependency resolution (simple linear DAG)
# ---------------------------------------------------------------------------

# Get tasks from plan in dependency order
# Returns run_ids in order they should be executed
# Usage: get_execution_order <plan_file>
get_execution_order() {
  local plan="$1"

  # Tasks without depends_on come first, then those with dependencies
  # For MVP this is a simple topological sort via jq
  jq -r '
    # First: tasks with no dependencies
    (.tasks | map(select(.depends_on == null or (.depends_on | length) == 0)) | .[].run_id),
    # Then: tasks with dependencies (in order they appear)
    (.tasks | map(select(.depends_on != null and (.depends_on | length) > 0)) | .[].run_id)
  ' "$plan"
}

# Check if all dependencies of a task are satisfied
# Usage: dependencies_met <plan_file> <run_id> <session_dir>
dependencies_met() {
  local plan="$1"
  local run_id="$2"
  local session_dir="$3"

  local deps
  deps=$(jq -r --arg rid "$run_id" \
    '.tasks[] | select(.run_id == $rid) | .depends_on[]? // empty' "$plan")

  if [ -z "$deps" ]; then
    return 0  # No dependencies
  fi

  local dep
  for dep in $deps; do
    local dep_dir="$session_dir/runs/$dep"
    if [ ! -f "$dep_dir/DONE" ] && [ ! -f "$dep_dir/.done_time" ]; then
      return 1  # Dependency not yet done
    fi
  done

  return 0  # All deps satisfied
}
