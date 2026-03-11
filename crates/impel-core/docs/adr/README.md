# impel Architecture Decision Records

This directory contains the Architecture Decision Records (ADRs) for impel — the AI agent orchestration layer of the impress research operating environment.

## Index

### Foundation (001-009)

| ADR | Title | Status |
|-----|-------|--------|
| [001](001-stigmergic-coordination.md) | Stigmergic Coordination | Accepted |
| [002](002-event-sourcing.md) | Event Sourcing | Accepted |
| [003](003-temperature-attention.md) | Temperature-Based Attention | Accepted |
| [004](004-thread-dag.md) | Thread DAG | Accepted |
| [005](005-agent-types.md) | Agent Types and Personas | Accepted |
| [006](006-escalation-categories.md) | Escalation Categories | Accepted |
| [007](007-pull-based-agents.md) | Pull-Based Agent Selection | Accepted |
| [008](008-integration-architecture.md) | Integration Architecture | Accepted |
| [009](009-four-level-views.md) | Four-Level Views | Accepted |

### LangGraph-Informed Extensions (010-017)

These ADRs were developed after studying LangGraph's agent orchestration patterns and reconciling them with the existing stigmergic, event-sourced, pull-based architecture.

| ADR | Title | Status | Key References |
|-----|-------|--------|----------------|
| [010](010-langgraph-lessons.md) | What LangGraph Teaches (and What We Reject) | Proposed | 001, 002, 003, 004, 007 |
| [011](011-counsel-as-facilitator.md) | Counsel as Team Facilitator, Not Supervisor | Proposed | 001, 005, 007, 009 |
| [012](012-item-graph-output-protocol.md) | Item Graph Output Protocol | Proposed | 002, position paper §2.2 |
| [013](013-checkpointing-event-replay.md) | Checkpointing via Event Replay | Proposed | 002, 004 |
| [014](014-unified-human-checkpoints.md) | Unified Human Checkpoint System | Proposed | 003, 006, 013 |
| [015](015-long-term-memory.md) | Long-Term Memory Architecture | Proposed | 005, 012, position paper §2.2 |
| [016](016-streaming-observability.md) | Streaming and Progress Observability | Proposed | 009, 014 |
| [017](017-concurrent-input-handling.md) | Concurrent Task Input Handling | Proposed | 007, 013 |

## Dependency Graph

```
010 (LangGraph Lessons) ──── frames all of ────→ 011-017

011 (Counsel Facilitator) ←── 001 (Stigmergy)
                          ←── 005 (Agent Types)
                          ←── 007 (Pull-Based)

012 (Item Graph Output) ←── 002 (Event Sourcing)
                        ←── position paper §2.2

013 (Checkpointing) ←── 002 (Event Sourcing)
                    ←── 004 (Thread DAG)

014 (Human Checkpoints) ←── 006 (Escalation Categories)
                        ←── 003 (Temperature Attention)
                        ←── 013 (Checkpointing)

015 (Long-Term Memory) ←── 012 (Item Graph Output)
                       ←── 005 (Agent Types)

016 (Streaming) ←── 009 (Four-Level Views)
                ←── 014 (Human Checkpoints)

017 (Concurrent Input) ←── 007 (Pull-Based)
                       ←── 013 (Checkpointing)
```

## Implementation Priority

| Priority | ADR | Rationale |
|----------|-----|-----------|
| **P0** | 014 (Human Checkpoints) | Most impactful gap — PI must approve/reject agent actions |
| **P0** | 016 (Streaming) | Token streaming dramatically improves UX |
| **P1** | 013 (Checkpointing) | Foundation for HITL and fault tolerance |
| **P1** | 010 (LangGraph Lessons) | Meta-ADR — frames all others |
| **P2** | 011 (Counsel Facilitator) | Vision document — guides CounselEngine evolution |
| **P2** | 012 (Item Graph Output) | Requires impress-core item store maturity |
| **P2** | 015 (Long-Term Memory) | Enhances quality over time |
| **P3** | 017 (Concurrent Input) | Practical but not urgent |

## Cross-Reference: Position Paper

The [position paper](../position-paper-cognitive-architecture_4.md) provides the theoretical foundation. Key mappings:

- **§2.2 Item Envelope** → ADR-012 (output protocol), ADR-015 (memories as items)
- **§2.2 Operations as Overlay Items** → ADR-012 (agent runs are items)
- **§7 Private-by-Default** → ADR-012 (visibility field on output items)
- **§8 Internal Scholarly Culture** → ADR-011 (Counsel as reviewer/editor, not supervisor)
