import { tool } from "@opencode-ai/plugin"

const VALID_ROLES = [
  "explorer",
  "researcher",
  "coder",
  "reviewer",
  "summarizer",
  "verifier",
] as const

/**
 * Spawn a new subagent with a specific role and goal.
 * Tool name: orc-orchestration_spawn
 */
export const spawn = tool({
  description:
    "Spawn a single subagent. For spawning multiple agents at once, " +
    "use orc-orchestration_spawn_batch instead (parallel, much faster). " +
    "Returns: SPAWNED run-NNN %NN role",
  args: {
    role: tool.schema
      .enum([...VALID_ROLES])
      .describe("Agent role"),
    goal: tool.schema
      .string()
      .describe("Detailed task description for the agent"),
  },
  async execute(args, context) {
    if (process.env.ORC_IS_SUBAGENT === "1") {
      return "ERROR: Subagents are not allowed to spawn other agents. Only the orchestrator can do this."
    }

    try {
      const result =
        await Bun.$`./orc_agent spawn ${args.role} ${args.goal}`.cwd(
          context.worktree,
        )
      return result.text().trim()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR spawning ${args.role} agent: ${msg}`
    }
  },
})

/**
 * Spawn multiple subagents in parallel. Much faster than calling spawn repeatedly.
 * Tool name: orc-orchestration_spawn_batch
 */
export const spawn_batch = tool({
  description:
    "Spawn multiple subagents in PARALLEL. Use this instead of calling spawn " +
    "multiple times — all agents start simultaneously. " +
    "Returns results for each agent.",
  args: {
    agents: tool.schema
      .array(
        tool.schema.object({
          role: tool.schema
            .enum([...VALID_ROLES])
            .describe("Agent role"),
          goal: tool.schema
            .string()
            .describe("Detailed task description for the agent"),
        }),
      )
      .describe("Array of agents to spawn, each with a role and goal"),
  },
  async execute(args, context) {
    if (process.env.ORC_IS_SUBAGENT === "1") {
      return "ERROR: Subagents are not allowed to spawn other agents."
    }

    if (!args.agents || args.agents.length === 0) {
      return "ERROR: No agents specified."
    }

    const results = await Promise.all(
      args.agents.map(async (agent) => {
        try {
          const result =
            await Bun.$`./orc_agent spawn ${agent.role} ${agent.goal}`.cwd(
              context.worktree,
            )
          return result.text().trim()
        } catch (err: unknown) {
          const msg = err instanceof Error ? err.message : String(err)
          return `ERROR spawning ${agent.role}: ${msg}`
        }
      }),
    )

    return results.join("\n")
  },
})

/**
 * List all current agents and their statuses.
 * Tool name: orc-orchestration_list
 */
export const list = tool({
  description: "List all current agents and their statuses.",
  args: {},
  async execute(_args, context) {
    try {
      const result = await Bun.$`./orc_agent list`.cwd(context.worktree)
      return result.text().trim() || "No agents found."
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR listing agents: ${msg}`
    }
  },
})

/**
 * Check health of a specific agent.
 * Tool name: orc-orchestration_ping
 */
export const ping = tool({
  description: "Check health of a specific agent by run ID.",
  args: {
    run_id: tool.schema
      .string()
      .describe("Agent run ID (e.g. run-001)"),
  },
  async execute(args, context) {
    try {
      const result = await Bun.$`./orc_agent ping ${args.run_id}`.cwd(
        context.worktree,
      )
      return result.text().trim()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR pinging ${args.run_id}: ${msg}`
    }
  },
})

/**
 * Retry a failed or timed out agent.
 * Tool name: orc-orchestration_retry
 */
export const retry = tool({
  description:
    "Retry a failed or timed-out agent. Optionally provide an improved goal.",
  args: {
    run_id: tool.schema
      .string()
      .describe("Agent run ID to retry (e.g. run-003)"),
    new_goal: tool.schema
      .string()
      .optional()
      .describe("Optional improved goal text. If omitted, uses the original goal."),
  },
  async execute(args, context) {
    try {
      const result = args.new_goal
        ? await Bun.$`./orc_agent retry ${args.run_id} ${args.new_goal}`.cwd(
            context.worktree,
          )
        : await Bun.$`./orc_agent retry ${args.run_id}`.cwd(context.worktree)
      return result.text().trim()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR retrying ${args.run_id}: ${msg}`
    }
  },
})

/**
 * Reassign a completed agent's pane with a new role and task.
 * Faster than spawn — reuses the existing pane and skips OpenCode startup.
 * Tool name: orc-orchestration_reassign
 */
export const reassign = tool({
  description:
    "Reuse a completed agent's pane with a new role and task. " +
    "Faster than spawn — skips OpenCode startup time. " +
    "If run_id is omitted, auto-picks the first available done pane.",
  args: {
    role: tool.schema
      .enum([...VALID_ROLES])
      .describe("New agent role"),
    goal: tool.schema
      .string()
      .describe("New task description"),
    run_id: tool.schema
      .string()
      .optional()
      .describe("Specific completed run ID to reuse (e.g. run-001). If omitted, auto-picks first available."),
  },
  async execute(args, context) {
    if (process.env.ORC_IS_SUBAGENT === "1") {
      return "ERROR: Subagents cannot reassign agents."
    }

    try {
      if (args.run_id) {
        const result =
          await Bun.$`./orc_agent reassign ${args.run_id} ${args.role} ${args.goal}`.cwd(
            context.worktree,
          )
        return result.text().trim()
      } else {
        const result =
          await Bun.$`./orc_agent reassign ${args.role} ${args.goal}`.cwd(
            context.worktree,
          )
        return result.text().trim()
      }
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR reassigning: ${msg}`
    }
  },
})

/**
 * Check health of all agents at once.
 * Tool name: orc-orchestration_check_all
 */
export const check_all = tool({
  description:
    "Check health of all agents at once. Reports dead, timed-out, and healthy agents.",
  args: {},
  async execute(_args, context) {
    try {
      const result = await Bun.$`./orc_agent check-all`.cwd(context.worktree)
      return result.text().trim() || "All agents checked."
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR checking all agents: ${msg}`
    }
  },
})

/**
 * Check or set session branch name.
 * Tool name: orc-orchestration_session_name
 */
export const session_name = tool({
  description:
    "Get or set the session branch name. Use 'get' to check current name, 'set' to rename the branch following conventional commits format (e.g. feat/add-auth, fix/race-condition).",
  args: {
    action: tool.schema
      .enum(["get", "set"])
      .describe("Action: 'get' to check current name, 'set' to rename"),
    name: tool.schema
      .string()
      .optional()
      .describe(
        "Branch name in conventional commits format: <type>/<description>. Required for 'set' action. Types: feat, fix, refactor, docs, test, chore, ci, perf, style, build, revert",
      ),
  },
  async execute(args, context) {
    try {
      const result = args.action === "set" && args.name
        ? await Bun.$`./orc_agent name set ${args.name}`.cwd(context.worktree)
        : await Bun.$`./orc_agent name get`.cwd(context.worktree)
      return result.text().trim()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR: ${msg}`
    }
  },
})
