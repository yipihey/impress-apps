/**
 * HTTP client for impel API
 *
 * Provides access to the impel agent orchestration system for managing
 * research threads, agents, escalations, and coordination state.
 */

// ============================================================================
// Types
// ============================================================================

export interface ImpelStatus {
  paused: boolean;
  threads: {
    total: number;
    active: number;
  };
  agents: {
    total: number;
  };
  personas: {
    total: number;
  };
  escalations: {
    open: number;
  };
  event_sequence: number;
}

export interface ThreadSummary {
  id: string;
  title: string;
  state: string;
  temperature: number;
  claimed_by: string | null;
}

export interface ThreadDetail {
  id: string;
  title: string;
  description: string;
  state: string;
  temperature: number;
  claimed_by: string | null;
  created_at: string;
  updated_at: string;
  parent_id: string | null;
  tags: string[];
  artifact_ids: string[];
}

export interface ThreadsResponse {
  threads: ThreadSummary[];
  count: number;
}

export interface ThreadFilters {
  state?: string;
  min_temperature?: number;
  max_temperature?: number;
}

export interface PersonaSummary {
  id: string;
  name: string;
  archetype: string;
  role_description: string;
  builtin: boolean;
}

export interface PersonaBehavior {
  verbosity: number;
  risk_tolerance: number;
  citation_density: number;
  escalation_tendency: number;
  working_style: string;
  notes: string[];
}

export interface PersonaDomain {
  primary_domains: string[];
  methodologies: string[];
  data_sources: string[];
}

export interface PersonaModel {
  provider: string;
  model: string;
  temperature: number;
  max_tokens: number | null;
  top_p: number | null;
}

export interface ToolPolicy {
  tool: string;
  access: string;
  scope: string[];
  notes: string | null;
}

export interface PersonaTools {
  policies: ToolPolicy[];
  default_access: string;
}

export interface PersonaDetail {
  id: string;
  name: string;
  archetype: string;
  role_description: string;
  system_prompt: string;
  behavior: PersonaBehavior;
  domain: PersonaDomain;
  model: PersonaModel;
  tools: PersonaTools;
  builtin: boolean;
  source_path: string | null;
}

export interface PersonasResponse {
  personas: PersonaSummary[];
  count: number;
}

export interface AgentSummary {
  id: string;
  agent_type: string;
  status: string;
  current_thread: string | null;
  threads_completed: number;
}

export interface AgentDetail {
  id: string;
  agent_type: string;
  status: string;
  current_thread: string | null;
  registered_at: string;
  last_active_at: string;
  threads_completed: number;
  capabilities: string[];
}

export interface AgentsResponse {
  agents: AgentSummary[];
  count: number;
}

export interface NextThreadResponse {
  thread: ThreadDetail | null;
  claimed: boolean;
  message: string;
}

export interface EscalationSummary {
  id: string;
  category: string;
  priority: string;
  status: string;
  title: string;
  thread_id: string | null;
  created_at: string;
  created_by: string;
}

export interface EscalationOption {
  label: string;
  description: string;
  impact: string | null;
}

export interface EscalationDetail {
  id: string;
  category: string;
  priority: string;
  status: string;
  title: string;
  description: string;
  thread_id: string | null;
  created_by: string;
  created_at: string;
  acknowledged_at: string | null;
  acknowledged_by: string | null;
  resolved_at: string | null;
  resolved_by: string | null;
  resolution: string | null;
  options: EscalationOption[];
  selected_option: number | null;
}

export interface EscalationsResponse {
  escalations: EscalationSummary[];
  count: number;
}

export interface EscalationPollResponse {
  id: string;
  status: string;
  resolved: boolean;
  resolution: string | null;
  resolved_by: string | null;
  resolved_at: string | null;
  selected_option: number | null;
  timed_out: boolean;
}

export interface EventSummary {
  id: string;
  sequence: number;
  timestamp: string;
  entity_id: string;
  entity_type: string;
  description: string;
  actor_id: string | null;
}

export interface EventsResponse {
  events: EventSummary[];
  count: number;
}

export interface ThreadEventsResponse {
  thread_id: string;
  events: EventSummary[];
  count: number;
}

export interface CreateThreadParams {
  title: string;
  description: string;
  parent_id?: string;
  priority?: number;
}

export interface CreateEscalationParams {
  category: string;
  title: string;
  description: string;
  created_by: string;
  thread_id?: string;
  priority?: string;
  options?: Array<{
    label: string;
    description: string;
    impact?: string;
  }>;
}

// ============================================================================
// Client
// ============================================================================

export class ImpelClient {
  constructor(private baseURL: string) {}

  // --------------------------------------------------------------------------
  // Status
  // --------------------------------------------------------------------------

