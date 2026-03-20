```
                                  ██████╗ ██████╗  ██████╗
                                 ██╔═══██╗██╔══██╗██╔════╝
                                 ██║   ██║██████╔╝██║
                                 ██║   ██║██╔══██╗██║
                                 ╚██████╔╝██║  ██║╚██████╗
                                  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝
```

<div align="center">

**Tmux-based multi-agent orchestration for [OpenCode](https://opencode.ai)**

Decompose complex tasks across specialized AI agents — all visible in your terminal.

<!-- Badges -->
[![Shell](https://img.shields.io/badge/shell-bash-blue)](#prerequisites)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey)](#prerequisites)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

</div>

---

## Overview

**orc** is an external orchestration layer for [OpenCode](https://opencode.ai). It does **not** modify OpenCode itself — it launches multiple OpenCode instances inside tmux panes, coordinates them via shell scripts, and connects them through file-based communication and `tmux send-keys`.

One **orchestrator** (main agent) decomposes your task and spawns specialized **subagents**. Each subagent is a separate OpenCode instance running in its own tmux pane. Results flow back to the orchestrator, which synthesizes a final answer.

### Key Features

- **Multi-agent orchestration** with 8 specialized roles (explorer, researcher, coder, reviewer, verifier, summarizer, namer, orchestrator)
- **Tmux-based visual workspace** — 3x2 grid layout, every agent visible in real time
- **Git worktree isolation** — each session gets its own branch and working directory
- **Auto pane reuse** — completed agent panes are recycled via `/new`, skipping 5-45s startup
- **Watchdog health monitoring** — automatic timeout detection, dead pane cleanup, silence alerts
- **Auto-commit and push** on every agent completion
- **Conventional Commits branch naming** — a dedicated `namer` agent generates `feat/...`, `fix/...` branch names
- **Pure bash + shell** — no Python, Ruby, or Node.js runtime dependencies beyond OpenCode itself

---

## Architecture

```
                           ┌──────────────────────────────────────────────┐
                           │              tmux session (orc-N)            │
                           │                                              │
 ┌──────────┐  orc start   │  ┌─────────────┐  spawn   ┌──────────────┐  │
 │          │─────────────▶│  │ Orchestrator │────────▶ │  Explorer    │  │
 │   User   │              │  │  (main pane) │  spawn   ├──────────────┤  │
 │          │◀─────────────│  │              │────────▶ │  Researcher  │  │
 └──────────┘  orc finish  │  │              │  spawn   ├──────────────┤  │
                           │  │              │────────▶ │  Coder       │  │
                           │  │              │  spawn   ├──────────────┤  │
                           │  │   ◀──done──  │◀──────── │  Reviewer    │  │
                           │  │              │          ├──────────────┤  │
                           │  │  synthesize  │          │  Verifier    │  │
                           │  │  & respond   │          ├──────────────┤  │
                           │  └─────────────┘          │  Summarizer  │  │
                           │                            └──────────────┘  │
                           │                                              │
                           │  ┌─────────────────────────────────────────┐ │
                           │  │  Watchdog (background)                  │ │
                           │  │  - timeout detection                    │ │
                           │  │  - dead pane cleanup                    │ │
                           │  │  - disk space monitoring                │ │
                           │  └─────────────────────────────────────────┘ │
                           └──────────────────────────────────────────────┘
                                              │
                                     ┌────────┴────────┐
                                     │  .orchestrator/  │
                                     │  sessions/       │
                                     │  worktrees/      │
                                     │  active-sessions/│
                                     └─────────────────┘
```

**Flow:**
1. `orc start` creates a tmux session, git worktree, and launches OpenCode as the orchestrator
2. The orchestrator decomposes the user's task and spawns subagents via `orc_agent spawn`
3. Each subagent runs in its own pane with a role-specific prompt and permissions
4. Subagents report results via `orc_agent done`, which writes to a file and notifies the orchestrator
5. The orchestrator reads results, synthesizes, and delivers the final answer
6. `orc finish` commits, pushes, and cleans up the session

---

## Prerequisites

| Dependency | Version | macOS | Ubuntu/Debian |
|------------|---------|-------|---------------|
| **bash** | >= 4.0 | Built-in (or `brew install bash`) | Built-in |
| **tmux** | >= 3.0 | `brew install tmux` | `sudo apt install tmux` |
| **jq** | >= 1.6 | `brew install jq` | `sudo apt install jq` |
| **opencode** | Latest | `curl -fsSL https://opencode.ai/install \| bash` | `curl -fsSL https://opencode.ai/install \| bash` |
| **git** | >= 2.20 | `brew install git` | `sudo apt install git` |

---

## Installation

```bash
git clone https://github.com/your-username/orc.git
cd orc
./install.sh
```

### What `install.sh` does

1. **Preflight checks** — verifies all dependencies (tmux, jq, opencode, git) are installed
2. **Installs binaries** — copies `orc` and `orc_agent` to `~/.local/share/orc/` and creates symlinks in `~/.local/bin/`
3. **Installs OpenCode agents** — copies role-specific agent definitions (`orc-orchestrator.md`, `orc-coder.md`, etc.) to `~/.config/opencode/agents/`
4. **Configures permissions** — updates `opencode.json` with tool permissions for orc tools
5. **Final verification** — checks that `orc` and `orc_agent` are accessible in your PATH

> If `~/.local/bin` is not in your PATH, add this to your shell profile:
> ```bash
> export PATH="$HOME/.local/bin:$PATH"
> ```

To uninstall:

```bash
./install.sh --uninstall
```

---

## Quick Start

### 1. Navigate to your project

```bash
cd /path/to/your/project
```

### 2. Start a session

```bash
orc start
```

This creates a new tmux session with a git worktree, launches OpenCode as the orchestrator, and attaches you to the session.

### 3. Type your task

In the orchestrator pane (leftmost), type your request:

```
Refactor the authentication module to use JWT tokens instead of session cookies
```

### 4. Watch agents work

The orchestrator will decompose the task and spawn specialized agents. You'll see them appear in the grid to the right — explorers reading code, coders making changes, reviewers checking quality.

### 5. Finish the session

Once the orchestrator delivers the final result:

```bash
# From outside tmux (or detach first with Ctrl+B, D):
orc finish "Refactored auth to use JWT"
```

This commits all changes, pushes the branch, and cleans up the worktree.

---

## CLI Reference

### `orc` — Session Management

| Command | Description |
|---------|-------------|
| `orc start [name]` | Start a new session. Creates git worktree, launches tmux, auto-attaches. |
| `orc list` | Show all sessions with status overview. |
| `orc status [sid]` | Detailed status: runs, processes, events, recommendations. Defaults to latest session. |
| `orc attach [sid]` | Attach to a session's tmux. Defaults to latest session. |
| `orc logs [sid]` | Tail the event log (pretty-printed JSONL). Defaults to latest session. |
| `orc commit [message]` | Commit all changes in the session's worktree. Default message auto-generated. |
| `orc push [remote]` | Push the session branch to remote (default: `origin`). |
| `orc finish [message]` | Commit + push + finalize session. Cleans up worktree, keeps branch. |
| `orc abort [sid]` | Kill session: stops watchdog, kills tmux, marks runs as cancelled. Asks for confirmation. |
| `orc cancel <sid> <rid>` | Cancel a single subagent run. |
| `orc recover [sid]` | Diagnose session state, show stuck runs, suggest fixes. |
| `orc help` | Show help. |

### `orc_agent` — Agent Orchestration

| Command | Description |
|---------|-------------|
| `orc_agent spawn <role> <goal>` | Spawn a subagent in a grid pane. Auto-reuses completed panes when available. |
| `orc_agent spawn-window <role> <goal>` | Spawn a subagent in a separate tmux window (fallback when grid is full). |
| `orc_agent reassign [run_id] <role> <goal>` | Explicitly reuse a completed agent's pane with a new role and task. Faster than spawn. |
| `orc_agent done <run_id> <summary>` | Subagent reports completion. Writes result to file and notifies orchestrator. |
| `orc_agent reply <pane_id> <message>` | Send a raw message to any tmux pane. |
| `orc_agent ping <run_id>` | Check agent health. Exit codes: 0=ok, 2=dead, 3=timed-out. |
| `orc_agent retry <run_id> [new_goal]` | Reset conversation with `/new` and resend the task. Optionally provide a new goal. |
| `orc_agent check-all` | Scan all agents, notify orchestrator of dead/timed-out runs. |
| `orc_agent list` | Show all agents with position, alive status, done status, reuse readiness, and elapsed time. |
| `orc_agent name [get\|set] [name]` | Get or set the session branch name. Set requires conventional commits format. |

---

## Agent Roles

| Role | Purpose | Can Edit | Can Write | Can Bash | Special |
|------|---------|:--------:|:---------:|:--------:|---------|
| **orchestrator** | Decomposes tasks, spawns agents, synthesizes results | No | No | Yes | Never does work itself; delegates everything |
| **explorer** | Studies codebases, maps dependencies, collects facts | No | No | Yes | Read-only; reports structure and patterns |
| **researcher** | Gathers external facts, compares options, recommends | No | No | Yes | Searches for information; cites sources |
| **coder** | Writes, modifies, and refactors code | Yes | Yes | Yes | The **only** role allowed to modify source files |
| **reviewer** | Finds bugs, risks, contradictions; reviews diffs | No | No | Yes | Always runs `git diff`; gives verdict |
| **verifier** | Runs tests, validates implementations match specs | No | No | Yes | Executes build/test commands; reports pass/fail |
| **summarizer** | Aggregates multiple sources into concise summaries | No | No | Yes | Never invents content; preserves nuance |
| **namer** | Generates conventional branch name from task context | No | No | Limited | Only runs `orc_agent name set`; minimal permissions |

### Role Details

**Orchestrator** — The brain of the system. Receives the user's task, decides which agents to spawn, monitors their progress, and combines their results into a final answer. It has `edit: deny` and `write: false` permissions — it delegates all work.

**Explorer** — Your eyes into the codebase. Reads files, maps project structure, identifies patterns, and reports findings. Useful for understanding unfamiliar code before making changes. Cannot modify anything.

**Researcher** — Gathers external knowledge. Searches for facts, compares alternatives, evaluates trade-offs, and provides recommendations with confidence levels. Useful for technology decisions and architectural questions.

**Coder** — The only agent that can modify source files. Reads context first, makes focused changes, runs build/test commands to verify, and reports what was changed. Follows the project's existing coding conventions.

**Reviewer** — The critic. Examines proposals and code changes for problems. Always runs `git diff`, checks for security issues, edge cases, and feasibility. Provides severity-rated issues and a clear verdict (approve/request-changes/reject).

**Verifier** — The tester. Runs the project's test suite, checks each requirement against the implementation, and provides evidence-based pass/fail verdicts. Does not fix issues — only identifies them.

**Summarizer** — The aggregator. Takes multiple information sources and distills them into concise, actionable summaries. Preserves disagreements and nuance without adding opinions.

**Namer** — A utility agent that analyzes the user's task and generates a conventional commits branch name (e.g., `feat/add-user-auth`). Spawned automatically at the start of each session.

---

## Session Lifecycle

```
orc start ─── Create worktree ─── Launch tmux ─── Start orchestrator
                  │                                      │
                  │                              Spawn namer agent
                  │                              (sets branch name)
                  │                                      │
                  │                              User types task
                  │                                      │
                  │                              Orchestrator decomposes
                  │                                      │
                  │                              Spawn subagents ──┐
                  │                                                │
                  │                              Agents work in    │
                  │                              parallel panes    │
                  │                                                │
                  │                              Results flow back ◀┘
                  │                                      │
                  │                              Orchestrator synthesizes
                  │                                      │
                  ▼                                      ▼
              orc finish ─── Commit ─── Push ─── Clean up worktree
```

### Git Worktree Isolation

Each session creates a dedicated git branch (`orc/<session-id>`) and worktree under `.orchestrator/worktrees/`. This means:

- All agent changes happen on an isolated branch — your main branch is untouched
- Multiple sessions can run concurrently without conflicts
- After `orc finish`, the branch is pushed and the worktree is removed, but the branch persists for history

### Branch Naming

A `namer` agent is spawned automatically at the start of each session. It analyzes the user's task and sets a conventional commits branch name:

```
orc/feat/add-user-auth
orc/fix/race-condition-in-watchdog
orc/refactor/split-agent-lifecycle
```

You can check or manually set the branch name:

```bash
orc_agent name get                    # Show current name
orc_agent name set feat/my-feature    # Set manually
```

### Auto-commit

Every time an agent reports `done`, orc automatically:
1. Stages all changes in the worktree (`git add -A`)
2. Commits with a descriptive message: `orc: [coder] Refactor auth module to use JWT`
3. Pushes to the remote

---

## Grid Layout

The tmux workspace uses a **3-column x 2-row grid** for subagent panes, with the orchestrator in a fixed left pane.

```
┌─────────────────┬───────────────┬───────────────┬───────────────┐
│                  │               │               │               │
│                  │  Agent 1      │  Agent 3      │  Agent 5      │
│  Orchestrator    │  (c0r0)       │  (c1r0)       │  (c2r0)       │
│  (main pane)     │               │               │               │
│                  ├───────────────┼───────────────┼───────────────┤
│   25% width      │               │               │               │
│                  │  Agent 2      │  Agent 4      │  Agent 6      │
│                  │  (c0r1)       │  (c1r1)       │  (c2r1)       │
│                  │               │               │               │
└─────────────────┴───────────────┴───────────────┴───────────────┘
```

### Layout Rules

- **Maximum 6 grid panes** (3 columns x 2 rows). Beyond that, agents fall back to separate tmux windows.
- **Minimum pane dimensions**: 55 characters wide, 12 rows tall. If the terminal is too small, spawn falls back to a separate window.
- **Auto-equalization**: after each spawn, the grid is rebalanced for even distribution.
- **Orchestrator pane**: always 25% of terminal width (minimum 40 columns), never used for workers.

### Pane Reuse

When a subagent completes, its pane is marked as `READY` for reuse. The next `spawn` call will:

1. Find a completed agent pane that's still alive
2. Send `/new` to reset the OpenCode conversation
3. If the new role differs from the old one, restart OpenCode with the correct `--agent` flag
4. Send the new task prompt

This skips the 5-45 second OpenCode startup time. Disable with `ORC_NO_REUSE=1`.

---

## Configuration

### `opencode.json`

The project-level `opencode.json` configures OpenCode settings and plugins:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [
    "@0xsero/open-queue"
  ]
}
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ORC_AGENT_TIMEOUT` | `180` | Seconds before an agent is considered timed out |
| `ORC_NO_REUSE` | `0` | Set to `1` to disable automatic pane reuse |
| `ORC_IS_SUBAGENT` | (unset) | Automatically set to `1` for subagent panes. Prevents subagents from spawning other agents. |
| `ORC_SESSION_ID` | (auto) | Current session ID. Set automatically in tmux environment. |
| `ORC_INSTALL_DIR` | `~/.local/share/orc` | Installation directory (used by `install.sh`) |
| `ORC_BIN_DIR` | `~/.local/bin` | Symlink directory (used by `install.sh`) |

### Adjusting Timeouts

```bash
# Give agents 5 minutes instead of 3
ORC_AGENT_TIMEOUT=300 orc start

# Per-spawn override (via env)
ORC_AGENT_TIMEOUT=600 ./orc_agent spawn researcher "Deep analysis of codebase architecture"
```

---

## Directory Structure

```
your-project/
├── .orchestrator/                      # Runtime data (gitignored)
│   ├── active-sessions/                # Registry of running sessions
│   │   └── session-20260320-143012     # JSON: session_id, worktree_path, pid
│   ├── latest-session                  # Pointer to most recent session (backward compat)
│   ├── sessions/
│   │   └── session-20260320-143012/    # Per-session directory
│   │       ├── session.json            # Session metadata (id, name, worktree, branch, status)
│   │       ├── event-log.jsonl         # Structured event log
│   │       ├── watchdog.log            # Watchdog stdout/stderr
│   │       ├── .main_pane_id           # Tmux pane ID of the orchestrator
│   │       ├── .watchdog_pid           # PID of the watchdog process
│   │       ├── .layout_panes           # List of grid pane IDs
│   │       ├── .sendkeys_lock/         # mkdir-based lock for tmux send-keys
│   │       ├── .layout_lock/           # mkdir-based lock for grid operations
│   │       └── runs/
│   │           ├── run-001/            # Per-agent run directory
│   │           │   ├── .agent_meta.json   # Role, goal, pane_id, grid position, timestamps
│   │           │   ├── .pane_id           # Tmux pane ID
│   │           │   ├── .spawn_time        # Unix timestamp of spawn
│   │           │   ├── .done_time         # Unix timestamp of completion
│   │           │   ├── result.txt         # Full result text from orc_agent done
│   │           │   ├── handoff.md         # Detailed structured output (optional)
│   │           │   └── transcript.log     # Raw pane output via pipe-pane
│   │           ├── run-002/
│   │           └── ...
│   └── worktrees/
│       └── session-20260320-143012/    # Git worktree for this session
├── orc                                 # Session management CLI
├── orc_agent                           # Agent orchestration CLI
├── scripts/
│   ├── lib.sh                          # Shared functions (locking, logging, git helpers)
│   ├── start-session.sh                # Bootstrap tmux + worktree + orchestrator
│   ├── abort-session.sh                # Kill everything, mark runs cancelled
│   ├── recover-session.sh              # Diagnose stuck sessions
│   ├── watchdog.sh                     # Background health monitor
│   ├── list-sessions.sh                # List all sessions
│   ├── cancel-agent.sh                 # Cancel a single run
│   ├── spawn-agent.sh                  # Legacy spawn helper
│   ├── send-task.sh                    # Legacy task sending
│   ├── resume-main.sh                  # Resume orchestrator after subagent completion
│   └── request-review.sh              # Request review workflow
├── templates/
│   ├── prompts/                        # Prompt templates injected into agents
│   │   ├── main-agent-system.md        # System prompt for orchestrator
│   │   ├── subagent-generic.md         # Generic instructions for all subagents
│   │   ├── subagent-explorer.md        # Explorer-specific prompt
│   │   ├── subagent-researcher.md      # Researcher-specific prompt
│   │   ├── subagent-coder.md           # Coder-specific prompt
│   │   ├── subagent-reviewer.md        # Reviewer-specific prompt
│   │   ├── subagent-verifier.md        # Verifier-specific prompt
│   │   ├── subagent-summarizer.md      # Summarizer-specific prompt
│   │   └── subagent-namer.md           # Namer-specific prompt
│   └── specs/                          # Role profile templates
│       ├── explorer.md
│       ├── researcher.md
│       ├── coder.md
│       ├── reviewer.md
│       ├── verifier.md
│       └── summarizer.md
├── .opencode/
│   └── agents/                         # OpenCode native agent definitions
│       ├── orc-orchestrator.md         # Orchestrator agent (edit: deny)
│       ├── orc-explorer.md             # Explorer agent (edit: deny)
│       ├── orc-researcher.md           # Researcher agent (edit: deny)
│       ├── orc-coder.md                # Coder agent (edit: allow)
│       ├── orc-reviewer.md             # Reviewer agent (edit: deny)
│       ├── orc-verifier.md             # Verifier agent (edit: deny)
│       ├── orc-summarizer.md           # Summarizer agent (edit: deny)
│       └── orc-namer.md                # Namer agent (minimal permissions)
├── opencode.json                       # OpenCode project configuration
├── install.sh                          # Installer script
└── PLAN.md                             # Architecture design document
```

---

## How It Works

### Communication Model

orc uses a **hybrid communication model** combining tmux terminal automation with file-based result passing:

1. **Task delivery**: The orchestrator's prompt is assembled from role specs + generic instructions + the specific goal, then sent to the subagent's pane via `tmux send-keys -l` (literal mode, no key interpretation).

2. **Result reporting**: When a subagent calls `orc_agent done <run_id> <summary>`:
   - The full result is written to `runs/<run_id>/result.txt`
   - A truncated notification (max 200 chars) is sent to the orchestrator's pane via `tmux send-keys`
   - The orchestrator receives this as a new message in its OpenCode conversation

3. **Detailed handoff**: For complex results, agents write structured output to `runs/<run_id>/handoff.md`, which the orchestrator can read via file tools.

### Locking

orc uses **mkdir-based locking** for all concurrent operations (portable across macOS and Linux, no `flock` dependency):

```bash
acquire_lock "/path/.lock_dir" 10   # timeout in seconds
# ... critical section ...
release_lock "/path/.lock_dir"
```

Lock features:
- Atomic acquisition via `mkdir` (POSIX guarantee)
- PID-based stale lock detection (if holder process died)
- Exponential backoff (0.1s -> 0.2s -> 0.5s -> 1s)
- Two active locks: `.sendkeys_lock` (serializes tmux sends) and `.layout_lock` (serializes grid operations)

### Pane Reuse Mechanism

When `spawn` is called and a completed agent pane exists:

1. `find_reusable_pane()` iterates all runs looking for one with `.done_time` and an alive pane
2. Atomic `mkdir` claim prevents two concurrent spawns from grabbing the same pane
3. If the new role matches the old role, `/new` resets the conversation (fast path, ~2s)
4. If the role changed, OpenCode is restarted with `--agent orc-<new_role>` (slower, ~10s, but correct permissions)
5. A new run directory is created, inheriting the pane ID and grid position

### Watchdog

A background process (`scripts/watchdog.sh`) runs for each session with configurable intervals:

| Parameter | Default | Description |
|-----------|---------|-------------|
| Check interval | 10s | How often to scan all runs |
| Run timeout | 300s | Max time before a run is marked FAILED |
| Pane silence | 120s | Warn if no pane output for this long |

The watchdog also monitors disk space (minimum 100MB) and logs all events to `event-log.jsonl`.

### Template System

Each subagent receives a prompt assembled from multiple layers:

```
┌──────────────────────────────┐
│  Role Profile (specs/*.md)    │  "You are a coder. Your profession is..."
├──────────────────────────────┤
│  Generic Instructions         │  ACK protocol, scope constraints, output format
│  (subagent-generic.md)        │
├──────────────────────────────┤
│  Role-Specific Instructions   │  Role-specific workflow and quality rules
│  (subagent-<role>.md)         │
├──────────────────────────────┤
│  Project Context (auto-detect)│  Language, build/test commands (from Cargo.toml, etc.)
├──────────────────────────────┤
│  Task Goal                    │  The specific task assigned by the orchestrator
├──────────────────────────────┤
│  ACK + Done Commands          │  ./orc_agent reply + ./orc_agent done with correct IDs
└──────────────────────────────┘
```

Project context is auto-detected from build files (Cargo.toml, package.json, go.mod, pyproject.toml, Makefile).

---

## Examples

### Code Review Workflow

```
User: Review the recent changes to the payment module for security issues
```

The orchestrator will:
1. Spawn an **explorer** to map the payment module structure
2. Spawn a **reviewer** to examine recent diffs for security issues
3. Synthesize both reports into a final security review

### Feature Implementation

```
User: Add rate limiting to the API endpoints with Redis-based token bucket
```

The orchestrator will:
1. Spawn an **explorer** to understand the current API structure
2. Spawn a **researcher** to evaluate rate limiting strategies and Redis libraries
3. Spawn a **coder** to implement the rate limiter
4. Spawn a **reviewer** to check the implementation
5. Spawn a **verifier** to run tests and validate the implementation
6. Synthesize all results and report completion

### Bug Investigation

```
User: Users are getting 500 errors on the /api/checkout endpoint intermittently
```

The orchestrator will:
1. Spawn an **explorer** to examine the checkout endpoint code and error handling
2. Spawn a **researcher** to investigate common causes of intermittent 500 errors
3. Spawn a **coder** to implement the fix once the root cause is identified
4. Spawn a **verifier** to confirm the fix resolves the issue

### Codebase Audit

```
User: Give me a comprehensive overview of this project's architecture and potential tech debt
```

The orchestrator will:
1. Spawn multiple **explorers** in parallel — one for each major directory
2. Spawn a **reviewer** to identify architectural risks and tech debt
3. Spawn a **summarizer** to aggregate all findings into a single report

---

## Troubleshooting

### tmux not found

```
[orc] tmux is not installed. Please install tmux first.
```

Install tmux:
- macOS: `brew install tmux`
- Ubuntu/Debian: `sudo apt install tmux`

### opencode not found in PATH

```
[orc] opencode not found in PATH.
```

Install OpenCode:
```bash
curl -fsSL https://opencode.ai/install | bash
```

### Session already exists

```
[orc] tmux session 'orc-1' already exists.
```

Either attach to the existing session or abort it:
```bash
orc attach          # attach to it
orc abort orc-1     # kill it and start fresh
```

### Pane too small for grid

If your terminal is too small to fit the 3x2 grid, agents will fall back to separate tmux windows. For best experience:

- **Minimum terminal size**: 220 x 55 characters
- **Recommended**: Full-screen terminal or a large monitor

### Agent timed out

```
AGENT_ALERT: 1 agent(s) have problems:
  run-003 (coder): TIMEOUT(245s)
```

Options:
```bash
orc_agent retry run-003                    # Retry with same goal
orc_agent retry run-003 "Better goal..."   # Retry with refined goal
orc_agent ping run-003                     # Check detailed status
```

### Stuck session after crash

If tmux or your terminal crashed:
```bash
orc recover                 # Diagnose session state
orc attach                  # Re-attach if tmux is still running
orc abort session-XXXXX     # Kill and clean up
```

### Disk space issues

orc refuses to spawn agents when disk space drops below 100MB. The watchdog also monitors disk space and logs critical warnings. Free up disk space and retry.

### Lock timeout

```
SPAWN_ERROR: layout lock timeout
```

This means another spawn is holding the lock for too long. Wait a few seconds and retry. If it persists, check for dead lock files:
```bash
ls -la .orchestrator/sessions/*/.*_lock/
# Remove stale locks manually if the holding process is dead
rm -rf .orchestrator/sessions/<sid>/.layout_lock
```

---

## License

MIT License

Copyright (c) 2026

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
