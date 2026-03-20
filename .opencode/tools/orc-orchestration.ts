import { tool } from "@opencode-ai/plugin"

/**
 * Spawn a new subagent with a specific role and goal.
 * Tool name: orc-orchestration_spawn
 */
export const spawn = tool({
  description:
    "Spawn a new subagent with a specific role and goal. " +
    "Only the orchestrator (main agent) should use this. " +
    "Returns: SPAWNED run-NNN %NN role",
  args: {
    role: tool.schema
      .enum([
        "explorer",
        "researcher",
        "coder",
        "reviewer",
        "summarizer",
        "verifier",
      ])
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
      const goalArg = args.new_goal || ""
      const result =
        await Bun.$`./orc_agent retry ${args.run_id} ${goalArg}`.cwd(
          context.worktree,
        )
      return result.text().trim()
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR retrying ${args.run_id}: ${msg}`
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
