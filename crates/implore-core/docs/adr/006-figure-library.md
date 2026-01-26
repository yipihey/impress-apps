# ADR-006: Figure Library with Imprint Linking

## Status
Accepted

## Context
Scientific workflows produce many figures across projects:

1. Exploratory figures during analysis
2. Draft figures for internal discussion
3. Publication-quality figures for papers
4. Variations (different colormaps, zoom levels, annotations)

These figures need:
- Organization and searchability
- Version history
- Link to papers where they're used
- Export in multiple formats

Traditional approaches:
- **Manual file management**: Error-prone, no metadata
- **Notebooks**: Figures buried in code cells
- **Asset managers**: Not science-aware, no document linking

## Decision
implore provides a **Figure Library** that organizes figures and links them to imprint documents.

```rust
pub struct FigureLibrary {
    figures: HashMap<FigureId, LibraryFigure>,
    folders: Vec<FigureFolder>,
    imprint_links: HashMap<FigureId, Vec<ImprintLink>>,
}

pub struct LibraryFigure {
    pub id: FigureId,
    pub name: String,
    pub description: Option<String>,
    pub created_at: DateTime<Utc>,
    pub modified_at: DateTime<Utc>,
    pub tags: Vec<String>,

    /// Source configuration to recreate figure
    pub config: FigureConfig,

    /// Cached renders at various resolutions
    pub cached_renders: HashMap<Resolution, PathBuf>,

    /// Data provenance
    pub data_sources: Vec<DataSource>,
}

pub struct ImprintLink {
    /// Which imprint document
    pub document_id: DocumentId,

    /// Where in the document (figure number, label)
    pub anchor: FigureAnchor,

    /// Link type
    pub link_type: LinkType,
}

pub enum LinkType {
    /// Figure embedded in document
    Embedded,
    /// Figure referenced but stored separately
    Referenced,
    /// Draft figure not yet in document
    Draft,
}
```

### Sync with Imprint

When a figure is linked to an imprint document:

1. **Embedded**: Figure rendered and inserted as image
2. **Referenced**: Reference stored, figure pulled on render
3. **Draft**: Tracked but not yet placed

```rust
impl FigureSyncService {
    /// Update all linked figures in a document
    pub fn sync_to_document(&self, doc_id: &DocumentId) -> Result<SyncStats, SyncError> {
        let links = self.library.links_for_document(doc_id);
        let mut stats = SyncStats::default();

        for link in links {
            match link.link_type {
                LinkType::Embedded => {
                    let render = self.render_figure(&link.figure_id)?;
                    self.update_embedded_figure(doc_id, &link.anchor, render)?;
                    stats.updated += 1;
                }
                LinkType::Referenced => {
                    // Just update reference metadata
                    stats.unchanged += 1;
                }
                LinkType::Draft => {
                    stats.skipped += 1;
                }
            }
        }

        Ok(stats)
    }
}
```

### Figure Folders

```rust
pub struct FigureFolder {
    pub id: FolderId,
    pub name: String,
    pub parent: Option<FolderId>,
    pub figures: Vec<FigureId>,
}
```

Organization options:
- By project: "Galaxy Survey 2024"
- By paper: "Nature Paper Figures"
- By type: "Mass Functions", "Phase Diagrams"

## Consequences

### Positive
- Reusability: Same figure in multiple papers
- Provenance: Know exactly how figure was created
- Sync: Update figure once, propagates to documents
- Search: Find figures by tag, date, data source
- Export: Batch export for journal submission

### Negative
- Complexity: Another system to manage
- Storage: Cached renders consume disk space
- Sync conflicts: Figure changes while document editing
- Cross-app dependency: Requires imprint infrastructure

## Implementation
- Library in `implore-core/src/library.rs`
- Sync service in `implore-core/src/sync.rs`
- Figure configs store all parameters to recreate
- Renders cached at 1x, 2x, print resolutions
- CloudKit sync for library metadata
