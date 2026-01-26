# ADR-004: SourceMap for Direct PDF Manipulation

## Status
Accepted

## Context
DirectPdf mode requires clicking on rendered PDF text and editing the corresponding source. This requires mapping between:

1. **PDF coordinates**: (page, x, y) positions of rendered glyphs
2. **Source positions**: (line, column) or byte offset in Typst source

Traditional approaches:
- **SyncTeX**: LaTeX's solution, complex format, not applicable to Typst
- **Debug info**: Compiler-generated source maps (common in web development)
- **Heuristic matching**: Text search (brittle, fails with duplicates)

## Decision
imprint uses a **SourceMap** data structure that Typst generates during compilation, mapping rendered content back to source positions.

```rust
pub struct SourceMap {
    entries: Vec<SourceMapEntry>,
    page_index: Vec<PageRange>,  // Fast lookup by page
}

pub struct SourceMapEntry {
    /// PDF location
    pub page: u32,
    pub bbox: BoundingBox,       // x, y, width, height

    /// Source location
    pub source_range: Range<usize>,  // Byte offsets in source
    pub source_file: Option<PathBuf>, // For multi-file documents

    /// Content type for context-aware editing
    pub content_type: ContentType,
}

pub enum ContentType {
    Text,
    Heading { level: u8 },
    Equation { display: bool },
    Figure { id: Option<String> },
    Citation { key: String },
    Code { language: Option<String> },
}
```

### Click-to-Edit Flow

1. User clicks PDF at (page=2, x=150, y=300)
2. Query SourceMap for entries on page 2 containing point
3. Find entry with `bbox.contains(150, 300)`
4. Extract `source_range` (e.g., bytes 1420..1485)
5. Open inline editor positioned at that source location
6. On edit completion, recompile and update SourceMap

## Consequences

### Positive
- Precise mapping: Click lands on correct source location
- Content-aware: Know whether clicking text, equation, or figure
- Fast lookup: Page index enables O(log n) search
- Multi-file support: Works with Typst's module system

### Negative
- Memory overhead: SourceMap scales with document complexity
- Compilation dependency: Must regenerate on every change
- Typst integration: Requires Typst to expose source location info
- Complex content: Tables and nested structures harder to map

## Implementation
- SourceMap generated as side-effect of Typst compilation
- Cached alongside rendered PDF
- Invalidated on source changes (partial invalidation for incremental)
- Bounding box hit testing with small tolerance for usability
- Content type used to select appropriate inline editor widget
