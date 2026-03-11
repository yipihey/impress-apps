# ADR-011: Counsel as Team Facilitator, Not Supervisor

## Status
Proposed

## Context
LangGraph's multi-agent patterns center on a Supervisor that decomposes tasks and delegates to workers. The current CounselEngine implementation is effectively this — a single centralized agent loop that receives tasks and executes them sequentially. But the existing impel ADRs describe teams of 5-10 agents coordinating stigmergically through shared state.

The key insight: Counsel's role is NOT to be a supervisor/orchestrator. Counsel is the PI's representative — a facilitator who:

1. **Surfaces work**: Shows the PI what the agent team is doing (ADR-009 four-level views)
2. **Routes escalations**: When agents hit decisions/novelty/blocks (ADR-006), Counsel presents these to the PI with context
3. **Translates intent**: When the PI gives a high-level directive, Counsel creates threads with appropriate temperature boosts and context, then the agent team self-organizes around them
4. **Maintains continuity**: Keeps conversation history, summaries, and long-term memory (ADR-015) across sessions

Counsel is the interface between human steering and agent-team activity — not the brain of the operation.

## Decision
Counsel does NOT assign work to other agents. Instead:

1. PI sends a request (email, HTTP, intent) → Counsel creates a Thread with initial context and temperature boost
2. Agent team members (Research, Code, Verification, etc. per ADR-005) pull threads based on temperature + capabilities (ADR-007)
3. When agents produce results, escalations, or child threads, Counsel observes and surfaces relevant updates to the PI
4. PI's feedback (via escalation resolution, temperature boosts, steering commands) flows back into the shared environment

### Migration from Current CounselEngine
The current single-agent NativeAgentLoop is phase 1 — Counsel doing all the work itself.

- **Phase 1 (current)**: Counsel receives tasks and executes them directly via NativeAgentLoop
- **Phase 2**: Counsel creates threads that multiple agent instances can pull. The NativeAgentLoop runs inside each agent, not just Counsel
- **Phase 3**: Counsel becomes primarily observational — monitoring team activity, surfacing summaries, and translating PI directives into environmental signals

## Consequences

### Positive
- Aligns with stigmergic coordination (ADR-001) — no central bottleneck
- CounselEngine evolves from "agent that does work" to "agent that facilitates work"
- Multiple NativeAgentLoop instances can run in parallel, each serving a different agent persona
- Natural scaling — add more agent instances without changing coordination logic

### Negative
- TaskOrchestrator becomes the mechanism for any agent (not just Counsel) to execute loops
- The pull-based model (ADR-007) needs implementation: available-threads query, claiming, temperature-sorted selection
- More complex to debug than single-agent execution

## References
- ADR-001 (stigmergic coordination)
- ADR-005 (agent types — Research, Code, Verification, Review, Synthesis, Orchestration)
- ADR-007 (pull-based agents)
- ADR-009 (four-level views — Counsel surfaces these to PI)
- Position paper §8 (internal scholarly culture — Counsel as reviewer/editor)
