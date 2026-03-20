#!/usr/bin/env bash
# =============================================================================
# orc — unified CLI for opencode-orc orchestration
# =============================================================================
# Usage:
#   orc start              Start a new session (tmux + opencode + git worktree)
#   orc list               Show all sessions
#   orc status <sid>       Detailed status of a session
#   orc attach [sid]       Attach to session's tmux (latest if no sid)
#   orc logs [sid]         Tail event log (latest if no sid)
#   orc commit [message]   Commit changes in session branch
#   orc push [remote]      Push session branch to remote
#   orc finish [message]   Commit + push + finalize session
#   orc abort <sid>        Kill a session
#   orc cancel <sid> <rid> Cancel a single run
#   orc recover <sid>      Diagnose and recover a session
#   orc help               Show this help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
ORC_DIR=".orchestrator"

# Source lib for helpers
source "$SCRIPT_DIR/lib.sh"

# ---------------------------------------------------------------------------
# Resolve latest session
# ---------------------------------------------------------------------------
resolve_latest_sid() {
  local root
  root=$(get_project_root)

  # Priority 1: Explicit env var
  if [ -n "${ORC_SESSION_ID:-}" ]; then
    printf '%s' "$ORC_SESSION_ID"
    return 0
  fi

  # Priority 2: Most recent active session from active-sessions/
  local active_dir="$root/$ORC_DIR/active-sessions"
  if [ -d "$active_dir" ]; then
    local newest=""
    for f in "$active_dir"/session-*; do
      [ -f "$f" ] || continue
      local candidate
      candidate=$(basename "$f")
      # Among active sessions, pick the most recently registered (lexicographic = chronological)
      if [ -z "$newest" ] || [[ "$candidate" > "$newest" ]]; then
        newest="$candidate"
      fi
    done
    if [ -n "$newest" ]; then
      printf '%s' "$newest"
      return 0
    fi
  fi

  # Priority 3: Fallback to latest-session file (backward compat)
  local latest_file="$root/$ORC_DIR/latest-session"
  if [ -f "$latest_file" ]; then
    cat "$latest_file"
    return 0
  fi

  # Priority 4: Most recent session dir
  local latest
  latest=$(ls -1d "$root/$ORC_DIR/sessions"/session-* 2>/dev/null | sort -r | head -1)
  if [ -n "$latest" ]; then
    basename "$latest"
    return 0
  fi

  orc_error "No sessions found. Run: orc start"
  return 1
}

# Require session_id: use argument or latest
require_sid() {
  if [ -n "${1:-}" ]; then
    echo "$1"
  else
    resolve_latest_sid
  fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_start() {
  local session_name="${1:-}"

  # Start tmux session
  local output
  if [ -n "$session_name" ]; then
    output=$("$SCRIPT_DIR/start-session.sh" "$session_name")
  else
    output=$("$SCRIPT_DIR/start-session.sh")
  fi

  # Last line of output is the session_id
  local sid
  sid=$(echo "$output" | tail -1)
  local sdir
  sdir=$(get_session_dir "$sid")

  # Read tmux session name from session.json
  local tmux_name
  tmux_name=$(jq -r '.session_name' "$sdir/session.json" 2>/dev/null || echo "?")

  orc_ok "Session started!"
  echo ""
  echo "  Session ID:  $sid"
  echo "  tmux:        $tmux_name"
  echo ""
  echo "  Attach:      orc attach"
  echo "  Status:      orc status"
  echo "  List all:    orc list"
  echo "  Abort:       orc abort $sid"
  echo ""

  # Attach immediately
  orc_info "Attaching to tmux session..."
  tmux attach -t "$tmux_name"
}

cmd_list() {
  "$SCRIPT_DIR/list-sessions.sh"
}

cmd_status() {
  local sid
  sid=$(require_sid "${1:-}")
  "$SCRIPT_DIR/recover-session.sh" "$sid"
}

cmd_attach() {
  local sid
  sid=$(require_sid "${1:-}")
  local tmux_name
  tmux_name=$(resolve_session_name "$sid")

  if ! tmux has-session -t "$tmux_name" 2>/dev/null; then
    orc_error "tmux session '$tmux_name' is not running"
    exit 1
  fi

  tmux attach -t "$tmux_name"
}

cmd_logs() {
  local sid
  sid=$(require_sid "${1:-}")
  local sdir
  sdir=$(get_session_dir "$sid")

  local log_file="$sdir/event-log.jsonl"

  if [ ! -f "$log_file" ]; then
    orc_error "No event log found for $sid"
    exit 1
  fi

  orc_info "Tailing event log for $sid (Ctrl+C to stop)"
  echo ""

  # Pretty-print existing + follow
  tail -f "$log_file" | while IFS= read -r line; do
    local ts level msg
    ts=$(echo "$line" | jq -r '.ts // "?"' 2>/dev/null || echo "?")
    level=$(echo "$line" | jq -r '.level // "?"' 2>/dev/null || echo "?")
    msg=$(echo "$line" | jq -r '.msg // "?"' 2>/dev/null || echo "?")

    case "$level" in
      error) printf "${RED}[%s] %s${NC}\n" "$ts" "$msg" ;;
      warn)  printf "${YELLOW}[%s] %s${NC}\n" "$ts" "$msg" ;;
      info)  printf "${BLUE}[%s] %s${NC}\n" "$ts" "$msg" ;;
      *)     printf "[%s] %s: %s\n" "$ts" "$level" "$msg" ;;
    esac
  done
}

