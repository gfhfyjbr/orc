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
VALID_ROLES='["researcher","explorer","reviewer","summarizer","verifier"]'

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
log_event() {
  local session_dir="$1"
  local level="$2"
  local msg="$3"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","level":"%s","msg":"%s"}\n' "$ts" "$level" "$msg" \
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

# Generate next run ID for a session
# Usage: generate_run_id <session_dir>
generate_run_id() {
  local session_dir="$1"
  local runs_dir="$session_dir/runs"
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

  printf 'run-%03d' "$((max_num + 1))"
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# Get the project root (where .orchestrator/ lives)
# Walks up from CWD looking for .orchestrator/ or .git/
get_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -d "$dir/.orchestrator" ] || [ -d "$dir/.git" ]; then
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

# Check if a run is complete (DONE marker exists)
# Usage: run_is_done <run_dir>
run_is_done() {
  [ -f "$1/DONE" ]
}

# Check if a run has failed (FAILED marker exists)
# Usage: run_is_failed <run_dir>
run_is_failed() {
  [ -f "$1/FAILED" ]
}

# Check if a run is finished (either DONE or FAILED)
# Usage: run_is_finished <run_dir>
run_is_finished() {
  [ -f "$1/DONE" ] || [ -f "$1/FAILED" ]
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
    if [ -f "$run_dir/DONE" ]; then
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

# ---------------------------------------------------------------------------
# Spec generation
# ---------------------------------------------------------------------------

# Generate spec.md for a subagent run from plan task data
# Usage: generate_spec <run_dir> <session_id> <run_id> <role> <goal> <inputs_json> <deliverables_json>
generate_spec() {
  local run_dir="$1"
  local session_id="$2"
  local run_id="$3"
  local role="$4"
  local goal="$5"
  local inputs_json="$6"
  local deliverables_json="$7"
  local workspace
  workspace=$(get_project_root)

  # Load role-specific profile from templates
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local template_dir="$script_dir/../templates/specs"
  local profile=""

  if [ -f "$template_dir/${role}.md" ]; then
    profile=$(cat "$template_dir/${role}.md")
  else
    profile="You are a $role subagent. Work strictly within your assigned scope."
  fi

  # Format inputs as list
  local inputs_list
  inputs_list=$(echo "$inputs_json" | jq -r '.[]? // empty' 2>/dev/null | sed 's/^/- /')
  [ -z "$inputs_list" ] && inputs_list="- (no specific inputs)"

  # Format deliverables as numbered list
  local deliverables_list
  deliverables_list=$(echo "$deliverables_json" | jq -r '.[]? // empty' 2>/dev/null | nl -ba | sed 's/^[[:space:]]*//')
  [ -z "$deliverables_list" ] && deliverables_list="1. Result summary"

  cat > "$run_dir/spec.md" <<EOF
# Subagent Spec

- run_id: $run_id
- role: $role
- session: $session_id
- workspace: $workspace

## Agent Profile

$profile

## Goal

$goal

## Input Context

$inputs_list

## Constraints

- Work strictly within the scope defined above.
- Do not attempt to answer the user directly — your output is for the main agent.
- Do not modify code outside your assigned scope.
- Record results in the specified output files.

## Deliverables

$deliverables_list

## Output Files

Write files in this exact order:
1. \`$run_dir/status.json\` — update periodically as you work (optional)
2. \`$run_dir/result.json\` — machine-readable structured result
3. \`$run_dir/handoff.md\` — human-readable summary for main agent
4. \`$run_dir/DONE\` — final marker (create ONLY after all other files are written)

### DONE marker format:
\`\`\`json
{
  "run_id": "$run_id",
  "role": "$role",
  "status": "completed",
  "files": ["result.json", "handoff.md"],
  "completed_at": "<ISO-8601 timestamp>"
}
\`\`\`

If you cannot complete the task, create \`$run_dir/FAILED\` instead of \`DONE\`:
\`\`\`json
{
  "run_id": "$run_id",
  "status": "failed",
  "reason": "<description of what went wrong>",
  "failed_at": "<ISO-8601 timestamp>"
}
\`\`\`
EOF
}

# ---------------------------------------------------------------------------
# Bootstrap prompt generation
# ---------------------------------------------------------------------------

# Generate the bootstrap prompt that will be sent to a subagent
# Usage: generate_bootstrap_prompt <run_dir>
generate_bootstrap_prompt() {
  local run_dir="$1"

  cat > "$run_dir/prompt.txt" <<EOF
Read the file \`$run_dir/spec.md\`.

Then:
1. Execute the task strictly within the spec's scope.
2. If appropriate, periodically update \`$run_dir/status.json\`.
3. When finished, write files in this exact order:
   - \`$run_dir/result.json\`
   - \`$run_dir/handoff.md\`
   - \`$run_dir/DONE\` (JSON with run_id, role, status, files, completed_at)
4. Do NOT write a final answer to the user. Write results for the main agent.
EOF
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
    if [ ! -f "$dep_dir/DONE" ]; then
      return 1  # Dependency not yet done
    fi
  done

  return 0  # All deps satisfied
}