  /**
   * Check if impel is running and get system status.
   */
  async checkStatus(): Promise<ImpelStatus | null> {
    try {
      const response = await fetch(`${this.baseURL}/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImpelStatus;
    } catch {
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Threads
  // --------------------------------------------------------------------------

  /**
   * List all threads with optional filters.
   */
  async listThreads(filters?: ThreadFilters): Promise<ThreadsResponse> {
    const params = new URLSearchParams();
    if (filters?.state) params.set("state", filters.state);
    if (filters?.min_temperature !== undefined)
      params.set("min_temperature", String(filters.min_temperature));
    if (filters?.max_temperature !== undefined)
      params.set("max_temperature", String(filters.max_temperature));

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/threads?${query}`
      : `${this.baseURL}/threads`;

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`List threads failed: ${response.statusText}`);
    }
    return (await response.json()) as ThreadsResponse;
  }

  /**
   * Get available threads (unclaimed, claimable).
   */
  async getAvailableThreads(): Promise<ThreadsResponse> {
    const response = await fetch(`${this.baseURL}/threads/available`);
    if (!response.ok) {
      throw new Error(`Get available threads failed: ${response.statusText}`);
    }
    return (await response.json()) as ThreadsResponse;
  }

  /**
   * Get thread details by ID.
   */
  async getThread(id: string): Promise<ThreadDetail | null> {
    try {
      const response = await fetch(`${this.baseURL}/threads/${id}`);
      if (!response.ok) return null;
      return (await response.json()) as ThreadDetail;
    } catch {
      return null;
    }
  }

