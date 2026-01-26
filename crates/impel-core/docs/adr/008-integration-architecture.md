# ADR-008: Integration Architecture

## Status
Accepted

## Context
Impel is part of the impress suite of research tools:
- **imbib**: Reference and bibliography management
- **imprint**: Document creation and editing
- **implore**: Data visualization and analysis

Each tool has its own Rust core crate and may have GUI applications. Integration options:
1. **Direct linking**: Import crates directly
2. **IPC**: Inter-process communication
3. **Adapters**: Abstract interface with pluggable backends
4. **URL schemes**: macOS/iOS URL scheme communication

## Decision
Use an **adapter pattern** with trait-based interfaces that can be implemented for:
- Direct crate linking (when compiled together)
- URL scheme communication (for GUI apps)
- HTTP/WebSocket (for remote services)
- Mock implementations (for testing)

## Integration Points

### imbib (Reference Manager)
```rust
pub trait ImbibClient {
    fn verify_reference(&self, key: &str) -> Result<VerificationResult>;
    fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchResult>>;
    fn get_bibliography(&self, keys: &[String]) -> Result<String>;
    fn exists(&self, identifier: &str) -> Result<bool>;
}
```

**Use cases:**
- Verify citations in papers
- Search for related literature
- Generate bibliography for papers
- Check if references exist in library

### imprint (Document Editor)
```rust
pub trait ImprintClient {
    fn create_document(&self, title: &str, template: Option<&str>) -> Result<DocumentHandle>;
    fn document_status(&self, id: &str) -> Result<DocumentStatus>;
    fn export(&self, id: &str, format: ExportFormat) -> Result<Vec<u8>>;
    fn insert_citation(&self, handle: &DocumentHandle, key: &str) -> Result<()>;
}
```

**Use cases:**
- Create papers from thread work
- Track document progress
- Export to PDF/LaTeX/Typst
- Insert citations and figures

### implore (Data/Visualization)
```rust
pub trait ImploreClient {
    fn search(&self, query: &str, sources: &[Source]) -> Result<Vec<DataSource>>;
    fn fetch(&self, url: &str, filename: &str) -> Result<FetchResult>;
    fn create_visualization(&self, request: VisualizationRequest) -> Result<VisualizationResult>;
}
```

**Use cases:**
- Search for data sources
- Fetch data with provenance tracking
- Generate figures for papers
- Track data lineage

## Consequences

### Positive
- Clean separation of concerns
- Testable with mock implementations
- Flexible deployment options
- Can evolve independently

### Negative
- Interface maintenance overhead
- May miss tool-specific features
- Abstraction penalty for some operations

## File Organization
```
crates/impel-core/src/integrations/
├── mod.rs          # Module exports
├── imbib.rs        # Reference management adapter
├── imprint.rs      # Document editing adapter
└── implore.rs      # Data visualization adapter
```

## URL Scheme Integration
For GUI app communication on macOS/iOS:
- `imbib://search?q=quantum+computing`
- `imprint://open?doc=paper-123`
- `implore://visualize?data=/path/to/data.csv`

Adapters can detect if GUI app is running and use URL scheme, falling back to direct crate linking otherwise.
