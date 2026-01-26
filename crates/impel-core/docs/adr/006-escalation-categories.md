# ADR-006: Escalation Categories

## Status
Accepted

## Context
Human attention is scarce and valuable. We need a system that:
- Routes the right issues to humans
- Prevents escalation fatigue
- Provides enough context for quick decisions
- Tracks resolution for accountability

## Decision
Define **6 escalation categories** with distinct semantics:

| Category | Meaning | Default Priority | Example |
|----------|---------|------------------|---------|
| **Decision** | Strategic choice needed | Medium | "Direction A or B?" |
| **Novelty** | Unprecedented finding | High | "Is this result new?" |
| **Stuck** | Cannot proceed | High | "Need external data" |
| **Scope** | Boundary uncertainty | Medium | "Go deeper or wrap up?" |
| **Quality** | Quality concern | Medium | "Doesn't meet standards" |
| **Checkpoint** | Scheduled review | Low | "Weekly progress check" |

## Escalation Guidelines

### SHOULD Escalate When
- Multiple valid paths exist, wrong choice wastes significant resources
- Result would be significant enough to warrant verification if true
- Progress blocked > 2 cycles without resolution
- Quality checks fail repeatedly
- Explicit gate requires approval

### SHOULD NOT Escalate
- Routine decisions within established scope
- Technical implementation choices
- Recoverable errors (retry first)
- Questions answerable from constitution or prior work

## Consequences

### Positive
- Clear taxonomy reduces ambiguity
- Priority-based sorting focuses attention
- Categories enable routing to appropriate humans
- Lifecycle tracking ensures closure

### Negative
- Categories may not cover all cases
- Priority inflation risk ("everything is Critical")
- Requires discipline from agents

## Implementation

```rust
pub enum EscalationCategory {
    Decision,   // Strategic choice needed
    Novelty,    // Unprecedented finding
    Stuck,      // Cannot proceed
    Scope,      // Boundary uncertainty
    Quality,    // Quality concern
    Checkpoint, // Scheduled review
}

pub enum EscalationPriority {
    Low = 0,      // Next review session
    Medium = 1,   // Within 24 hours
    High = 2,     // Within a few hours
    Critical = 3, // Immediate attention
}

pub enum EscalationStatus {
    Pending,      // Awaiting acknowledgment
    Acknowledged, // Seen but not resolved
    Resolved,     // Completed with decision
    Dismissed,    // Closed without action
}
```

## Lifecycle
1. Agent creates escalation with category and description
2. Escalation appears in human alert queue, sorted by priority
3. Human acknowledges (marks seen)
4. Human resolves (makes decision, records outcome)
5. Resolution fed back to thread/agents

## Decision Escalations
For `Decision` category, escalations can include options:
```rust
pub struct EscalationOption {
    pub label: String,
    pub description: String,
    pub impact: Option<String>,
}
```
Human selects an option, which becomes the resolution.
