#!/usr/bin/env bash
# =============================================================================
# list-sessions.sh — Show all orchestration sessions and their status
# =============================================================================
# Usage: ./list-sessions.sh [workdir]
#
# Scans .orchestrator/sessions/ and displays:
#   - Session ID, tmux session name, status
#   - Run counts (done/failed/stuck/total)
#   - Whether tmux session is alive
#   - Whether watchdog/orchestrate are running
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

WORKDIR="${1:-$(get_project_root)}"
SESSIONS_DIR="$WORKDIR/$ORC_DIR/sessions"

if [ ! -d "$SESSIONS_DIR" ]; then
  orc_info "No sessions found. Run start-session.sh to create one."
  exit 0
fi

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

printf '\n'
printf '  %-28s %-18s %-10s %-8s %-22s %s\n' \
  "SESSION ID" "TMUX" "STATUS" "RUNS" "PROCESSES" "CREATED"
printf '  %s\n' "$(printf '%.0s─' {1..110})"

# ---------------------------------------------------------------------------
# Iterate sessions
# ---------------------------------------------------------------------------

session_count=0

for session_dir in "$SESSIONS_DIR"/session-*; do
  [ -d "$session_dir" ] || continue
  session_count=$((session_count + 1))

  sid=$(basename "$session_dir")

  # Read metadata
  tmux_name="?"
  status="?"
  created="?"

  if [ -f "$session_dir/session.json" ]; then
    tmux_name=$(jq -r '.session_name // "?"' "$session_dir/session.json" 2>/dev/null || echo "?")
    status=$(jq -r '.status // "?"' "$session_dir/session.json" 2>/dev/null || echo "?")
    created=$(jq -r '.created_at // "?"' "$session_dir/session.json" 2>/dev/null || echo "?")
    # Shorten timestamp
    created=$(echo "$created" | sed 's/T/ /' | sed 's/Z//')
  fi

  # Count runs
  total=0; done_count=0; failed_count=0; stuck_count=0
  for run_dir in "$session_dir"/runs/run-*; do
    [ -d "$run_dir" ] || continue
    total=$((total + 1))
    if [ -f "$run_dir/DONE" ]; then
      done_count=$((done_count + 1))
    elif [ -f "$run_dir/FAILED" ]; then
      failed_count=$((failed_count + 1))
    else
      stuck_count=$((stuck_count + 1))
    fi
  done

  runs_summary="${done_count}d/${failed_count}f/${stuck_count}s/${total}t"

  # Check tmux session alive
  tmux_alive="dead"
  if tmux has-session -t "$tmux_name" 2>/dev/null; then
    tmux_alive="alive"
  fi

  # Check processes
  procs=""
  if [ -f "$session_dir/.watchdog_pid" ]; then
    wpid=$(cat "$session_dir/.watchdog_pid")
    if kill -0 "$wpid" 2>/dev/null; then
      procs="wd:$wpid"
    fi
  fi
  if [ -f "$session_dir/.orchestrate_pid" ]; then
    opid=$(cat "$session_dir/.orchestrate_pid")
    if kill -0 "$opid" 2>/dev/null; then
      [ -n "$procs" ] && procs="$procs "
      procs="${procs}orc:$opid"
    fi
  fi
  [ -z "$procs" ] && procs="-"

  # Color status
  case "$status" in
    active)  status_display="${GREEN}active${NC}" ;;
    aborted) status_display="${RED}aborted${NC}" ;;
    *)       status_display="$status" ;;
  esac

  # Color tmux
  case "$tmux_alive" in
    alive) tmux_display="${tmux_name} ${GREEN}*${NC}" ;;
    dead)  tmux_display="${tmux_name} ${RED}x${NC}" ;;
  esac

  printf "  %-28s %-18b %-10b %-8s %-22s %s\n" \
    "$sid" "$tmux_display" "$status_display" "$runs_summary" "$procs" "$created"

  # Show stuck runs if any
  if [ "$stuck_count" -gt 0 ]; then
    for run_dir in "$session_dir"/runs/run-*; do
      [ -d "$run_dir" ] || continue
      [ -f "$run_dir/DONE" ] && continue
      [ -f "$run_dir/FAILED" ] && continue
      rid=$(basename "$run_dir")
      role=$(jq -r '.role // "?"' "$run_dir/.agent_meta.json" 2>/dev/null || echo "?")
      printf "    ${YELLOW}^ stuck: %s (%s)${NC}\n" "$rid" "$role"
    done
  fi
done

printf '\n'

if [ "$session_count" -eq 0 ]; then
  orc_info "No sessions found."
else
  # Count active tmux sessions
  active_tmux=0
  for session_dir in "$SESSIONS_DIR"/session-*; do
    [ -d "$session_dir" ] || continue
    if [ -f "$session_dir/session.json" ]; then
      tn=$(jq -r '.session_name // ""' "$session_dir/session.json" 2>/dev/null || echo "")
      if [ -n "$tn" ] && tmux has-session -t "$tn" 2>/dev/null; then
        active_tmux=$((active_tmux + 1))
      fi
    fi
  done
  printf "  Total: %d sessions, %d with active tmux\n\n" "$session_count" "$active_tmux"
fi
