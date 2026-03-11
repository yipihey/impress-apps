# ADR-014: Unified Human Checkpoint System

## Status
Proposed

## Context
Two systems address human-in-the-loop:

- **LangGraph**: Generic `interrupt()` / `Command(resume=value)` — mechanical pause/resume. Simple but semantically thin.
- **Existing ADR-006**: 6 escalation categories (Decision, Novelty, Stuck, Scope, Quality, Checkpoint) with priorities, lifecycle, and decision options. Semantically rich but lacks execution mechanics.

Neither is complete alone. We unify them.

## Decision
A **Human Checkpoint** is the unified primitive combining ADR-006's semantic richness with LangGraph's execution mechanics.

### Data Model

```rust
pub struct HumanCheckpoint {
    pub id: CheckpointId,
    pub thread_id: ThreadId,
    pub agent_id: AgentId,

    // Semantics (from ADR-006)
    pub category: EscalationCategory,      // Decision, Novelty, Stuck, Scope, Quality, Checkpoint
    pub priority: EscalationPriority,      // Low, Medium, High, Critical
    pub description: String,
    pub options: Vec<EscalationOption>,     // For Decision category
    pub context_summary: String,            // What the agent was doing

    // Mechanics (from LangGraph)
    pub execution_checkpoint_id: CheckpointId,  // Links to ADR-013 checkpoint
    pub blocks_execution: bool,             // true = interrupt, false = async review
    pub status: CheckpointStatus,           // Pending, Acknowledged, Resolved, Dismissed
    pub resolution: Option<Resolution>,     // Human's response
}

pub struct Resolution {
    pub decided_by: ActorId,
    pub decided_at: DateTime<Utc>,
    pub value: serde_json::Value,           // Arbitrary response payload
    pub selected_option: Option<usize>,     // Index into options (for Decision)
    pub feedback: Option<String>,           // Free-text human feedback
}
```

### Behavior

**Blocking checkpoint** (`blocks_execution: true`):
- Agent execution pauses
- State saved to checkpoint (ADR-013)
- Agent awaits resolution before resuming
- This is LangGraph's `interrupt()`

**Async checkpoint** (`blocks_execution: false`):
- Agent continues working
- Checkpoint queued for human review
- Resolution feeds back as a new event in the thread
- This is "FYI" escalation

### Integration Points

| Surface | Mechanism |
|---------|-----------|
| **Agent-side** | `HumanCheckpoint::blocking(category, description)` or `HumanCheckpoint::async_review(category, description)` |
| **Counsel-side** | Surfaces checkpoints to PI, sorted by priority (ADR-003 temperature applies — hot-thread checkpoints surface first) |
| **HTTP API** | `GET /api/checkpoints?status=pending`, `POST /api/checkpoints/{id}/resolve` |
| **Email** | Blocking checkpoints become emails to PI; reply resolves them |
| **Events** | `.checkpointCreated` and `.checkpointResolved` added to TaskEvent stream |

### Persona-Driven Thresholds
Using existing `escalationTendency` from agent personas (ADR-005):

- **High tendency** → more blocking checkpoints (cautious agents)
- **Low tendency** → more async reviews (autonomous agents)
- **Tool-level overrides** → `requiresApproval: true` for inherently risky operations (e.g., add_papers with >20 results)

## Consequences

### Positive
- Single system replaces both unimplemented escalation UI and missing interrupt mechanism
- Blocking checkpoints leverage checkpoint storage (ADR-013) for clean resume
- Async checkpoints are just items (ADR-012) with `impel/escalation@1.0` schema
- Temperature system (ADR-003) naturally prioritizes urgent checkpoints

### Negative
- Blocking checkpoints require checkpoint infrastructure (ADR-013) to be in place first
- Resolution routing adds complexity (email reply parsing, HTTP API, UI)
- Risk of escalation fatigue if thresholds are too low

## References
- ADR-006 (escalation categories — the semantic taxonomy)
- ADR-003 (temperature attention — prioritization of checkpoints)
- ADR-005 (agent personas — escalationTendency)
- ADR-013 (checkpointing — execution state for blocking checkpoints)
- Position paper §8.4 (PI reads review, requests comparison run)
