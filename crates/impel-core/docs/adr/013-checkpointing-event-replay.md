# ADR-013: Checkpointing via Event Replay

## Status
Proposed

## Context
LangGraph checkpoints state at every super-step, enabling replay (re-execute from step N), fork (branch with modified state), and time travel (browse execution history). Existing ADR-002 already chose event sourcing, which naturally supports these capabilities — replaying events to any point IS checkpointing.

## Decision
Implement checkpointing as event stream snapshots.

### Event Log
Already mandated by ADR-002: every agent action within a thread is an immutable event with sequence number, timestamp, actor, and payload.

### Snapshot Checkpoints
At configurable intervals (every N events, or every agent round), store a serialized projection of the current thread state. This avoids replaying the entire event stream for common operations.

```rust
pub struct Checkpoint {
    pub id: CheckpointId,
    pub thread_id: ThreadId,
    pub sequence_at: u64,           // Event sequence number at snapshot time
    pub state_json: serde_json::Value,
    pub created_at: DateTime<Utc>,
    pub parent_checkpoint_id: Option<CheckpointId>,
}

pub trait CheckpointStore {
    fn save(&self, checkpoint: Checkpoint) -> Result<()>;
    fn load(&self, id: CheckpointId) -> Result<Option<Checkpoint>>;
    fn latest_for_thread(&self, thread_id: ThreadId) -> Result<Option<Checkpoint>>;
    fn list_for_thread(&self, thread_id: ThreadId) -> Result<Vec<Checkpoint>>;
}
```

Storage: SQLite (GRDB) — same database as the event store.

### Replay
To replay from checkpoint C:
1. Load snapshot at C
2. Replay events after C's sequence number
3. Nodes after the checkpoint re-execute; earlier results are already in the snapshot

### Fork
1. Create a new thread with a copy of the snapshot at checkpoint C
2. Optionally apply state modifications
3. New thread gets a `DerivedFrom` edge to the original (ADR-004)
4. New events accumulate independently

### Fault Tolerance
If an agent crashes mid-execution, the last checkpoint provides a clean restart point. Events from the failed execution are preserved for debugging (they're immutable per ADR-002).

## Phasing

| Phase | Capability | Enables |
|-------|-----------|---------|
| **Phase 1** | Snapshot at each agent round | Fault tolerance, basic resume |
| **Phase 2** | Replay API | Debugging expensive runs |
| **Phase 3** | Fork API | "What-if" exploration |

## Implementation
- **Rust**: `Checkpoint`, `CheckpointStore` trait in `crates/impel-core/`
- **Swift**: `TaskOrchestrator.replay(threadID:, fromCheckpoint:)`, `TaskOrchestrator.fork(threadID:, checkpoint:, stateUpdate:)`
- **Storage**: SQLite (GRDB) — same DB as event store

## Consequences

### Positive
- Enables fault-tolerant agent execution without losing partial results
- Natural fit with event sourcing (ADR-002) — snapshots are just cached projections
- Fork creates new threads in the DAG (ADR-004 SpawnedFrom / DerivedFrom)

### Negative
- Snapshot storage grows (mitigated by compaction — drop old snapshots when events are stable)
- Replay/fork require the thread's tool environment to still be available
- Serialization format must be stable across versions

## References
- ADR-002 (event sourcing)
- ADR-004 (thread DAG — fork creates DerivedFrom edges)
- LangGraph checkpointing concepts
