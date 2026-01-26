# ADR-007: Pull-Based Agent Model

## Status
Accepted

## Context
How should agents receive work assignments? Options:
1. **Push**: Central scheduler assigns work to agents
2. **Pull**: Agents query for available work and self-select
3. **Hybrid**: Mix of push and pull

## Decision
Use a **pull-based model** where agents autonomously select their own work.

### Agent Work Cycle
```
1. Query coordination state for available threads
2. Filter by own capabilities
3. Sort by temperature (prefer hotter threads)
4. Claim a thread (soft advisory claim)
5. Execute work
6. Post events with results
7. Release thread
8. Cool-down period
9. Repeat
```

### Work Selection Criteria
Agents consider:
- Thread state (must be `Active` or `Embryo`)
- Dependencies (all `blocked_by` must be resolved)
- Temperature (higher = more attractive)
- Required capabilities (thread can specify needs)
- Current claims (prefer unclaimed threads)

## Consequences

### Positive
- No central bottleneck for assignment
- Agents naturally gravitate to important work
- Graceful degradation if some agents fail
- Scales without coordination overhead
- Agents can specialize based on capabilities

### Negative
- Potential for contention on hot threads
- No global optimization of assignment
- Requires good temperature signals
- May need tie-breaking for identical temperatures

## Implementation

### Agent API
```rust
// Query available work
GET /threads/available?capabilities=code,testing

// Claim a thread (advisory)
POST /threads/{id}/claim
{ "agent_id": "code-agent-1" }

// Post work results
POST /events
{ "entity_id": "thread-123", "payload": { "Progress": { ... } } }

// Release thread
POST /threads/{id}/release
{ "agent_id": "code-agent-1" }
```

### Claiming Semantics
- Claims are **advisory**, not locks
- Multiple agents can work on same thread if needed
- Claims help avoid duplicate work
- Claims expire after inactivity

### Cycle Timing
| Phase | Duration |
|-------|----------|
| Poll for work | < 1 sec |
| Claim and setup | < 1 sec |
| Execute | 5 min - 2 hours |
| Post results | < 1 sec |
| Cool-down | 0 - 5 min |

## Pause Semantics
When system is paused:
1. Agents complete current cycle
2. On next poll, receive "paused" status
3. Wait until resume
4. Continue normal operation

This provides clean stopping points for human review.
