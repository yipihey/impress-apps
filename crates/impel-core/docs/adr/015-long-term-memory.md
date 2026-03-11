# ADR-015: Long-Term Memory Architecture

## Status
Proposed

## Context
LangGraph distinguishes short-term memory (thread-scoped, via checkpoints) and long-term memory (cross-thread, via Store abstraction with namespace/key/value + semantic search). The position paper's item graph is a natural substrate for both.

Current impel has short-term memory (conversation history per task) and context compression (summarization), but no structured cross-session learning.

## Decision
Implement long-term memory as items in the shared graph, organized into three types.

### Memory Types

**1. Semantic Memory — Facts**
Knowledge about the research domain, user preferences, and frequent collaborators.

```rust
// Schema: impel/memory-fact@1.0
{
    "fact": "PI prefers ADS over arXiv for astrophysics searches",
    "confidence": 0.9,
    "source_thread": "thread-123"
}
// Edges: Annotates the persona or user profile
```

**2. Episodic Memory — Patterns**
Successful task patterns extracted as few-shot examples.

```rust
// Schema: impel/memory-episode@1.0
{
    "task_type": "literature survey",
    "approach": "search ADS first, then check citing papers, filter by year",
    "outcome": "found 23 relevant papers in 3 rounds",
    "quality_rating": 0.85
}
// Edges: DerivedFrom the completed task-result item
```

**3. Procedural Memory — Instructions**
Learned rules that refine agent behavior over time.

```rust
// Schema: impel/memory-instruction@1.0
{
    "rule": "Always check for Van Leer limiter convergence above level 10",
    "source": "PI feedback on thread-456",
    "applies_to": ["simulation", "AMR"]
}
// Edges: Annotates the persona; InResponseTo the original feedback
```

### Memory Lifecycle

| Phase | Timing | Description |
|-------|--------|-------------|
| **Write** | Background, post-task | After task completion, a background process extracts memories. No latency impact during execution. |
| **Read** | Hot path, pre-iteration | Before each agent loop iteration, retrieve relevant memories by namespace + optional embedding similarity. Inject into system prompt. |
| **Update** | On new evidence | New evidence can `Supersede` old memories (position paper edge type). Old memories remain in history but are deprioritized. |

### Namespace Hierarchy
Mapped to item graph paths:

```
impel/memory/user/{user_id}/facts/       — user-specific semantic memory
impel/memory/persona/{persona_id}/instructions/ — persona-specific procedural memory
impel/memory/domain/{topic}/episodes/     — domain-specific episodic memory
```

### Retrieval Strategy
1. **Exact match**: Namespace + tag filtering for known contexts
2. **Semantic search**: Embedding similarity for open-ended retrieval (reuse imbib's NLEmbedding infrastructure)
3. **Recency weighting**: More recent memories preferred, with confidence decay on older entries

## Consequences

### Positive
- Memories are items — they participate in the full graph (searchable, provenanced, versioned)
- Agents improve over time by accumulating domain knowledge
- PI corrections become procedural memories, preventing repeated mistakes
- Privacy: memories inherit Private visibility by default

### Negative
- Embedding computation needed (can reuse imbib's NLEmbedding infrastructure)
- Memory extraction is a background agent task (could be a Review-type agent per ADR-005)
- Risk of stale memories — requires confidence decay and supersession mechanics

## References
- Position paper §2.2 (item envelope)
- ADR-005 (Review agent could maintain memories)
- ADR-012 (item graph output protocol — memories are output items)
- imbib ADR-022 (embedding index strategy)
