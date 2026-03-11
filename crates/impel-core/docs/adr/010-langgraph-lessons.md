# ADR-010: What LangGraph Teaches (and What We Reject)

## Status
Proposed

## Context
LangGraph (LangChain's agent orchestration framework) provides a mature Python-based graph runtime for agent execution. We studied its course curriculum and documentation to evaluate which patterns should inform impel's Rust/Swift architecture. This ADR summarizes what we adopt, what we adapt, and what we consciously reject.

## Decision

### What We Adopt
- **Checkpointing at every step** (ADR-013) — enables replay, fork, fault tolerance
- **Interrupt/resume primitives** (ADR-014) — mechanical pause/resume for human-in-the-loop
- **Token-by-token streaming** (ADR-016) — critical for responsive UX
- **Long-term memory as a first-class concern** (ADR-015) — semantic/episodic/procedural memory types
- **Typed state with explicit merge semantics** — adapted as projection functions over event streams (ADR-012)
- **Double-texting strategies** (ADR-017) — enqueue/interrupt for concurrent inputs

### What We Adapt
LangGraph concepts reframed to fit our existing architecture:

| LangGraph Concept | impel Equivalent | Why |
|-------------------|------------------|-----|
| **Reducers** | Event stream projections | ADR-002 already decided event sourcing; reducers are just projection logic |
| **Conditional edges** | Temperature-weighted attention | ADR-003 already provides dynamic routing via gradients |
| **Subgraphs** | Thread DAG | ADR-004 already provides hierarchical decomposition via SpawnedFrom + dependency edges |
| **Send() for map-reduce** | Thread spawning | Agents create child threads; DAG structure + pull-based selection = emergent parallelism |

### What We Reject
- **Central graph runtime** — conflicts with stigmergic coordination (ADR-001). In LangGraph, the runtime decides execution order. In impel, the environment (temperature + shared state) guides agents. Individual agents may use structured internal workflows (ReAct loops), but inter-agent coordination is emergent.
- **Supervisor pattern** — conflicts with ADR-001 and ADR-007. No agent decides what other agents work on. Counsel facilitates but doesn't direct. See ADR-011.
- **Structural routing functions** — temperature IS our routing signal (ADR-003). Adding deterministic routing functions would undermine the emergent coordination model.

## Consequences
New ADRs 011-017 extend the existing 001-009 series with LangGraph-informed capabilities while preserving the stigmergic, event-sourced, pull-based architecture.

## References
- ADR-001 (stigmergic coordination)
- ADR-002 (event sourcing)
- ADR-003 (temperature attention)
- ADR-004 (thread DAG)
- ADR-007 (pull-based agents)
- LangGraph documentation and course curriculum
