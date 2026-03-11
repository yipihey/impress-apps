# ADR-012: Item Graph Output Protocol

## Status
Proposed

## Context
LangGraph uses typed state schemas with reducers — nodes operate on mutable state and return partial updates. The position paper describes a richer model: every research artifact is an item with a typed envelope (id, schema, author, author_kind, payload, refs, tags, visibility). Existing ADR-002 mandates event sourcing.

The resolution: agent execution uses lightweight ephemeral internal state (current CounselEngine models: messages, tool results). But everything that exits an agent's work becomes a proper item in the shared graph.

## Decision

### Internal Execution State (Ephemeral, Per-Agent-Loop)
- Message history (`[AIMessage]` — the conversation with the LLM)
- Tool execution records (tool name, input, output, duration)
- Round counter, token counts
- This is CounselEngine's current model. No change needed.

### Output Items (Persistent, in Shared Item Graph)
Every completed task produces an **item** with the position paper's envelope:

```rust
pub struct ItemEnvelope {
    pub id: ItemId,
    pub schema: String,          // e.g. "impel/task-result@1.0"
    pub author: ActorId,
    pub author_kind: AuthorKind, // Human | Agent
    pub payload: serde_json::Value,
    pub refs: Vec<TypedEdge>,    // DerivedFrom, Cites, InResponseTo, ProducedBy, Annotates
    pub tags: Vec<String>,
    pub visibility: Visibility,  // Private (default), Team, Public
    pub created_at: DateTime<Utc>,
}
```

- **Visibility**: Private by default (position paper §7 — agent output is Private-by-default)
- **Refs**: Typed edges to inputs (DerivedFrom), cited papers (Cites), parent thread (InResponseTo)
- Tool results that produce artifacts (papers found, figures generated) become their own items with `ProducedBy` edges to the task-result item
- Escalations are items with `schema: impel/escalation@1.0` and an `Annotates` edge to the thread

### Reducer-as-Projection
When computing the "current state of a thread," project over all items with edges to that thread:

| Dimension | Projection Logic |
|-----------|-----------------|
| Messages | Ordered by timestamp (append semantics) |
| Artifacts | Collected via DerivedFrom/ProducedBy edges |
| Status | State machine derived from latest status-change event |
| Temperature | Computed from recent activity, breakthroughs, human boosts (ADR-003) |

This is event sourcing (ADR-002) expressed through the item graph (position paper §2.2). LangGraph's reducer concept maps to projection functions.

### Output Schemas
| Schema | Purpose |
|--------|---------|
| `impel/task-result@1.0` | Completed task output |
| `impel/escalation@1.0` | Human checkpoint / escalation |
| `impel/digest@1.0` | Summary / compression of thread activity |
| `impel/agent-run@1.0` | Metadata about an agent execution cycle |

## Consequences

### Positive
- Clean separation between ephemeral execution and persistent outputs
- All outputs are first-class items — searchable, provenanced, versioned
- Projections provide flexible views over the same event history

### Negative
- No separate `TaskExecutionState` struct in Rust — use item graph projections instead
- Schema definitions and validation needed for each output type
- SharedTaskBridge (already exists) evolves into the formal output protocol

## References
- ADR-002 (event sourcing)
- Position paper §2.2 (item envelope)
- Position paper §2.2 "Operations as overlay items"
