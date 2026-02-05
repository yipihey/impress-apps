/**
 * MCP tool definitions for impel
 *
 * Provides AI agents with tools to orchestrate research threads, manage
 * agents, handle escalations, and coordinate autonomous research workflows.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImpelClient } from "./client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const IMPEL_TOOLS: Tool[] = [
  // --------------------------------------------------------------------------
  // Status & System
  // --------------------------------------------------------------------------
  {
    name: "impel_status",
    description:
      "Get impel system status including thread counts, agent counts, and open escalations. Use this to check if impel is running and get an overview of the coordination state.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },

  // --------------------------------------------------------------------------
  // Thread Tools (Read)
  // --------------------------------------------------------------------------
  {
    name: "impel_list_threads",
    description:
      "List research threads with optional filters. Returns thread summaries sorted by temperature (priority). Use state filter for specific lifecycle stages (EMBRYO, ACTIVE, BLOCKED, REVIEW, COMPLETE, KILLED).",
    inputSchema: {
      type: "object",
      properties: {
        state: {
          type: "string",
          description:
            "Filter by state: EMBRYO, ACTIVE, BLOCKED, REVIEW, COMPLETE, or KILLED",
        },
        min_temperature: {
          type: "number",
          description: "Minimum temperature (0.0-1.0) to include",
        },
        max_temperature: {
          type: "number",
          description: "Maximum temperature (0.0-1.0) to include",
        },
      },
    },
  },
  {
    name: "impel_get_thread",
    description:
      "Get detailed information about a specific thread including description, state, temperature, tags, and artifacts.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_get_thread_events",
    description:
      "Get the event history for a specific thread. Shows all state changes, claims, releases, and other events.",
    inputSchema: {
      type: "object",
      properties: {
        thread_id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["thread_id"],
    },
  },
  {
    name: "impel_get_available_threads",
    description:
      "Get threads available for claiming (unclaimed and in a claimable state). Use this to find work that can be picked up.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },

  // --------------------------------------------------------------------------
  // Thread Tools (Write)
  // --------------------------------------------------------------------------
  {
    name: "impel_create_thread",
    description:
      "Create a new research thread. Threads start in EMBRYO state and must be activated before work can begin. Set priority (0.0-1.0) to influence attention ordering.",
    inputSchema: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "Thread title (brief, descriptive)",
        },
        description: {
          type: "string",
          description: "Detailed description of the research task",
        },
        parent_id: {
          type: "string",
          description: "Optional parent thread UUID for hierarchical threads",
        },
        priority: {
          type: "number",
          description: "Initial temperature/priority (0.0-1.0, default 0.5)",
        },
      },
      required: ["title", "description"],
    },
  },
  {
    name: "impel_activate_thread",
    description:
      "Activate an EMBRYO thread, transitioning it to ACTIVE state where it can be claimed and worked on.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_claim_thread",
    description:
      "Claim a thread for an agent to work on. Only ACTIVE threads can be claimed. An agent can only work on one thread at a time.",
    inputSchema: {
      type: "object",
      properties: {
        thread_id: {
          type: "string",
          description: "Thread UUID to claim",
        },
        agent_id: {
          type: "string",
          description: "Agent ID claiming the thread",
        },
      },
      required: ["thread_id", "agent_id"],
    },
  },
  {
    name: "impel_release_thread",
    description:
      "Release a claimed thread, making it available for other agents. Use when pausing work or handing off.",
    inputSchema: {
      type: "object",
      properties: {
        thread_id: {
          type: "string",
          description: "Thread UUID to release",
        },
        agent_id: {
          type: "string",
          description: "Agent ID releasing the thread",
        },
      },
      required: ["thread_id", "agent_id"],
    },
  },
  {
    name: "impel_block_thread",
    description:
      "Block a thread that cannot make progress. Use when waiting for external input, resources, or human decision.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
        reason: {
          type: "string",
          description: "Why the thread is blocked",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_unblock_thread",
    description:
      "Unblock a BLOCKED thread, returning it to ACTIVE state.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_submit_for_review",
    description:
      "Submit a thread for human review. Use when work is complete and needs approval before marking as done.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_complete_thread",
    description:
      "Mark a thread as complete. Only threads in REVIEW state can be completed. This is a terminal state.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_kill_thread",
    description:
      "Kill a thread, marking it as terminated. Use for abandoned or superseded threads. This is a terminal state.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
        reason: {
          type: "string",
          description: "Why the thread is being killed",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_set_temperature",
    description:
      "Adjust thread temperature (priority). Higher temperature means more attention. Use to reprioritize work.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Thread UUID",
        },
        temperature: {
          type: "number",
          description: "New temperature (0.0-1.0)",
        },
        reason: {
          type: "string",
          description: "Why temperature is being changed",
        },
      },
      required: ["id", "temperature"],
    },
  },

  // --------------------------------------------------------------------------
  // Persona Tools
  // --------------------------------------------------------------------------
  {
    name: "impel_list_personas",
    description:
      "List all available personas. Personas define agent behavior, model settings, and tool access policies.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "impel_get_persona",
    description:
      "Get full details of a persona including system prompt, behavior parameters, domain expertise, and tool policies.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Persona ID (e.g., 'scout', 'archivist')",
        },
      },
      required: ["id"],
    },
  },

  // --------------------------------------------------------------------------
  // Agent Tools
  // --------------------------------------------------------------------------
  {
    name: "impel_list_agents",
    description:
      "List all registered agents with their status and current work.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "impel_get_agent",
    description:
      "Get detailed information about an agent including capabilities, registration time, and work history.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Agent ID (e.g., 'research-1', 'code-2')",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_register_agent",
    description:
      "Register a new agent. Agent types: Research, Code, Verification, Adversarial, Review, Librarian.",
    inputSchema: {
      type: "object",
      properties: {
        agent_type: {
          type: "string",
          description:
            "Type of agent: research, code, verification, adversarial, review, librarian",
        },
        persona_id: {
          type: "string",
          description: "Optional persona ID to associate with the agent",
        },
      },
      required: ["agent_type"],
    },
  },
  {
    name: "impel_terminate_agent",
    description:
      "Terminate an agent, removing it from the active pool. Terminated agents cannot be reactivated.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Agent ID to terminate",
        },
        reason: {
          type: "string",
          description: "Reason for termination",
        },
      },
      required: ["id"],
    },
  },

  // --------------------------------------------------------------------------
  // Escalation Tools
  // --------------------------------------------------------------------------
  {
    name: "impel_list_escalations",
    description:
      "List escalations (requests for human attention). By default shows only open escalations. Sorted by priority.",
    inputSchema: {
      type: "object",
      properties: {
        open_only: {
          type: "boolean",
          description: "Only show open escalations (default: true)",
        },
      },
    },
  },
  {
    name: "impel_get_escalation",
    description:
      "Get full details of an escalation including description, options (for Decision type), and resolution status.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Escalation UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impel_create_escalation",
    description:
      "Create an escalation to request human attention. Categories: Decision (choose between options), Novelty (unprecedented situation), Stuck (can't progress), Scope (boundary issues), Quality (review needed), Checkpoint (regular progress review).",
    inputSchema: {
      type: "object",
      properties: {
        category: {
          type: "string",
          description:
            "Escalation category: decision, novelty, stuck, scope, quality, checkpoint",
        },
        title: {
          type: "string",
          description: "Brief title describing the escalation",
        },
        description: {
          type: "string",
          description: "Detailed description of what needs attention",
        },
        created_by: {
          type: "string",
          description: "ID of the agent creating the escalation",
        },
        thread_id: {
          type: "string",
          description: "Optional related thread UUID",
        },
        priority: {
          type: "string",
          description: "Priority: low, medium, high, critical (default based on category)",
        },
        options: {
          type: "array",
          description: "For Decision escalations, the options to choose from",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              description: { type: "string" },
              impact: { type: "string" },
            },
            required: ["label", "description"],
          },
        },
      },
      required: ["category", "title", "description", "created_by"],
    },
  },
  {
    name: "impel_acknowledge_escalation",
    description:
      "Acknowledge an escalation, indicating it has been seen. Does not resolve it.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Escalation UUID",
        },
        by: {
          type: "string",
          description: "ID of who is acknowledging",
        },
      },
      required: ["id", "by"],
    },
  },
  {
    name: "impel_resolve_escalation",
    description:
      "Resolve an escalation with a decision or resolution. For Decision escalations, can specify which option was selected.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Escalation UUID",
        },
        by: {
          type: "string",
          description: "ID of who is resolving",
        },
        resolution: {
          type: "string",
          description: "Resolution text explaining the decision",
        },
        selected_option: {
          type: "number",
          description: "For Decision escalations, index of selected option (0-based)",
        },
      },
      required: ["id", "by", "resolution"],
    },
  },

  // --------------------------------------------------------------------------
  // Event Tools
  // --------------------------------------------------------------------------
  {
    name: "impel_get_events",
    description:
      "Get recent events from the event log. Events track all state changes in the system.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Maximum number of events to return (default: 100)",
        },
      },
    },
  },

  // --------------------------------------------------------------------------
  // Agent Work Dispatch
  // --------------------------------------------------------------------------
  {
    name: "impel_get_next_thread",
    description:
      "Get the next available thread for an agent to work on. Returns the highest-temperature unclaimed thread. Use auto_claim=true to automatically claim the thread in one call. Essential for agent work loops.",
    inputSchema: {
      type: "object",
      properties: {
        agent_id: {
          type: "string",
          description: "Agent ID to get next thread for",
        },
        auto_claim: {
          type: "boolean",
          description:
            "Automatically claim the thread (default: false). Set true for efficient work dispatch.",
        },
      },
      required: ["agent_id"],
    },
  },

  // --------------------------------------------------------------------------
  // Escalation Polling
  // --------------------------------------------------------------------------
  {
    name: "impel_poll_escalation",
    description:
      "Poll for escalation resolution with long-polling. Blocks until the escalation is resolved by a human or the timeout expires. Essential for human-in-the-loop agent workflows - use this after creating an escalation to wait for the human decision.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Escalation UUID to poll",
        },
        timeout: {
          type: "number",
          description:
            "Timeout in seconds (default: 30, max: 120). Request blocks until resolved or timeout.",
        },
      },
      required: ["id"],
    },
  },
];

// ============================================================================
// Tool Handler
// ============================================================================

export class ImpelTools {
  constructor(private client: ImpelClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      // Status
      case "impel_status":
        return this.getStatus();

      // Threads (Read)
      case "impel_list_threads":
        return this.listThreads(args);
      case "impel_get_thread":
        return this.getThread(args);
      case "impel_get_thread_events":
        return this.getThreadEvents(args);
      case "impel_get_available_threads":
        return this.getAvailableThreads();

      // Threads (Write)
      case "impel_create_thread":
        return this.createThread(args);
      case "impel_activate_thread":
        return this.activateThread(args);
      case "impel_claim_thread":
        return this.claimThread(args);
      case "impel_release_thread":
        return this.releaseThread(args);
      case "impel_block_thread":
        return this.blockThread(args);
      case "impel_unblock_thread":
        return this.unblockThread(args);
      case "impel_submit_for_review":
        return this.submitForReview(args);
      case "impel_complete_thread":
        return this.completeThread(args);
      case "impel_kill_thread":
        return this.killThread(args);
      case "impel_set_temperature":
        return this.setTemperature(args);

      // Personas
      case "impel_list_personas":
        return this.listPersonas();
      case "impel_get_persona":
        return this.getPersona(args);

      // Agents
      case "impel_list_agents":
        return this.listAgents();
      case "impel_get_agent":
        return this.getAgent(args);
      case "impel_register_agent":
        return this.registerAgent(args);
      case "impel_terminate_agent":
        return this.terminateAgent(args);

      // Escalations
      case "impel_list_escalations":
        return this.listEscalations(args);
      case "impel_get_escalation":
        return this.getEscalation(args);
      case "impel_create_escalation":
        return this.createEscalation(args);
      case "impel_acknowledge_escalation":
        return this.acknowledgeEscalation(args);
      case "impel_resolve_escalation":
        return this.resolveEscalation(args);

      // Events
      case "impel_get_events":
        return this.getEvents(args);

      // Agent Work Dispatch
      case "impel_get_next_thread":
        return this.getNextThread(args);

      // Escalation Polling
      case "impel_poll_escalation":
        return this.pollEscalation(args);

      default:
        return {
          content: [{ type: "text", text: `Unknown impel tool: ${name}` }],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Status
  // --------------------------------------------------------------------------

  private async getStatus(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const status = await this.client.checkStatus();

    if (!status) {
      return {
        content: [
          {
            type: "text",
            text: "impel is not running or HTTP API is not accessible.\n\nTo start impel:\n  cd crates/impel-server && IMPEL_ADDR=127.0.0.1:23123 cargo run",
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            "# impel Status",
            "",
            `**Paused:** ${status.paused ? "Yes" : "No"}`,
            `**Threads:** ${status.threads.active} active / ${status.threads.total} total`,
            `**Agents:** ${status.agents.total}`,
            `**Personas:** ${status.personas.total}`,
            `**Open Escalations:** ${status.escalations.open}`,
            `**Event Sequence:** ${status.event_sequence}`,
          ].join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Threads (Read)
  // --------------------------------------------------------------------------

  private async listThreads(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.listThreads({
      state: args?.state as string | undefined,
      min_temperature: args?.min_temperature as number | undefined,
      max_temperature: args?.max_temperature as number | undefined,
    });

    if (result.threads.length === 0) {
      return {
        content: [{ type: "text", text: "No threads found." }],
      };
    }

    const lines = result.threads.map((t) => {
      const claimed = t.claimed_by ? ` [${t.claimed_by}]` : "";
      return `- **${t.title}** (${t.id.slice(0, 8)}...)\n  State: ${t.state} | Temp: ${t.temperature.toFixed(2)}${claimed}`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# Threads (${result.count})\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  private async getThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    const thread = await this.client.getThread(id);
    if (!thread) {
      return { content: [{ type: "text", text: `Thread not found: ${id}` }] };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Thread: ${thread.title}`,
            "",
            `**ID:** ${thread.id}`,
            `**State:** ${thread.state}`,
            `**Temperature:** ${thread.temperature.toFixed(2)}`,
            `**Claimed By:** ${thread.claimed_by || "unclaimed"}`,
            thread.parent_id ? `**Parent:** ${thread.parent_id}` : null,
            "",
            "## Description",
            thread.description || "(no description)",
            "",
            thread.tags.length > 0
              ? `**Tags:** ${thread.tags.join(", ")}`
              : null,
            thread.artifact_ids.length > 0
              ? `**Artifacts:** ${thread.artifact_ids.length}`
              : null,
            "",
            `**Created:** ${thread.created_at}`,
            `**Updated:** ${thread.updated_at}`,
          ]
            .filter((line) => line !== null)
            .join("\n"),
        },
      ],
    };
  }

  private async getThreadEvents(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const threadId = args?.thread_id as string;
    if (!threadId) {
      return {
        content: [{ type: "text", text: "Error: thread_id is required" }],
      };
    }

    const result = await this.client.getThreadEvents(threadId);

    if (result.events.length === 0) {
      return {
        content: [{ type: "text", text: `No events for thread ${threadId}` }],
      };
    }

    const lines = result.events.map((e) => {
      const actor = e.actor_id ? ` by ${e.actor_id}` : "";
      return `[${e.sequence}] ${e.timestamp}: ${e.description}${actor}`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# Events for Thread ${threadId.slice(0, 8)}... (${result.count})\n\n\`\`\`\n${lines.join("\n")}\n\`\`\``,
        },
      ],
    };
  }

  private async getAvailableThreads(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const result = await this.client.getAvailableThreads();

    if (result.threads.length === 0) {
      return {
        content: [{ type: "text", text: "No threads available for claiming." }],
      };
    }

    const lines = result.threads.map(
      (t) =>
        `- **${t.title}** (${t.id.slice(0, 8)}...)\n  Temp: ${t.temperature.toFixed(2)}`
    );

    return {
      content: [
        {
          type: "text",
          text: `# Available Threads (${result.threads.length})\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Threads (Write)
  // --------------------------------------------------------------------------

  private async createThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const title = args?.title as string;
    const description = args?.description as string;
    if (!title || !description) {
      return {
        content: [
          { type: "text", text: "Error: title and description are required" },
        ],
      };
    }

    const thread = await this.client.createThread({
      title,
      description,
      parent_id: args?.parent_id as string | undefined,
      priority: args?.priority as number | undefined,
    });

    return {
      content: [
        {
          type: "text",
          text: `Created thread: **${thread.title}**\n\nID: ${thread.id}\nState: ${thread.state}\nTemperature: ${thread.temperature.toFixed(2)}`,
        },
      ],
    };
  }

  private async activateThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.activateThread(id);

    return {
      content: [{ type: "text", text: `Thread ${id} activated (ACTIVE)` }],
    };
  }

  private async claimThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const threadId = args?.thread_id as string;
    const agentId = args?.agent_id as string;
    if (!threadId || !agentId) {
      return {
        content: [
          { type: "text", text: "Error: thread_id and agent_id are required" },
        ],
      };
    }

    await this.client.claimThread(threadId, agentId);

    return {
      content: [
        { type: "text", text: `Thread ${threadId} claimed by ${agentId}` },
      ],
    };
  }

  private async releaseThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const threadId = args?.thread_id as string;
    const agentId = args?.agent_id as string;
    if (!threadId || !agentId) {
      return {
        content: [
          { type: "text", text: "Error: thread_id and agent_id are required" },
        ],
      };
    }

    await this.client.releaseThread(threadId, agentId);

    return {
      content: [
        { type: "text", text: `Thread ${threadId} released by ${agentId}` },
      ],
    };
  }

  private async blockThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.blockThread(id, args?.reason as string | undefined);

    return {
      content: [{ type: "text", text: `Thread ${id} blocked (BLOCKED)` }],
    };
  }

  private async unblockThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.unblockThread(id);

    return {
      content: [{ type: "text", text: `Thread ${id} unblocked (ACTIVE)` }],
    };
  }

  private async submitForReview(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.submitForReview(id);

    return {
      content: [
        { type: "text", text: `Thread ${id} submitted for review (REVIEW)` },
      ],
    };
  }

  private async completeThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.completeThread(id);

    return {
      content: [{ type: "text", text: `Thread ${id} completed (COMPLETE)` }],
    };
  }

  private async killThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.killThread(id, args?.reason as string | undefined);

    return {
      content: [{ type: "text", text: `Thread ${id} killed (KILLED)` }],
    };
  }

  private async setTemperature(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    const temperature = args?.temperature as number;
    if (!id || temperature === undefined) {
      return {
        content: [
          { type: "text", text: "Error: id and temperature are required" },
        ],
      };
    }

    await this.client.setTemperature(
      id,
      temperature,
      args?.reason as string | undefined
    );

    return {
      content: [
        {
          type: "text",
          text: `Thread ${id} temperature set to ${temperature.toFixed(2)}`,
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Personas
  // --------------------------------------------------------------------------

  private async listPersonas(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const result = await this.client.listPersonas();

    if (result.personas.length === 0) {
      return {
        content: [{ type: "text", text: "No personas available." }],
      };
    }

    const lines = result.personas.map(
      (p) =>
        `- **${p.name}** (${p.id})\n  ${p.archetype} | ${p.builtin ? "Built-in" : "Custom"}\n  ${p.role_description}`
    );

    return {
      content: [
        {
          type: "text",
          text: `# Personas (${result.count})\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  private async getPersona(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    const persona = await this.client.getPersona(id);
    if (!persona) {
      return { content: [{ type: "text", text: `Persona not found: ${id}` }] };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Persona: ${persona.name}`,
            "",
            `**ID:** ${persona.id}`,
            `**Archetype:** ${persona.archetype}`,
            `**Built-in:** ${persona.builtin ? "Yes" : "No"}`,
            "",
            "## Role",
            persona.role_description,
            "",
            "## Behavior",
            `- Verbosity: ${persona.behavior.verbosity}`,
            `- Risk Tolerance: ${persona.behavior.risk_tolerance}`,
            `- Citation Density: ${persona.behavior.citation_density}`,
            `- Escalation Tendency: ${persona.behavior.escalation_tendency}`,
            `- Working Style: ${persona.behavior.working_style}`,
            "",
            "## Domain",
            `- Domains: ${persona.domain.primary_domains.join(", ")}`,
            `- Methodologies: ${persona.domain.methodologies.join(", ")}`,
            `- Data Sources: ${persona.domain.data_sources.join(", ")}`,
            "",
            "## Model",
            `- Provider: ${persona.model.provider}`,
            `- Model: ${persona.model.model}`,
            `- Temperature: ${persona.model.temperature}`,
            "",
            "## Tool Access",
            `Default: ${persona.tools.default_access}`,
            ...persona.tools.policies.map(
              (p) => `- ${p.tool}: ${p.access} (${p.scope.join(", ")})`
            ),
          ].join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Agents
  // --------------------------------------------------------------------------

  private async listAgents(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const result = await this.client.listAgents();

    if (result.agents.length === 0) {
      return {
        content: [{ type: "text", text: "No agents registered." }],
      };
    }

    const lines = result.agents.map((a) => {
      const thread = a.current_thread
        ? ` working on ${a.current_thread.slice(0, 8)}...`
        : "";
      return `- **${a.id}** (${a.agent_type})\n  Status: ${a.status}${thread}\n  Completed: ${a.threads_completed} threads`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# Agents (${result.count})\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  private async getAgent(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    const agent = await this.client.getAgent(id);
    if (!agent) {
      return { content: [{ type: "text", text: `Agent not found: ${id}` }] };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Agent: ${agent.id}`,
            "",
            `**Type:** ${agent.agent_type}`,
            `**Status:** ${agent.status}`,
            `**Current Thread:** ${agent.current_thread || "none"}`,
            `**Threads Completed:** ${agent.threads_completed}`,
            "",
            "## Capabilities",
            agent.capabilities.map((c) => `- ${c}`).join("\n"),
            "",
            `**Registered:** ${agent.registered_at}`,
            `**Last Active:** ${agent.last_active_at}`,
          ].join("\n"),
        },
      ],
    };
  }

  private async registerAgent(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const agentType = args?.agent_type as string;
    if (!agentType) {
      return {
        content: [{ type: "text", text: "Error: agent_type is required" }],
      };
    }

    const agent = await this.client.registerAgent(
      agentType,
      args?.persona_id as string | undefined
    );

    return {
      content: [
        {
          type: "text",
          text: `Registered agent: **${agent.id}** (${agent.agent_type})\n\nCapabilities: ${agent.capabilities.join(", ")}`,
        },
      ],
    };
  }

  private async terminateAgent(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    await this.client.terminateAgent(id, args?.reason as string | undefined);

    return {
      content: [{ type: "text", text: `Agent ${id} terminated` }],
    };
  }

  // --------------------------------------------------------------------------
  // Escalations
  // --------------------------------------------------------------------------

  private async listEscalations(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const openOnly = args?.open_only !== false;
    const result = await this.client.listEscalations(openOnly);

    if (result.escalations.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: openOnly
              ? "No open escalations."
              : "No escalations found.",
          },
        ],
      };
    }

    const lines = result.escalations.map((e) => {
      const thread = e.thread_id ? ` (thread: ${e.thread_id.slice(0, 8)}...)` : "";
      return `- **[${e.priority}] ${e.title}** (${e.id.slice(0, 8)}...)\n  ${e.category} | ${e.status}${thread}\n  Created by ${e.created_by} at ${e.created_at}`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# Escalations (${result.count})\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  private async getEscalation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    const esc = await this.client.getEscalation(id);
    if (!esc) {
      return {
        content: [{ type: "text", text: `Escalation not found: ${id}` }],
      };
    }

    const optionsSection =
      esc.options.length > 0
        ? [
            "",
            "## Options",
            ...esc.options.map(
              (o, i) =>
                `${i}. **${o.label}**: ${o.description}${o.impact ? ` (Impact: ${o.impact})` : ""}`
            ),
            esc.selected_option !== null
              ? `\n**Selected:** Option ${esc.selected_option}`
              : "",
          ]
        : [];

    return {
      content: [
        {
          type: "text",
          text: [
            `# Escalation: ${esc.title}`,
            "",
            `**ID:** ${esc.id}`,
            `**Category:** ${esc.category}`,
            `**Priority:** ${esc.priority}`,
            `**Status:** ${esc.status}`,
            esc.thread_id ? `**Thread:** ${esc.thread_id}` : null,
            "",
            "## Description",
            esc.description,
            ...optionsSection,
            "",
            `**Created by:** ${esc.created_by}`,
            `**Created at:** ${esc.created_at}`,
            esc.acknowledged_by
              ? `**Acknowledged by:** ${esc.acknowledged_by} at ${esc.acknowledged_at}`
              : null,
            esc.resolved_by
              ? `**Resolved by:** ${esc.resolved_by} at ${esc.resolved_at}`
              : null,
            esc.resolution ? `**Resolution:** ${esc.resolution}` : null,
          ]
            .filter((line) => line !== null)
            .join("\n"),
        },
      ],
    };
  }

  private async createEscalation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const category = args?.category as string;
    const title = args?.title as string;
    const description = args?.description as string;
    const createdBy = args?.created_by as string;

    if (!category || !title || !description || !createdBy) {
      return {
        content: [
          {
            type: "text",
            text: "Error: category, title, description, and created_by are required",
          },
        ],
      };
    }

    const esc = await this.client.createEscalation({
      category,
      title,
      description,
      created_by: createdBy,
      thread_id: args?.thread_id as string | undefined,
      priority: args?.priority as string | undefined,
      options: args?.options as
        | Array<{ label: string; description: string; impact?: string }>
        | undefined,
    });

    return {
      content: [
        {
          type: "text",
          text: `Created escalation: **${esc.title}**\n\nID: ${esc.id}\nCategory: ${esc.category}\nPriority: ${esc.priority}\nStatus: ${esc.status}`,
        },
      ],
    };
  }

  private async acknowledgeEscalation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    const by = args?.by as string;
    if (!id || !by) {
      return {
        content: [{ type: "text", text: "Error: id and by are required" }],
      };
    }

    await this.client.acknowledgeEscalation(id, by);

    return {
      content: [
        { type: "text", text: `Escalation ${id} acknowledged by ${by}` },
      ],
    };
  }

  private async resolveEscalation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    const by = args?.by as string;
    const resolution = args?.resolution as string;
    if (!id || !by || !resolution) {
      return {
        content: [
          { type: "text", text: "Error: id, by, and resolution are required" },
        ],
      };
    }

    await this.client.resolveEscalation(
      id,
      by,
      resolution,
      args?.selected_option as number | undefined
    );

    return {
      content: [{ type: "text", text: `Escalation ${id} resolved by ${by}` }],
    };
  }

  // --------------------------------------------------------------------------
  // Events
  // --------------------------------------------------------------------------

  private async getEvents(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.getEvents();

    if (result.events.length === 0) {
      return {
        content: [{ type: "text", text: "No events found." }],
      };
    }

    const lines = result.events.map((e) => {
      const actor = e.actor_id ? ` by ${e.actor_id}` : "";
      return `[${e.sequence}] ${e.entity_type}/${e.entity_id.slice(0, 8)}...: ${e.description}${actor}`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# Recent Events (${result.count})\n\n\`\`\`\n${lines.join("\n")}\n\`\`\``,
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Agent Work Dispatch
  // --------------------------------------------------------------------------

  private async getNextThread(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const agentId = args?.agent_id as string;
    if (!agentId) {
      return {
        content: [{ type: "text", text: "Error: agent_id is required" }],
      };
    }

    const autoClaim = (args?.auto_claim as boolean) ?? false;

    const result = await this.client.getNextThread(agentId, autoClaim);

    if (!result.thread) {
      return {
        content: [
          {
            type: "text",
            text: `No threads available for agent ${agentId}.\n\n${result.message}`,
          },
        ],
      };
    }

    const t = result.thread;
    const claimStatus = result.claimed
      ? `**Claimed by:** ${agentId}`
      : "**Status:** Available (not claimed)";

    return {
      content: [
        {
          type: "text",
          text: [
            `# Next Thread for Agent ${agentId}`,
            "",
            `**Title:** ${t.title}`,
            `**ID:** ${t.id}`,
            `**State:** ${t.state}`,
            `**Temperature:** ${t.temperature.toFixed(2)}`,
            claimStatus,
            "",
            "## Description",
            t.description || "(no description)",
            "",
            `**Message:** ${result.message}`,
          ].join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Escalation Polling
  // --------------------------------------------------------------------------

  private async pollEscalation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return { content: [{ type: "text", text: "Error: id is required" }] };
    }

    const timeout = (args?.timeout as number) ?? 30;

    const result = await this.client.pollEscalationResolution(id, timeout);

    if (result.timed_out) {
      return {
        content: [
          {
            type: "text",
            text: [
              `# Escalation Poll: Timed Out`,
              "",
              `**ID:** ${result.id}`,
              `**Status:** ${result.status}`,
              `**Resolved:** No (poll timed out after ${timeout}s)`,
              "",
              "The escalation has not been resolved yet. You can poll again to continue waiting.",
            ].join("\n"),
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Escalation Poll: Resolved`,
            "",
            `**ID:** ${result.id}`,
            `**Status:** ${result.status}`,
            `**Resolved:** Yes`,
            `**Resolved By:** ${result.resolved_by}`,
            `**Resolved At:** ${result.resolved_at}`,
            result.selected_option !== null
              ? `**Selected Option:** ${result.selected_option}`
              : null,
            "",
            "## Resolution",
            result.resolution || "(no resolution text)",
          ]
            .filter((line) => line !== null)
            .join("\n"),
        },
      ],
    };
  }
}