cmd_abort() {
  local sid
  sid=$(require_sid "${1:-}")

  echo ""
  orc_warn "About to abort session: $sid"
  read -rp "  Are you sure? [y/N] " confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *)
      orc_info "Aborted."
      exit 0
      ;;
  esac

  "$SCRIPT_DIR/abort-session.sh" "$sid"
}

cmd_cancel() {
  if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    orc_error "Usage: orc cancel <session_id> <run_id>"
    exit 1
  fi
  "$SCRIPT_DIR/cancel-agent.sh" "$1" "$2"
}

cmd_recover() {
  local sid
  sid=$(require_sid "${1:-}")
  "$SCRIPT_DIR/recover-session.sh" "$sid"
}

# ---------------------------------------------------------------------------
# Git commands: commit, push, finish
# ---------------------------------------------------------------------------

cmd_commit() {
  local sid
  sid=$(require_sid "")
  local sdir
  sdir=$(get_session_dir "$sid")
  local workdir
  workdir=$(jq -r '.worktree_path // .workdir // "."' "$sdir/session.json" 2>/dev/null || pwd)
  local message="${1:-orc: manual commit for $sid}"

  session_commit "$workdir" "$message"
}

cmd_push() {
  local sid
  sid=$(require_sid "")
  local sdir
  sdir=$(get_session_dir "$sid")
  local workdir
  workdir=$(jq -r '.worktree_path // .workdir // "."' "$sdir/session.json" 2>/dev/null || pwd)
  local remote="${1:-origin}"

  session_push "$workdir" "$remote"
}

cmd_finish() {
  local sid
  sid=$(require_sid "")
  local sdir
  sdir=$(get_session_dir "$sid")
  local workdir
  workdir=$(jq -r '.worktree_path // .workdir // "."' "$sdir/session.json" 2>/dev/null || pwd)
  local project_root
  project_root=$(jq -r '.workdir // "."' "$sdir/session.json" 2>/dev/null || pwd)
  local message="${1:-orc: finish session $sid}"

  orc_info "Finishing session $sid..."

  # 1. Commit any remaining changes
  session_commit "$workdir" "$message"

  # 2. Push to remote
  session_push "$workdir"

  # 3. Update session status
  if [ -f "$sdir/session.json" ]; then
    local tmp
    tmp=$(mktemp)
    jq '.status = "finished" | .finished_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
      "$sdir/session.json" > "$tmp" && mv "$tmp" "$sdir/session.json"
  fi

  # 4. Deregister active session
  deregister_active_session "$project_root" "$sid"

  # 5. Clean up worktree (keep branch)
  cleanup_session_worktree "$sid" "$project_root"

  log_event "$sdir" "info" "session $sid finished"
  orc_ok "Session $sid finished. Changes committed and pushed. Branch kept for history."
}

cmd_help() {
  cat <<'EOF'

  orc — opencode-orc orchestration CLI

  COMMANDS:
    start [name]           Start new session. Auto-attaches to tmux.
                           Creates git worktree for isolation.

    list                   Show all sessions with status overview.

    status [sid]           Detailed status of a session (runs, processes, events).
                           Uses latest session if sid omitted.

    attach [sid]           Attach to session's tmux.
                           Uses latest session if sid omitted.

    logs [sid]             Tail the event log (pretty-printed).
                           Uses latest session if sid omitted.

    commit [message]       Commit all current changes in session branch.
                           Default message: "orc: manual commit for <sid>"

    push [remote]          Push session branch to remote (default: origin).

    finish [message]       Commit + push + finalize session.
                           Cleans up worktree, keeps branch for history.

    abort [sid]            Kill session: watchdog, tmux, all runs.
                           Cleans up worktree, keeps branch. Asks for confirmation.

    cancel <sid> <rid>     Cancel a single subagent run.

    recover [sid]          Diagnose session state, show stuck runs, suggest fixes.

    help                   Show this help.

  EXAMPLES:
    orc start              # start session, auto-attach
    orc list               # see all sessions
    orc attach             # re-attach to latest session
    orc commit "my changes" # commit changes in session branch
    orc push               # push session branch
    orc finish "done"      # commit + push + finalize
    orc logs               # watch event stream
    orc abort session-20260318-232850
    orc cancel session-20260318-232850 run-001

EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-help}"
shift 2>/dev/null || true

case "$CMD" in
  start)   cmd_start "$@" ;;
  list|ls) cmd_list "$@" ;;
  status)  cmd_status "$@" ;;
  attach)  cmd_attach "$@" ;;
  logs)    cmd_logs "$@" ;;
  commit)  cmd_commit "$@" ;;
  push)    cmd_push "$@" ;;
  finish)  cmd_finish "$@" ;;
  abort)   cmd_abort "$@" ;;
  cancel)  cmd_cancel "$@" ;;
  recover) cmd_recover "$@" ;;
  help|-h|--help) cmd_help ;;
  *)
    orc_error "Unknown command: $CMD"
    cmd_help
    exit 1
    ;;
esac
