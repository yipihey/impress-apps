# ADR-005: Agent Types

## Status
Accepted

## Context
AI agents need specialization to work effectively. Key questions:
- Should agents be generalists or specialists?
- How do we balance task cost vs coordination cost?
- What capabilities should each type have?

## Decision
Define **6 agent archetypes** with distinct capabilities:

| Type | Responsibility | Key Capabilities |
|------|----------------|------------------|
| **Research** | Hypothesis, analysis, writing | LiteratureSearch, DataCollection, Summarization |
| **Code** | Implementation, testing | CodeGeneration, CodeReview, Testing |
| **Verification** | Check claims, run code | Testing, Validation, Reproduction |
| **Adversarial** | Find flaws, challenge | CritiqueGeneration, WeaknessIdentification |
| **Review** | Synthesize, consolidate | QualityAssessment, DocumentReview |
| **Librarian** | Literature, references | ReferenceManagement, CitationFormatting |

## Specialization Guidelines

### When Specialists Win
- Deep skill matters for the task
- Tool sets are disjoint
- Verification must be independent from production
- Parallelism helps throughput

### When Generalists Win
- Task requires integrated judgment
- Handoff overhead dominates
- Boundaries are ambiguous

### Invariants (Always Enforce)
1. **Verifier ≠ Producer**: Verification agents must be separate from agents that produced the work
2. **Adversary ≠ Team**: Adversarial agents must be independent
3. **Operator ≠ Research**: Meta-coordination separate from research work

## Consequences

### Positive
- Clear responsibilities reduce confusion
- Capability matching enables better scheduling
- Specialization improves quality in specific areas
- Independence enables true verification

### Negative
- Handoff overhead between specialists
- May need generalist fallback for edge cases
- Capability definitions require maintenance

## Implementation

```rust
pub enum AgentType {
    Research,
    Code,
    Verification,
    Adversarial,
    Review,
    Librarian,
}

impl AgentType {
    pub fn capabilities(&self) -> Vec<AgentCapability> {
        match self {
            AgentType::Research => vec![
                AgentCapability::LiteratureSearch,
                AgentCapability::DataCollection,
                AgentCapability::Summarization,
            ],
            // ... other types
        }
    }
}
```

## Operator Agents (Advanced)
A separate layer of agents that manage research agents:
- **Spawner**: Creates agent instances
- **Monitor**: Watches health and progress
- **Diagnostician**: Investigates failures
- **Scaler**: Adjusts population to workload
- **Configurator**: Manages templates

Operator agents have additional capabilities: spawn-agent, terminate-agent, read-metrics, diagnose, modify-config.
