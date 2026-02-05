/**
 * HTTP client for impart API
 */

export interface ImpartStatus {
  status: string;
  app: string;
  version: string;
  port: number;
  accounts: number;
}

export interface LogEntry {
  id: string;
  timestamp: string;
  level: string;
  category: string;
  message: string;
}

export interface LogsResponse {
  status: string;
  data: {
    entries: LogEntry[];
    count: number;
    totalInStore: number;
  };
}

export interface ResearchConversation {
  id: string;
  title: string;
  participants: string[];
  createdAt: string;
  lastActivityAt: string;
  summaryText?: string;
  isArchived: boolean;
  tags: string[];
  parentConversationId?: string;
}

export interface ResearchMessage {
  id: string;
  sequence: number;
  senderRole: string;
  senderId: string;
  modelUsed?: string;
  contentMarkdown: string;
  sentAt: string;
  tokenCount?: number;
  processingDurationMs?: number;
  mentionedArtifactURIs: string[];
}

export interface ConversationStatistics {
  messageCount: number;
  humanMessageCount: number;
  counselMessageCount: number;
  artifactCount: number;
  paperCount: number;
  repositoryCount: number;
  totalTokens: number;
  duration: number;
  branchCount: number;
}

export interface ConversationsResponse {
  status: string;
  count: number;
  total: number;
  conversations: ResearchConversation[];
}

export interface ConversationDetailResponse {
  status: string;
  conversation: ResearchConversation;
  messages: ResearchMessage[];
  statistics: ConversationStatistics;
}

export interface CreateConversationResponse {
  status: string;
  conversationId: string;
  title: string;
  participants: string[];
  message: string;
}

export interface AddMessageResponse {
  status: string;
  conversationId: string;
  senderRole: string;
  senderId: string;
  message: string;
}

export interface BranchConversationResponse {
  status: string;
  conversationId: string;
  fromMessageId: string;
  title: string;
  message: string;
}

export interface UpdateConversationResponse {
  status: string;
  conversationId: string;
  message: string;
}

export interface RecordArtifactResponse {
  status: string;
  conversationId: string;
  uri: string;
  type: string;
  message: string;
}

export interface RecordDecisionResponse {
  status: string;
  conversationId: string;
  description: string;
  message: string;
}

export class ImpartClient {
  constructor(private baseURL: string) {}

  /**
   * Check if impart is running and accessible.
   */
  async checkStatus(): Promise<ImpartStatus | null> {
    try {
      const response = await fetch(`${this.baseURL}/api/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImpartStatus;
    } catch {
      return null;
    }
  }

  /**
   * Get log entries from the app's in-memory log store.
   */
  async getLogs(
    options: {
      limit?: number;
      level?: string;
      category?: string;
      search?: string;
      after?: string;
    } = {}
  ): Promise<LogsResponse> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.level) params.set("level", options.level);
    if (options.category) params.set("category", options.category);
    if (options.search) params.set("search", options.search);
    if (options.after) params.set("after", options.after);

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/logs?${query}`
      : `${this.baseURL}/api/logs`;

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Get logs failed: ${response.statusText}`);
    }
    return (await response.json()) as LogsResponse;
  }

  // ============================================================
  // Research Conversation Read Methods
  // ============================================================

  /**
   * List research conversations.
   */
  async listConversations(options: {
    limit?: number;
    offset?: number;
    includeArchived?: boolean;
  } = {}): Promise<ConversationsResponse> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.offset) params.set("offset", String(options.offset));
    if (options.includeArchived) params.set("includeArchived", "true");

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/research/conversations?${query}`
      : `${this.baseURL}/api/research/conversations`;

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`List conversations failed: ${response.statusText}`);
    }
    return (await response.json()) as ConversationsResponse;
  }

  /**
   * Get a specific research conversation with messages and statistics.
   */
  async getConversation(id: string): Promise<ConversationDetailResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${id}`
    );
    if (!response.ok) {
      throw new Error(`Get conversation failed: ${response.statusText}`);
    }
    return (await response.json()) as ConversationDetailResponse;
  }

  // ============================================================
  // Research Conversation Write Methods
  // ============================================================

  /**
   * Create a new research conversation.
   */
  async createConversation(
    title: string,
    participants?: string[]
  ): Promise<CreateConversationResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title, participants: participants ?? [] }),
      }
    );
    if (!response.ok) {
      throw new Error(`Create conversation failed: ${response.statusText}`);
    }
    return (await response.json()) as CreateConversationResponse;
  }

  /**
   * Add a message to a research conversation.
   */
  async addMessage(
    conversationId: string,
    senderRole: "human" | "counsel" | "system",
    senderId: string,
    content: string,
    causationId?: string
  ): Promise<AddMessageResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}/messages`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ senderRole, senderId, content, causationId }),
      }
    );
    if (!response.ok) {
      throw new Error(`Add message failed: ${response.statusText}`);
    }
    return (await response.json()) as AddMessageResponse;
  }

  /**
   * Branch a conversation from a specific message.
   */
  async branchConversation(
    conversationId: string,
    fromMessageId: string,
    title: string
  ): Promise<BranchConversationResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}/branch`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ fromMessageId, title }),
      }
    );
    if (!response.ok) {
      throw new Error(`Branch conversation failed: ${response.statusText}`);
    }
    return (await response.json()) as BranchConversationResponse;
  }

  /**
   * Update conversation metadata.
   */
  async updateConversation(
    conversationId: string,
    updates: { title?: string; summary?: string; tags?: string[] }
  ): Promise<UpdateConversationResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}`,
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(updates),
      }
    );
    if (!response.ok) {
      throw new Error(`Update conversation failed: ${response.statusText}`);
    }
    return (await response.json()) as UpdateConversationResponse;
  }

  /**
   * Archive a conversation.
   */
  async archiveConversation(
    conversationId: string
  ): Promise<UpdateConversationResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}/archive`,
      {
        method: "PATCH",
      }
    );
    if (!response.ok) {
      throw new Error(`Archive conversation failed: ${response.statusText}`);
    }
    return (await response.json()) as UpdateConversationResponse;
  }

  /**
   * Record an artifact reference in a conversation.
   */
  async recordArtifact(
    conversationId: string,
    uri: string,
    type: string,
    displayName?: string
  ): Promise<RecordArtifactResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}/artifacts`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ uri, type, displayName }),
      }
    );
    if (!response.ok) {
      throw new Error(`Record artifact failed: ${response.statusText}`);
    }
    return (await response.json()) as RecordArtifactResponse;
  }

  /**
   * Record a decision in a conversation.
   */
  async recordDecision(
    conversationId: string,
    description: string,
    rationale: string
  ): Promise<RecordDecisionResponse> {
    const response = await fetch(
      `${this.baseURL}/api/research/conversations/${conversationId}/decisions`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ description, rationale }),
      }
    );
    if (!response.ok) {
      throw new Error(`Record decision failed: ${response.statusText}`);
    }
    return (await response.json()) as RecordDecisionResponse;
  }
}
