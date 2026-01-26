# ADR-001: CRDT-First Document Model

## Status
Accepted

## Context
Collaborative academic writing requires real-time editing by multiple users who may be offline, on different continents, or working asynchronously over months. Traditional approaches include:

1. **Lock-based editing**: One user edits at a time (too restrictive)
2. **Operational Transformation (OT)**: Google Docs approach, requires central server
3. **CRDTs**: Conflict-free replicated data types, work offline and merge automatically

Academic writing has specific needs:
- Long documents edited over months/years
- Collaborators with intermittent connectivity (fieldwork, travel)
- Full version history for tracking changes across revisions
- No vendor lock-in or server dependency

## Decision
imprint uses **Automerge** as its document model, making CRDTs the foundation rather than an afterthought.

Key design choices:
1. **Document = Automerge Doc**: The canonical representation is always the CRDT
2. **Text as Automerge.Text**: Character-level collaborative editing with conflict resolution
3. **Metadata as Automerge Maps**: Structured data (title, authors, sections) in CRDT maps
4. **History is built-in**: Automerge's change history provides version control for free

```rust
pub struct ImprintDocument {
    doc: AutomergeDoc,
    actor_id: ActorId,
}

impl ImprintDocument {
    pub fn edit(&mut self, range: Range<usize>, text: &str) -> ChangeSet {
        let mut tx = self.doc.transaction();
        let text_obj = tx.get(ROOT, "content").unwrap();
        tx.splice_text(&text_obj, range.start, range.len(), text);
        tx.commit()
    }
}
```

## Consequences

### Positive
- Offline-first: Full editing capability without network
- Automatic merging: No manual conflict resolution needed
- Built-in history: Every change is recorded with actor and timestamp
- Sync-agnostic: Works with any transport (iCloud, CloudKit, peer-to-peer)
- Future-proof: WASM target enables web version without rewrite

### Negative
- Storage overhead: CRDT metadata increases document size ~2-3x
- Learning curve: Team must understand CRDT semantics
- Semantic conflicts: CRDTs resolve syntactic conflicts but not semantic ones (e.g., two edits to same sentence)
- Large documents: Performance considerations for documents >1MB (addressed via chunking)

## Implementation
- Core document operations in `imprint-document` crate
- Automerge 2.x with Rust bindings
- Chunking strategy for documents >1MB (see ADR-000)
- Change batching for undo/redo grouping