  /**
   * Create a new thread.
   */
  async createThread(params: CreateThreadParams): Promise<ThreadDetail> {
    const response = await fetch(`${this.baseURL}/threads`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Create thread failed: ${error}`);
    }
    return (await response.json()) as ThreadDetail;
  }

  /**
   * Activate a thread (Embryo -> Active).
   */
  async activateThread(id: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/activate`, {
      method: "PUT",
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Activate thread failed: ${error}`);
    }
  }

  /**
   * Claim a thread for an agent.
   */
  async claimThread(threadId: string, agentId: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${threadId}/claim`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ agent_id: agentId }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Claim thread failed: ${error}`);
    }
  }

  /**
   * Release a thread from an agent.
   */
  async releaseThread(threadId: string, agentId: string): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/threads/${threadId}/release`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ agent_id: agentId }),
      }
    );
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Release thread failed: ${error}`);
    }
  }

  /**
   * Block a thread.
   */
  async blockThread(id: string, reason?: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/block`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reason }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Block thread failed: ${error}`);
    }
  }

  /**
   * Unblock a thread.
   */
  async unblockThread(id: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/unblock`, {
      method: "PUT",
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Unblock thread failed: ${error}`);
    }
  }

  /**
   * Submit a thread for review.
   */
  async submitForReview(id: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/review`, {
      method: "PUT",
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Submit for review failed: ${error}`);
    }
  }

  /**
   * Mark a thread as complete.
   */
  async completeThread(id: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/complete`, {
      method: "PUT",
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Complete thread failed: ${error}`);
    }
  }

  /**
   * Kill a thread.
   */
  async killThread(id: string, reason?: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/kill`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reason }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Kill thread failed: ${error}`);
    }
  }

  /**
   * Set thread temperature (priority).
   */
  async setTemperature(
    id: string,
    temperature: number,
    reason?: string
  ): Promise<void> {
    const response = await fetch(`${this.baseURL}/threads/${id}/temperature`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ temperature, reason }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Set temperature failed: ${error}`);
    }
  }

  /**
   * Get events for a specific thread.
   */
  async getThreadEvents(threadId: string): Promise<ThreadEventsResponse> {
    const response = await fetch(`${this.baseURL}/threads/${threadId}/events`);
    if (!response.ok) {
      throw new Error(`Get thread events failed: ${response.statusText}`);
    }
    return (await response.json()) as ThreadEventsResponse;
  }

  // --------------------------------------------------------------------------
  // Personas
  // --------------------------------------------------------------------------

  /**
   * List all available personas.
   */
  async listPersonas(): Promise<PersonasResponse> {
    const response = await fetch(`${this.baseURL}/personas`);
    if (!response.ok) {
      throw new Error(`List personas failed: ${response.statusText}`);
    }
    return (await response.json()) as PersonasResponse;
  }

  /**
   * Get full persona details.
   */
  async getPersona(id: string): Promise<PersonaDetail | null> {
    try {
      const response = await fetch(`${this.baseURL}/personas/${id}`);
      if (!response.ok) return null;
      return (await response.json()) as PersonaDetail;
    } catch {
      return null;
    }
  }

  // --------------------------------------------------------------------------
  // Agents
  // --------------------------------------------------------------------------

  /**
   * List all registered agents.
   */
  async listAgents(): Promise<AgentsResponse> {
    const response = await fetch(`${this.baseURL}/agents`);
    if (!response.ok) {
      throw new Error(`List agents failed: ${response.statusText}`);
    }
    return (await response.json()) as AgentsResponse;
  }

  /**
   * Get agent details.
   */
  async getAgent(id: string): Promise<AgentDetail | null> {
    try {
      const response = await fetch(`${this.baseURL}/agents/${id}`);
      if (!response.ok) return null;
      return (await response.json()) as AgentDetail;
    } catch {
      return null;
    }
  }

  /**
   * Register a new agent.
   */
  async registerAgent(
    agentType: string,
    personaId?: string
  ): Promise<AgentDetail> {
    const response = await fetch(`${this.baseURL}/agents`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ agent_type: agentType, persona_id: personaId }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Register agent failed: ${error}`);
    }
    return (await response.json()) as AgentDetail;
  }

  /**
   * Terminate an agent.
   */
  async terminateAgent(id: string, reason?: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/agents/${id}`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reason }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Terminate agent failed: ${error}`);
    }
  }

  /**
   * Get the next available thread for an agent to work on.
   *
   * Returns the highest-temperature available thread. If autoClaim is true,
   * automatically claims the thread for the agent.
   */
  async getNextThread(
    agentId: string,
    autoClaim: boolean = false
  ): Promise<NextThreadResponse> {
    const params = new URLSearchParams();
    params.set("auto_claim", String(autoClaim));

    const response = await fetch(
      `${this.baseURL}/agents/${agentId}/next-thread?${params.toString()}`
    );
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Get next thread failed: ${error}`);
    }
    return (await response.json()) as NextThreadResponse;
  }

  // --------------------------------------------------------------------------
  // Escalations
  // --------------------------------------------------------------------------

  /**
   * List escalations.
   */
  async listEscalations(openOnly: boolean = true): Promise<EscalationsResponse> {
    const params = new URLSearchParams();
    params.set("open_only", String(openOnly));

    const response = await fetch(
      `${this.baseURL}/escalations?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`List escalations failed: ${response.statusText}`);
    }
    return (await response.json()) as EscalationsResponse;
  }

  /**
   * Get escalation details.
   */
  async getEscalation(id: string): Promise<EscalationDetail | null> {
    try {
      const response = await fetch(`${this.baseURL}/escalations/${id}`);
      if (!response.ok) return null;
      return (await response.json()) as EscalationDetail;
    } catch {
      return null;
    }
  }

  /**
   * Create a new escalation.
   */
  async createEscalation(
    params: CreateEscalationParams
  ): Promise<EscalationDetail> {
    const response = await fetch(`${this.baseURL}/escalations`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(params),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Create escalation failed: ${error}`);
    }
    return (await response.json()) as EscalationDetail;
  }

  /**
   * Acknowledge an escalation.
   */
  async acknowledgeEscalation(id: string, by: string): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/escalations/${id}/acknowledge`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ by }),
      }
    );
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Acknowledge escalation failed: ${error}`);
    }
  }

  /**
   * Resolve an escalation.
   */
  async resolveEscalation(
    id: string,
    by: string,
    resolution: string,
    selectedOption?: number
  ): Promise<void> {
    const response = await fetch(`${this.baseURL}/escalations/${id}/resolve`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        by,
        resolution,
        selected_option: selectedOption,
      }),
    });
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Resolve escalation failed: ${error}`);
    }
  }

  /**
   * Poll for escalation resolution with long-polling.
   *
   * This blocks until the escalation is resolved or the timeout expires.
   * Use this to wait for human decisions on escalations.
   */
  async pollEscalationResolution(
    id: string,
    timeoutSecs: number = 30
  ): Promise<EscalationPollResponse> {
    const params = new URLSearchParams();
    params.set("timeout", String(timeoutSecs));

    const response = await fetch(
      `${this.baseURL}/escalations/${id}/poll?${params.toString()}`,
      {
        // Set a client-side timeout slightly longer than the server timeout
        signal: AbortSignal.timeout((timeoutSecs + 5) * 1000),
      }
    );
    if (!response.ok) {
      const error = await response.text();
      throw new Error(`Poll escalation failed: ${error}`);
    }
    return (await response.json()) as EscalationPollResponse;
  }

  // --------------------------------------------------------------------------
  // Events
  // --------------------------------------------------------------------------

  /**
   * Get recent events.
   */
  async getEvents(since?: number, limit?: number): Promise<EventsResponse> {
    const response = await fetch(`${this.baseURL}/events`);
    if (!response.ok) {
      throw new Error(`Get events failed: ${response.statusText}`);
    }
    return (await response.json()) as EventsResponse;
  }
}
