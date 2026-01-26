# ADR-004: Thread DAG Structure

## Status
Accepted

## Context
Research work naturally forms a graph of dependencies and relationships:
- Some threads depend on others completing first
- Threads can spawn child threads
- Threads can be merged when work converges
- Related threads share context

Options considered:
1. **Flat list**: Simple but loses structure
2. **Tree hierarchy**: Parent-child only
3. **DAG (Directed Acyclic Graph)**: Full dependency modeling

## Decision
Model threads as a **Directed Acyclic Graph (DAG)** with typed edges.

### Edge Types
```rust
pub enum EdgeType {
    Requires,      // Hard dependency - must complete first
    SpawnedFrom,   // Created as child of parent thread
    MergedFrom,    // Thread is result of merging others
    Related,       // Soft link for context sharing
}
```

### Thread Relationships
- **blocked_by**: Threads that must complete before this one can proceed
- **blocks**: Threads waiting on this one
- **parent_id**: Thread this was spawned from
- **children**: Threads spawned from this one

## Consequences

### Positive
- Captures real research workflow structure
- Enables dependency-aware scheduling
- Supports thread merging and splitting
- Provides context for related work

### Negative
- More complex than flat structure
- Must prevent cycles (DAG invariant)
- Requires graph algorithms for traversal
- UI must visualize graph effectively

## Implementation

### Data Model
```rust
pub struct Thread {
    pub id: ThreadId,
    pub project_id: Option<ProjectId>,
    pub dependencies: Vec<ThreadId>,    // Requires edges (outgoing)
    pub blocked_by: Vec<ThreadId>,      // Blocked by these threads
    pub parent_id: Option<ThreadId>,    // SpawnedFrom edge
}
```

### Invariants
1. No cycles in dependency graph
2. Completed threads cannot have new dependencies added
3. Merging creates MergedFrom edges to source threads

### Graph Operations
- `petgraph` crate for in-memory graph algorithms
- SQLite for persistent edge storage
- Topological sort for valid execution order

## State Machine Integration
Threads have states that interact with the DAG:
- `Blocked`: Has unresolved blocking dependencies
- `Active`: All dependencies satisfied, can make progress
- Transitioning to `Active` requires all `blocked_by` threads to be `Complete`

## Visualization
The TUI Landscape view renders the DAG:
- Nodes = threads, sized by temperature
- Edges = dependencies/relationships
- Colors = thread state
