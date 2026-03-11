# ADR-017: Concurrent Task Input Handling

## Status
Proposed

## Context
LangGraph documents "double-texting" — when a user sends new input while an agent is still processing. Four strategies: reject (409), enqueue (queue behind), interrupt (pause current), rollback (discard current).

Current impel has no handling — each submission creates an independent task. This works for email (messages arrive serially) but breaks down for interactive use where the PI may redirect an in-progress task.

## Decision
**Enqueue** as default, **Interrupt** as opt-in. No rollback, no reject.

### Enqueue (Default)
If an agent is actively working on a thread, new messages to that thread queue in order.

- After current execution completes, the next queued message triggers a new execution round
- Natural for email (messages arrive serially)
- Natural for pull-based model (ADR-007) — agent finishes one cycle, picks up the next queued item
- Queue is per-thread, FIFO ordered

### Interrupt (Opt-In)
Enabled via `TaskRequest.interruptActive: Bool`. When true:

1. Current execution receives a cancellation signal
2. Agent completes current tool call (no mid-tool interruption — tools may have side effects)
3. Checkpoint saved (ADR-013)
4. New message begins execution from the interrupted state
5. Useful for interactive UI where the PI realizes they asked the wrong question

### Why No Rollback
Partial results are valuable in research. Completed tool calls may have produced artifacts, found papers, or written files. Discarding that work loses real value.

### Why No Reject
Poor UX. The PI should never be told "please wait." The system absorbs input and handles it appropriately.

## Implementation

```rust
pub struct ThreadExecutionState {
    pub thread_id: ThreadId,
    pub active_agent: Option<AgentId>,     // Currently executing agent
    pub pending_messages: Vec<QueuedMessage>,
    pub accepts_interrupt: bool,
}

pub struct QueuedMessage {
    pub id: MessageId,
    pub content: String,
    pub queued_at: DateTime<Utc>,
    pub interrupt_requested: bool,
}
```

### Execution Flow
1. New message arrives for thread T
2. If no agent is active on T → start execution immediately
3. If an agent is active on T:
   - If `interrupt_requested` → send cancellation signal, save checkpoint, start new execution
   - Otherwise → append to `pending_messages` queue
4. On execution complete → check `pending_messages`, auto-start next if present
5. Interrupt: cooperative cancellation via `Task.isCancelled` check after each tool execution

## Consequences

### Positive
- PI never blocked from sending input
- Enqueue preserves message ordering and completeness
- Interrupt enables responsive course-correction
- Email gateway naturally enqueues (SMTP delivers one at a time)

### Negative
- Queue management adds complexity to TaskOrchestrator
- Interrupt + checkpoint requires ADR-013 infrastructure
- Long queues could indicate the PI is outpacing agent capacity (metric to monitor)

## References
- LangGraph double-texting patterns
- ADR-007 (pull-based agents — enqueue aligns with pull model)
- ADR-013 (checkpointing — required for interrupt/resume)
- Existing TaskOrchestrator.swift
