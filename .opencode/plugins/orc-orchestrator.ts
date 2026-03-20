import type { Plugin } from "@opencode-ai/plugin"

export const OrcOrchestrator: Plugin = async ({
  project,
  client,
  $,
  directory,
  worktree,
}) => {
  const isSubagent = process.env.ORC_IS_SUBAGENT === "1"
  const runId = process.env.ORC_RUN_ID
  const sessionDir = process.env.ORC_SESSION_DIR
  const agentTimeout = process.env.ORC_AGENT_TIMEOUT

  const log = async (
    level: "debug" | "info" | "warn" | "error",
    message: string,
    extra?: Record<string, unknown>,
  ) => {
    try {
      await client.app.log({
        body: {
          service: "orc-orchestrator",
          level,
          message,
          extra: extra ?? {},
        },
      })
    } catch {
      // Graceful fallback — logging should never break the plugin
    }
  }

  if (runId) {
    await log("info", "ORC plugin loaded", {
      runId,
      isSubagent,
      sessionDir,
      directory,
    })
  }

  return {
    // 1. SHELL ENV HOOK — inject orc environment variables into shell sessions
    "shell.env": async (_input, output) => {
      // Always set workdir
      output.env.ORC_WORKDIR = directory

      // Propagate orc env vars if present
      if (runId) {
        output.env.ORC_RUN_ID = runId
      }
      if (sessionDir) {
        output.env.ORC_SESSION_DIR = sessionDir
      }
      if (isSubagent) {
        output.env.ORC_IS_SUBAGENT = "1"
      }
      if (agentTimeout) {
        output.env.ORC_AGENT_TIMEOUT = agentTimeout
      }

      // Add worktree to PATH so orc_agent is available in shell
      if (worktree) {
        const currentPath = output.env.PATH ?? process.env.PATH ?? ""
        if (!currentPath.includes(worktree)) {
          output.env.PATH = `${worktree}:${currentPath}`
        }
      }
    },

    // 2. EVENT HOOK — react to session lifecycle events
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        if (isSubagent && runId) {
          await log("info", "Subagent session idle", { runId })
          // Do NOT auto-call done — the agent must explicitly invoke orc_agent done
        }
      }

      if (event.type === "session.error") {
        await log("error", "Session error occurred", {
          runId: runId ?? "none",
          isSubagent,
        })

        // If subagent — notify main agent about the error
        if (isSubagent && runId) {
          try {
            const mainPane = process.env.ORC_MAIN_PANE
            if (mainPane) {
              await $`./orc_agent reply ${mainPane} "run-${runId}: ERROR — session error detected"`
            }
          } catch {
            await log("warn", "Failed to notify main agent about session error")
          }
        }
      }
    },

    // 3. TOOL EXECUTE BEFORE — guard against subagent spawning + logging
    "tool.execute.before": async (input, output) => {
      const toolName = input.tool ?? ""

      // Guard: subagents must not spawn other agents
      if (
        isSubagent &&
        (toolName === "orc-orchestration_spawn" ||
          toolName === "orc-orchestration_spawn-window")
      ) {
        throw new Error("Subagents cannot spawn other agents")
      }

      // Log all orc-* tool invocations
      if (toolName.startsWith("orc-")) {
        await log("debug", `Tool executing: ${toolName}`, {
          tool: toolName,
          runId: runId ?? "none",
          args: output.args,
        })
      }
    },

    // 4. TOOL EXECUTE AFTER — log results of orc tools
    "tool.execute.after": async (input, output) => {
      const toolName = input.tool ?? ""

      if (toolName.startsWith("orc-")) {
        await log("debug", `Tool completed: ${toolName}`, {
          tool: toolName,
          runId: runId ?? "none",
        })

        // Log completion signal from orc-comm_done
        if (toolName === "orc-comm_done") {
          await log("info", "Agent signaled done via orc-comm_done", {
            runId: runId ?? "none",
          })
        }
      }
    },
  }
}
