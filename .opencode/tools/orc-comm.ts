import { tool } from "@opencode-ai/plugin"

/**
 * Report task completion to the orchestrator.
 * Tool name: orc-comm_done
 */
export const done = tool({
  description:
    "Report task completion to the orchestrator. Call this when your work is finished. " +
    "The run_id is auto-detected from ORC_RUN_ID env var if not provided.",
  args: {
    run_id: tool.schema
      .string()
      .optional()
      .describe(
        "Run ID (e.g. run-001). If omitted, uses ORC_RUN_ID env var.",
      ),
    summary: tool.schema
      .string()
      .describe(
        "Concise summary of what was accomplished (max 200 chars for notification, full text saved to result.txt)",
      ),
  },
  async execute(args, context) {
    const runId = args.run_id || process.env.ORC_RUN_ID
    if (!runId) {
      return "ERROR: No run_id provided and ORC_RUN_ID env var is not set."
    }

    try {
      const result =
        await Bun.$`./orc_agent done ${runId} ${args.summary}`.cwd(
          context.worktree,
        )
      return result.text().trim() || `Done reported for ${runId}`
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR reporting done for ${runId}: ${msg}`
    }
  },
})

/**
 * Send a message to another agent pane or the main orchestrator pane.
 * Tool name: orc-comm_reply
 */
export const reply = tool({
  description:
    "Send a message to another agent pane or the main orchestrator pane via tmux.",
  args: {
    pane_id: tool.schema
      .string()
      .describe("Target tmux pane ID (e.g. %42)"),
    message: tool.schema.string().describe("Message to send"),
  },
  async execute(args, context) {
    try {
      const result =
        await Bun.$`./orc_agent reply ${args.pane_id} ${args.message}`.cwd(
          context.worktree,
        )
      return result.text().trim() || `Message sent to ${args.pane_id}`
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : String(err)
      return `ERROR sending reply to ${args.pane_id}: ${msg}`
    }
  },
})
