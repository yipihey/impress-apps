# ADR-022: Embedding Index Sync Strategy

## Status

Accepted

## Date

2026-01-21

## Context

The recommendation engine (ADR-020) uses an ANN (Approximate Nearest Neighbor) index built on HNSW (Hierarchical Navigable Small World) graphs for semantic similarity search. This index stores embeddings for publications to enable "similar papers" discovery.

Key characteristics of the current implementation:
- **Embedding dimension**: 384 floats per publication
- **Index size**: ~7-15 MB for 1,000 papers
- **Rebuild time**: ~2-5 seconds for 1,000 papers
- **Embedding computation**: ~2-5ms per publication (hash-based bag-of-words)
- **Storage**: In-memory only via `RustAnnIndex` actor

With iCloud sync via CloudKit, we need to decide whether to sync the similarity index across devices or regenerate it locally on each device.

## Decision

**Generate the embedding index locally on each device** rather than syncing via iCloud.

Each device builds its own ANN index from the synced Core Data publications when the user enables semantic or hybrid recommendation modes.

## Rationale

### Technical Constraint: HNSW Cannot Be Serialized

The Rust `hnsw_rs` library (v0.3) used by `RustAnnIndex` does not support graph serialization. The HNSW graph structure is built incrementally and cannot be exported/imported. This makes full index sync **technically infeasible**.

### Cheap Embedding Computation

Embeddings use a deterministic hash-based bag-of-words approach:
- Combines title, abstract, author names, and keywords
- Hashes words to sparse vector indices
- Normalizes to unit vector
- Cost: ~2-5ms per publication

This is fast enough that regenerating embeddings has negligible performance impact.

### Fast Index Rebuild

Building the full HNSW index takes ~2-5 seconds for a typical library (1,000 papers). This is acceptable for an on-demand operation triggered when:
- User enables semantic/hybrid mode
- Library publications change significantly

### Deterministic Results

The hash-based embedding algorithm produces identical vectors for identical input:
- Same publication metadata → same embedding
- Same embeddings → same similarity scores
- Users see consistent results across devices

### Implementation Simplicity

Local generation avoids:
- New CloudKit record types for index data
- Conflict resolution for index updates
- Additional iCloud storage consumption (~7-15 MB)
- Sync latency on first use of new device

## Alternatives Considered

### Option A: Sync Full Index via iCloud

**Rejected** - HNSW graph cannot be serialized (library limitation).

### Option C: Sync Embeddings, Build Graph Locally

**Rejected** - Marginal benefit given cheap embedding computation. Would add complexity for syncing embeddings while still requiring local graph construction.

## Implementation

### Local Generation Strategy

The implementation in `EmbeddingService.swift` builds the index locally:

```swift
@discardableResult
public func buildIndex(from libraries: [CDLibrary]) async -> Int {
    let index = RustAnnIndex()
    await index.initialize(...)

    for publication in publications {
        let embedding = computeEmbedding(for: publication)
        items.append((id, embedding))
    }

    await index.addBatch(items)
    return indexedCount
}
```

### Reactive Freshness Strategy

To keep the index fresh without polling, the service uses a reactive approach:

| Event | Action |
|-------|--------|
| Publication inserted | Incrementally add to existing index |
| Publication updated | Mark index stale (HNSW can't update) |
| Publication deleted | Mark index stale (HNSW can't remove) |
| Scoring requested | Rebuild if stale, then score |

This is implemented via Core Data change observers:

```swift
// App startup
await EmbeddingService.shared.setupChangeObservers()

// Automatic handling:
// - NSManagedObjectContextDidSave notifications trigger handleContextDidSave()
// - New publications are incrementally added via addToIndex()
// - Updates/deletes mark index stale via markStale()
// - similarityScore() and findSimilar() call ensureFreshIndex() before querying
```

**Benefits over polling:**
- No wasted computation when nothing changes
- Index is always fresh when needed (no staleness window)
- Incremental adds for new publications avoid full rebuilds
- Only rebuilds when actually necessary (update/delete)

## Future Considerations

If the app later adopts **neural network embeddings** (e.g., sentence-transformers, ~100-500ms per paper), this decision should be revisited:

1. Add `embedding: Data` attribute to `CDPublication`
2. Sync embeddings via CloudKit (they're just binary data)
3. Build HNSW graph locally from synced embeddings
4. Cache embeddings to avoid recomputation

This hybrid approach would save expensive neural computation while still building the graph locally.

## Consequences

### Positive
- Simple implementation with no new sync logic
- No additional iCloud storage overhead
- No conflict resolution complexity
- Works fully offline
- Deterministic results across devices

### Negative
- Each device performs duplicate computation
- ~2-5 second delay on first use of semantic mode per device
- Index is lost on app restart (must rebuild)

### Neutral
- Index quality is identical across devices (deterministic)
- Performance scales linearly with library size

## References

- [ADR-020: Recommendation Engine](020-recommendation-engine.md)
- `EmbeddingService.swift` - Embedding computation and index management
- `RustAnnIndex.swift` - Swift bridge for Rust HNSW implementation
- `RecommendationEngine.swift` - Integration with recommendation scoring
