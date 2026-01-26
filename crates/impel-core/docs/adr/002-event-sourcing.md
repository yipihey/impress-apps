# ADR-002: Event Sourcing

## Status
Accepted

## Context
Impel needs a robust data model that:
- Provides complete audit trail of all changes
- Supports time-travel and debugging
- Enables multiple projections of the same data
- Works reliably with concurrent agents

Options considered:
1. **Traditional CRUD**: Direct state mutation
2. **Event sourcing**: Append-only event log with materialized views
3. **CQRS without events**: Separate read/write models

## Decision
Use **event sourcing** with SQLite as the primary storage.

All state changes are recorded as immutable events. Current state is derived by projecting events into materialized views.

## Consequences

### Positive
- Complete audit trail - every change is recorded
- Time-travel debugging - replay events to any point
- Multiple views - different projections for different needs
- Natural fit for distributed systems
- Easy backup/replication - just copy the event log

### Negative
- Storage grows over time (mitigated by compaction/snapshots)
- Queries require projections (materialized views help)
- Schema evolution requires care
- Learning curve for developers

## Implementation

### Event Structure
```rust
pub struct Event {
    pub id: EventId,
    pub sequence: u64,
    pub timestamp: DateTime<Utc>,
    pub entity_id: String,
    pub entity_type: EntityType,
    pub payload: EventPayload,
    pub actor: Option<String>,
    pub correlation_id: Option<String>,
    pub causation_id: Option<EventId>,
}
```

### Storage
- SQLite for persistence
- In-memory store for testing
- Event store trait for abstraction

### Projections
- ThreadProjection: Current thread states
- AgentProjection: Agent registry state
- SystemProjection: System-wide state

## References
- Fowler, Martin. "Event Sourcing" (2005)
- Young, Greg. "CQRS and Event Sourcing" (2010)
