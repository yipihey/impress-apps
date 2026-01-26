# ADR-005: Capability Traits Pattern

## Status
Accepted

## Context
imprint's Rust core has multiple cross-cutting concerns:
- Document content and editing
- Synchronization (personal and collaborative)
- Version history and restoration
- Commenting and review
- Rendering and export

Traditional OOP would create a monolithic `Document` class with all methods. This leads to:
- Tight coupling between unrelated concerns
- Difficult testing (must mock entire document for sync tests)
- Hard to extend (adding capability requires modifying core class)

## Decision
imprint uses **capability traits** where each concern is a separate trait, and types implement only the traits they need.

```rust
/// Core document content operations
pub trait DocumentContent: Send + Sync {
    fn source(&self) -> String;
    fn edit(&mut self, range: Range<usize>, text: &str) -> ChangeSet;
    fn metadata(&self) -> &DocumentMetadata;
}

/// Synchronization capability
pub trait Syncable: Send + Sync {
    fn generate_sync_message(&self, peer: &PeerId) -> Option<SyncMessage>;
    fn receive_sync_message(&mut self, msg: &SyncMessage) -> Result<MergeResult, SyncError>;
}

/// Version history capability
pub trait Versionable: Send + Sync {
    fn history(&self) -> VersionTimeline;
    fn content_at(&self, snapshot: &SnapshotId) -> Result<String, HistoryError>;
}

/// Restoration extends Versionable
pub trait Restorable: Versionable {
    fn restore(&mut self, snapshot: &SnapshotId) -> Result<ChangeSet, HistoryError>;
}

/// Commenting capability
pub trait Commentable: Send + Sync {
    fn add_comment(&mut self, anchor: TextAnchor, text: &str, author: &UserId) -> CommentId;
    fn comments(&self) -> &[Comment];
}

/// Rendering capability
pub trait Renderable: Send + Sync {
    fn render_pdf(&self, config: &RenderConfig) -> Result<Vec<u8>, RenderError>;
}

/// Export capability
pub trait Exportable: Send + Sync {
    fn export_latex(&self, template: &JournalTemplate) -> Result<String, ExportError>;
}
```

### Composition at FFI Boundary

The FFI layer composes specialized managers that implement each trait:

```rust
pub struct ImprintSession {
    document: Arc<RwLock<ImprintDocument>>,  // DocumentContent
    sync: SyncManager,                        // Syncable
    history: HistoryManager,                  // Versionable, Restorable
    comments: CommentManager,                 // Commentable
    render: RenderService,                    // Renderable
    export: ExportService,                    // Exportable
}
```

## Consequences

### Positive
- Separation of concerns: Each trait is independently testable
- Flexibility: Types implement only needed capabilities
- Extension: New capabilities don't modify existing code
- Clear contracts: Trait defines exact interface for each capability

### Negative
- Indirection: Must compose managers rather than call methods directly
- Boilerplate: Delegation code in session facade
- Learning curve: Pattern less familiar than traditional OOP
- Coordination: Some operations span multiple capabilities

## Implementation
- Traits defined in `imprint-core/src/capabilities/`
- Managers in separate crates (`imprint-sync`, `imprint-render`, etc.)
- FFI session facade composes all managers
- `Send + Sync` bounds enable thread-safe FFI
