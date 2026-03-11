# ADR-016: Streaming and Progress Observability

## Status
Proposed

## Context
LangGraph supports 7 streaming modes (values, updates, messages/tokens, custom, checkpoints, tasks, debug). Current impel has tool-level events (toolStart/toolComplete) via polling. No token streaming.

Responsive UX requires that the PI can see what agents are doing in real time — not just final results.

## Decision
Extend `TaskEvent` incrementally across four phases.

### Phase 1 — Token Streaming (Highest UX Impact)

New event type:
```swift
case token(threadID: ThreadId, agentID: AgentId, text: String)
```

- Wire from AnthropicProvider's streaming response through NativeAgentLoop's progress callback
- Surface via SSE on `GET /api/threads/{id}/stream`
- Counsel's UI shows live agent reasoning

### Phase 2 — Custom Tool Progress

New event type:
```swift
case progress(threadID: ThreadId, toolName: String, message: String)
```

- Tools emit progress during execution (e.g., "Searching ADS... 150 results... filtering to 23")
- Tool registry passes a `ProgressWriter` handle to tool execution functions
- Enables meaningful status indicators beyond "tool running..."

### Phase 3 — Checkpoint Events

New event types:
```swift
case checkpointSaved(threadID: ThreadId, checkpointID: CheckpointId)
case humanCheckpointCreated(threadID: ThreadId, checkpointID: CheckpointId, category: EscalationCategory)
```

- Enables UI to show when human attention is needed (badge, notification)
- Integrates with ADR-014 unified human checkpoints

### Phase 4 — State Update Streaming

New event type:
```swift
case stateUpdate(threadID: ThreadId, key: String, summary: String)
```

- Emitted when thread projections change (temperature shift, status change, new artifact)
- Enables the four-level views (ADR-009) to update in real time

### Transport

All events flow through existing infrastructure:

| Channel | Mechanism |
|---------|-----------|
| In-process | `TaskOrchestrator.events(for:) -> AsyncStream<TaskEvent>` (already exists) |
| HTTP | SSE on `/api/threads/{id}/stream` (already exists as `/api/tasks/{id}/stream`) |
| Cross-app | Darwin notifications (ImpressNotification) |

### Filtering
SSE endpoint supports selective streaming:
```
GET /api/threads/{id}/stream?modes=tokens,checkpoints
```

This prevents token-volume events from overwhelming clients that only care about structural changes.

## Consequences

### Positive
- Token streaming dramatically improves UX — PI sees agent thinking live
- Tool progress provides meaningful status beyond binary "running/done"
- Checkpoint events enable proactive UI for human attention
- Phased rollout — each phase delivers standalone value

### Negative
- Token streaming increases event volume significantly — clients must filter
- AnthropicProvider needs streaming response support (may already have it)
- SSE connection management adds complexity for multiple concurrent threads

## References
- LangGraph streaming modes
- Existing TaskEvent enum in TaskOrchestrator.swift
- ADR-009 (four-level views — benefit from real-time state updates)
- ADR-014 (unified human checkpoints — checkpoint events)
