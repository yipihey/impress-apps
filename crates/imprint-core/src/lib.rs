//! Imprint Core - CRDT-based collaborative academic writing
//!
//! This crate provides the core functionality for the imprint academic writing application:
//!
//! - **Document**: CRDT-based document representation with Automerge for conflict-free
//!   collaborative editing
//! - **Selection**: Multi-cursor selection support (Helix-inspired)
//! - **Transaction**: Atomic editing operations with undo/redo and CRDT transform support
//! - **SourceMap**: Bidirectional mapping between Typst source and PDF output for direct
//!   manipulation editing
//! - **LaTeX**: Bidirectional LaTeX ↔ Typst conversion for import/export
//! - **Bibliography**: Citation tracking and management integrated with academic-domain
//!   publication types
//! - **Citations**: Trait-based citation provider system for flexible reference management
//! - **Collaboration**: Real-time sync and presence tracking for multi-user editing
//! - **Note Import**: Import annotations and highlights from PDF readers (imbib)
//! - **Render**: Typst-based document rendering (requires `typst-render` feature)
//!
//! # Edit Modes
//!
//! imprint supports three editing modes (from ADR-001), cycled via Tab:
//!
//! - **Mode A (DirectPdf)**: WYSIWYG-like direct PDF manipulation using source maps
//! - **Mode B (SplitView)**: Traditional source editor with live preview
//! - **Mode C (TextOnly)**: Full-screen source editor for focused writing

pub mod automation;
pub mod bibliography;
pub mod citation_lookup;
pub mod citations;
pub mod collaboration;
pub mod document;
pub mod latex;
pub mod migration;
pub mod note_import;
pub mod render;
pub mod selection;
pub mod sourcemap;
pub mod templates;
pub mod transaction;

pub use automation::*;
pub use bibliography::*;
pub use citation_lookup::*;
pub use citations::*;
pub use collaboration::*;
pub use document::*;
pub use latex::*;
pub use migration::*;
pub use note_import::*;
pub use render::*;
pub use selection::*;
pub use sourcemap::*;
pub use templates::*;
pub use transaction::*;

// Setup UniFFI when the feature is enabled
#[cfg(feature = "uniffi")]
uniffi::setup_scaffolding!();

// ============================================================================
// UniFFI Exports for Typst Rendering
// ============================================================================

/// Result of compiling a Typst document to PDF
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct CompileResult {
    /// PDF bytes if compilation succeeded
    pub pdf_data: Option<Vec<u8>>,
    /// Error message if compilation failed
    pub error: Option<String>,
    /// Warning messages from compilation
    pub warnings: Vec<String>,
    /// Number of pages in the output
    pub page_count: u32,
    /// Source map entries for click-to-edit
    pub source_map_entries: Vec<FFISourceMapEntry>,
}

// ============================================================================
// UniFFI Exports for SourceMap (ADR-004)
// ============================================================================

/// A source span (byte offsets in source code)
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFISourceSpan {
    /// Start byte offset (inclusive)
    pub start: u64,
    /// End byte offset (exclusive)
    pub end: u64,
}

/// A position in rendered PDF coordinates
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIRenderPosition {
    /// Page number (0-indexed)
    pub page: u32,
    /// X coordinate in points from left edge
    pub x: f64,
    /// Y coordinate in points from top edge
    pub y: f64,
}

/// A bounding box in PDF coordinates
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIBoundingBox {
    /// Left edge x coordinate
    pub x: f64,
    /// Top edge y coordinate
    pub y: f64,
    /// Width in points
    pub width: f64,
    /// Height in points
    pub height: f64,
}

/// Content type for cursor placement hints
#[cfg(feature = "uniffi")]
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq)]
pub enum FFIContentType {
    Text,
    Heading,
    Math,
    Code,
    Figure,
    Table,
    Citation,
    ListItem,
    Other,
}

/// A source map entry linking source to rendered position
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFISourceMapEntry {
    /// Source span in the document
    pub source: FFISourceSpan,
    /// Page number where this content appears
    pub page: u32,
    /// Bounding box on the page
    pub bbox: FFIBoundingBox,
    /// Type of content
    pub content_type: FFIContentType,
}

/// Result of looking up a click position in the source map
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFICursorPosition {
    /// Source offset for the cursor
    pub source_offset: u64,
    /// Whether a match was found
    pub found: bool,
    /// Content type at this position
    pub content_type: FFIContentType,
}

/// Page size options for PDF output
#[cfg(feature = "uniffi")]
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq)]
pub enum FFIPageSize {
    /// US Letter (8.5 x 11 inches)
    Letter,
    /// A4 (210 x 297 mm)
    A4,
    /// A5 (148 x 210 mm)
    A5,
}

/// Options for compiling Typst to PDF
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct CompileOptions {
    /// Page size for the output
    pub page_size: FFIPageSize,
    /// Font size in points (default: 11)
    pub font_size: f64,
    /// Page margins in points (top, right, bottom, left)
    pub margin_top: f64,
    pub margin_right: f64,
    pub margin_bottom: f64,
    pub margin_left: f64,
}

#[cfg(feature = "uniffi")]
impl Default for CompileOptions {
    fn default() -> Self {
        Self {
            page_size: FFIPageSize::A4,
            font_size: 11.0,
            margin_top: 72.0,
            margin_right: 72.0,
            margin_bottom: 72.0,
            margin_left: 72.0,
        }
    }
}

/// Compile Typst source code to PDF
///
/// This is the main entry point for Swift to compile documents.
///
/// # Arguments
/// * `source` - Typst source code
/// * `options` - Compilation options (page size, margins, etc.)
///
/// # Returns
/// A CompileResult containing the PDF data or error information
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compile_typst_to_pdf(source: String, options: CompileOptions) -> CompileResult {
    use crate::render::{
        DefaultTypstRenderer, OutputFormat, PageSize, RenderOptions, TypstRenderer,
    };

    let page_size = match options.page_size {
        FFIPageSize::Letter => PageSize::Letter,
        FFIPageSize::A4 => PageSize::A4,
        FFIPageSize::A5 => PageSize::A5,
    };

    let render_options = RenderOptions {
        page_size,
        font_size: options.font_size,
        margins: (
            options.margin_top,
            options.margin_right,
            options.margin_bottom,
            options.margin_left,
        ),
        output_format: OutputFormat::Pdf,
        font_paths: Vec::new(),
        include_metadata: true,
    };

    let renderer = DefaultTypstRenderer::new();

    match renderer.render(&source, &render_options) {
        Ok(output) => {
            if let Some(pdf_bytes) = output.as_pdf() {
                // Generate source map entries from the source
                let source_map_entries = generate_source_map_entries(&source, &render_options);

                CompileResult {
                    pdf_data: Some(pdf_bytes.to_vec()),
                    error: None,
                    warnings: Vec::new(),
                    page_count: 1, // TODO: Extract actual page count from PDF
                    source_map_entries,
                }
            } else {
                CompileResult {
                    pdf_data: None,
                    error: Some("Unexpected output format".to_string()),
                    warnings: Vec::new(),
                    page_count: 0,
                    source_map_entries: Vec::new(),
                }
            }
        }
        Err(e) => CompileResult {
            pdf_data: None,
            error: Some(e.to_string()),
            warnings: Vec::new(),
            page_count: 0,
            source_map_entries: Vec::new(),
        },
    }
}

/// Generate source map entries by parsing the Typst source
///
/// This is an approximation that identifies structural elements (headings, paragraphs)
/// and estimates their positions in the rendered PDF. For precise mapping, we would
/// need deeper integration with Typst's compiler internals.
#[cfg(feature = "uniffi")]
fn generate_source_map_entries(
    source: &str,
    options: &crate::render::RenderOptions,
) -> Vec<FFISourceMapEntry> {
    let mut entries = Vec::new();
    let mut current_y = options.margins.0; // Start after top margin
    let page_width = options.page_size.width_pt();
    let content_width = page_width - options.margins.1 - options.margins.3;
    let line_height = options.font_size * 1.4; // Approximate line height
    let heading_height = options.font_size * 2.0;

    let mut byte_offset = 0usize;

    for line in source.lines() {
        let line_bytes = line.len();
        let trimmed = line.trim();

        if trimmed.is_empty() {
            // Empty line - paragraph break
            current_y += line_height * 0.5;
        } else if trimmed.starts_with("= ") {
            // Level 1 heading
            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3,
                    y: current_y,
                    width: content_width,
                    height: heading_height,
                },
                content_type: FFIContentType::Heading,
            });
            current_y += heading_height + line_height * 0.5;
        } else if trimmed.starts_with("== ") || trimmed.starts_with("=== ") {
            // Level 2+ heading
            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3,
                    y: current_y,
                    width: content_width,
                    height: heading_height * 0.8,
                },
                content_type: FFIContentType::Heading,
            });
            current_y += heading_height * 0.8 + line_height * 0.3;
        } else if trimmed.starts_with("$") && trimmed.ends_with("$") {
            // Display math
            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3,
                    y: current_y,
                    width: content_width,
                    height: line_height * 1.5,
                },
                content_type: FFIContentType::Math,
            });
            current_y += line_height * 2.0;
        } else if trimmed.starts_with("```") {
            // Code block start/end
            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3,
                    y: current_y,
                    width: content_width,
                    height: line_height,
                },
                content_type: FFIContentType::Code,
            });
            current_y += line_height;
        } else if trimmed.starts_with("- ")
            || trimmed.starts_with("+ ")
            || trimmed.starts_with("* ")
        {
            // List item
            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3 + 20.0, // Indent for list
                    y: current_y,
                    width: content_width - 20.0,
                    height: line_height,
                },
                content_type: FFIContentType::ListItem,
            });
            current_y += line_height;
        } else {
            // Regular text paragraph
            // Estimate wrapped lines based on character count
            let chars_per_line = (content_width / (options.font_size * 0.5)) as usize;
            let num_lines = (trimmed.len() / chars_per_line).max(1);
            let para_height = line_height * num_lines as f64;

            entries.push(FFISourceMapEntry {
                source: FFISourceSpan {
                    start: byte_offset as u64,
                    end: (byte_offset + line_bytes) as u64,
                },
                page: 0,
                bbox: FFIBoundingBox {
                    x: options.margins.3,
                    y: current_y,
                    width: content_width,
                    height: para_height,
                },
                content_type: FFIContentType::Text,
            });
            current_y += para_height;
        }

        // Account for newline character
        byte_offset += line_bytes + 1;
    }

    entries
}

/// Look up a click position in the source map to find the corresponding source location
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn source_map_lookup(
    entries: Vec<FFISourceMapEntry>,
    page: u32,
    x: f64,
    y: f64,
) -> FFICursorPosition {
    // Find the entry whose bounding box contains the click position
    let mut best_match: Option<&FFISourceMapEntry> = None;
    let mut best_area = f64::INFINITY;

    for entry in &entries {
        if entry.page != page {
            continue;
        }

        let bbox = &entry.bbox;
        // Check if point is inside bounding box
        if x >= bbox.x && x <= bbox.x + bbox.width && y >= bbox.y && y <= bbox.y + bbox.height {
            let area = bbox.width * bbox.height;
            // Prefer smaller (more specific) regions
            if area < best_area {
                best_area = area;
                best_match = Some(entry);
            }
        }
    }

    if let Some(entry) = best_match {
        // Calculate position within the span based on x position
        let x_ratio = (x - entry.bbox.x) / entry.bbox.width;
        let span_length = entry.source.end - entry.source.start;
        let offset_within = (span_length as f64 * x_ratio) as u64;

        FFICursorPosition {
            source_offset: entry.source.start + offset_within,
            found: true,
            content_type: entry.content_type,
        }
    } else {
        // No exact match - find nearest entry on the page
        let mut nearest: Option<&FFISourceMapEntry> = None;
        let mut min_distance = f64::INFINITY;

        for entry in &entries {
            if entry.page != page {
                continue;
            }

            let bbox = &entry.bbox;
            let center_x = bbox.x + bbox.width / 2.0;
            let center_y = bbox.y + bbox.height / 2.0;
            let distance = ((x - center_x).powi(2) + (y - center_y).powi(2)).sqrt();

            if distance < min_distance {
                min_distance = distance;
                nearest = Some(entry);
            }
        }

        if let Some(entry) = nearest {
            // Place cursor at start or end based on position relative to center
            let center_x = entry.bbox.x + entry.bbox.width / 2.0;
            let offset = if x < center_x {
                entry.source.start
            } else {
                entry.source.end
            };

            FFICursorPosition {
                source_offset: offset,
                found: true,
                content_type: entry.content_type,
            }
        } else {
            FFICursorPosition {
                source_offset: 0,
                found: false,
                content_type: FFIContentType::Text,
            }
        }
    }
}

/// Result of a source-to-render lookup
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIRenderRegion {
    /// Page number (0-indexed)
    pub page: u32,
    /// Bounding box x coordinate
    pub x: f64,
    /// Bounding box y coordinate
    pub y: f64,
    /// Bounding box width
    pub width: f64,
    /// Bounding box height
    pub height: f64,
    /// Whether a match was found
    pub found: bool,
}

/// Look up a cursor position in the source to find the corresponding render location
///
/// This is the reverse of `source_map_lookup` - given a source position, find where
/// it appears in the rendered PDF. Used for cursor synchronization from source to PDF.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn source_to_render_lookup(
    entries: Vec<FFISourceMapEntry>,
    source_offset: u64,
) -> FFIRenderRegion {
    // Find entries that contain the source offset
    let mut best_match: Option<&FFISourceMapEntry> = None;
    let mut best_span_length = usize::MAX;

    for entry in &entries {
        let start = entry.source.start;
        let end = entry.source.end;

        // Check if the source offset is within this entry
        if source_offset >= start && source_offset < end {
            let span_length = (end - start) as usize;
            // Prefer smaller (more specific) spans
            if span_length < best_span_length {
                best_span_length = span_length;
                best_match = Some(entry);
            }
        }
    }

    // If no exact match, find the nearest entry
    if best_match.is_none() {
        let mut min_distance = u64::MAX;

        for entry in &entries {
            let start = entry.source.start;
            let end = entry.source.end;

            // Calculate distance to the nearest edge of this span
            let distance = if source_offset < start {
                start - source_offset
            } else if source_offset >= end {
                source_offset - end + 1
            } else {
                0
            };

            if distance < min_distance {
                min_distance = distance;
                best_match = Some(entry);
            }
        }
    }

    if let Some(entry) = best_match {
        FFIRenderRegion {
            page: entry.page,
            x: entry.bbox.x,
            y: entry.bbox.y,
            width: entry.bbox.width,
            height: entry.bbox.height,
            found: true,
        }
    } else {
        FFIRenderRegion {
            page: 0,
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
            found: false,
        }
    }
}

/// Compile Typst source with default options
///
/// Convenience function that uses A4 paper with standard margins.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compile_typst_to_pdf_default(source: String) -> CompileResult {
    compile_typst_to_pdf(source, CompileOptions::default())
}

/// Get source map entries for a compiled document
///
/// This can be called separately if you already have PDF data and just need the source map.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn generate_source_map(source: String, options: CompileOptions) -> Vec<FFISourceMapEntry> {
    use crate::render::{OutputFormat, PageSize, RenderOptions};

    let page_size = match options.page_size {
        FFIPageSize::Letter => PageSize::Letter,
        FFIPageSize::A4 => PageSize::A4,
        FFIPageSize::A5 => PageSize::A5,
    };

    let render_options = RenderOptions {
        page_size,
        font_size: options.font_size,
        margins: (
            options.margin_top,
            options.margin_right,
            options.margin_bottom,
            options.margin_left,
        ),
        output_format: OutputFormat::Pdf,
        font_paths: Vec::new(),
        include_metadata: true,
    };

    generate_source_map_entries(&source, &render_options)
}

/// Check if Typst rendering is available
///
/// Returns true if the library was built with the typst-render feature.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn is_typst_available() -> bool {
    cfg!(feature = "typst-render")
}

/// Get the Typst version string
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_typst_version() -> String {
    use crate::render::{DefaultTypstRenderer, TypstRenderer};
    DefaultTypstRenderer::new().typst_version().to_string()
}

/// Hello from imprint-core - verify FFI is working
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn hello_from_imprint() -> String {
    "Hello from imprint-core (Rust)!".to_string()
}

// ============================================================================
// UniFFI Exports for Templates
// ============================================================================

/// Template category for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq)]
pub enum FFITemplateCategory {
    Journal,
    Conference,
    Thesis,
    Report,
    Custom,
}

#[cfg(feature = "uniffi")]
impl From<&templates::TemplateCategory> for FFITemplateCategory {
    fn from(category: &templates::TemplateCategory) -> Self {
        match category {
            templates::TemplateCategory::Journal => FFITemplateCategory::Journal,
            templates::TemplateCategory::Conference => FFITemplateCategory::Conference,
            templates::TemplateCategory::Thesis => FFITemplateCategory::Thesis,
            templates::TemplateCategory::Report => FFITemplateCategory::Report,
            templates::TemplateCategory::Custom => FFITemplateCategory::Custom,
        }
    }
}

/// Journal information for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIJournalInfo {
    /// Publisher name
    pub publisher: String,
    /// Journal URL
    pub url: Option<String>,
    /// LaTeX document class
    pub latex_class: Option<String>,
    /// ISSN
    pub issn: Option<String>,
}

/// Page defaults for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIPageDefaults {
    /// Paper size (a4, letter, a5)
    pub size: String,
    /// Top margin in mm
    pub margin_top: f64,
    /// Right margin in mm
    pub margin_right: f64,
    /// Bottom margin in mm
    pub margin_bottom: f64,
    /// Left margin in mm
    pub margin_left: f64,
    /// Number of columns
    pub columns: u8,
    /// Font size in pt
    pub font_size: f64,
}

/// Template metadata for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFITemplateMetadata {
    /// Unique template ID
    pub id: String,
    /// Human-readable name
    pub name: String,
    /// Template version
    pub version: String,
    /// Description
    pub description: String,
    /// Author
    pub author: String,
    /// License
    pub license: String,
    /// Category
    pub category: FFITemplateCategory,
    /// Searchable tags
    pub tags: Vec<String>,
    /// Journal info (for journal templates)
    pub journal: Option<FFIJournalInfo>,
    /// Page layout defaults
    pub page_defaults: FFIPageDefaults,
    /// Whether this is a built-in template
    pub is_builtin: bool,
}

#[cfg(feature = "uniffi")]
impl From<&templates::Template> for FFITemplateMetadata {
    fn from(template: &templates::Template) -> Self {
        let m = &template.metadata;
        FFITemplateMetadata {
            id: m.id.clone(),
            name: m.name.clone(),
            version: m.version.clone(),
            description: m.description.clone(),
            author: m.author.clone(),
            license: m.license.clone(),
            category: FFITemplateCategory::from(&m.category),
            tags: m.tags.clone(),
            journal: m.journal.as_ref().map(|j| FFIJournalInfo {
                publisher: j.publisher.clone(),
                url: j.url.clone(),
                latex_class: j.latex_class.clone(),
                issn: j.issn.clone(),
            }),
            page_defaults: FFIPageDefaults {
                size: m.page_defaults.size.clone(),
                margin_top: m.page_defaults.margins.top,
                margin_right: m.page_defaults.margins.right,
                margin_bottom: m.page_defaults.margins.bottom,
                margin_left: m.page_defaults.margins.left,
                columns: m.page_defaults.columns,
                font_size: m.page_defaults.font_size,
            },
            is_builtin: template.is_builtin(),
        }
    }
}

/// Full template data for FFI
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFITemplate {
    /// Template metadata
    pub metadata: FFITemplateMetadata,
    /// Typst template source
    pub typst_source: String,
    /// Optional LaTeX preamble
    pub latex_preamble: Option<String>,
}

#[cfg(feature = "uniffi")]
impl From<&templates::Template> for FFITemplate {
    fn from(template: &templates::Template) -> Self {
        FFITemplate {
            metadata: FFITemplateMetadata::from(template),
            typst_source: template.typst_source.clone(),
            latex_preamble: template.latex_preamble.clone(),
        }
    }
}

/// List all available templates (metadata only)
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn list_templates() -> Vec<FFITemplateMetadata> {
    let registry = templates::TemplateRegistry::new();
    registry
        .list()
        .into_iter()
        .map(FFITemplateMetadata::from)
        .collect()
}

/// Get a template by ID
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_template(id: String) -> Option<FFITemplate> {
    let registry = templates::TemplateRegistry::new();
    registry.get(&id).map(FFITemplate::from)
}

/// Get template source by ID
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn get_template_source(id: String) -> Option<String> {
    let registry = templates::TemplateRegistry::new();
    registry.get(&id).map(|t| t.typst_source.clone())
}

/// Search templates by query string
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn search_templates(query: String) -> Vec<FFITemplateMetadata> {
    let registry = templates::TemplateRegistry::new();
    registry
        .search(&query)
        .into_iter()
        .map(FFITemplateMetadata::from)
        .collect()
}

/// List templates by category
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn list_templates_by_category(category: FFITemplateCategory) -> Vec<FFITemplateMetadata> {
    let registry = templates::TemplateRegistry::new();
    let cat = match category {
        FFITemplateCategory::Journal => templates::TemplateCategory::Journal,
        FFITemplateCategory::Conference => templates::TemplateCategory::Conference,
        FFITemplateCategory::Thesis => templates::TemplateCategory::Thesis,
        FFITemplateCategory::Report => templates::TemplateCategory::Report,
        FFITemplateCategory::Custom => templates::TemplateCategory::Custom,
    };
    registry
        .by_category(&cat)
        .into_iter()
        .map(FFITemplateMetadata::from)
        .collect()
}

/// Get the number of available templates
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn template_count() -> u32 {
    let registry = templates::TemplateRegistry::new();
    registry.len() as u32
}

#[cfg(test)]
mod tests {
    #[allow(unused_imports)]
    use super::*;

    #[test]
    #[cfg(feature = "typst-render")]
    fn test_typst_compile_simple() {
        let source = "= Hello World\n\nThis is a test.";
        let options = CompileOptions::default();
        let result = compile_typst_to_pdf(source.to_string(), options);

        if let Some(error) = &result.error {
            println!("Compilation error: {}", error);
        }

        assert!(
            result.error.is_none(),
            "Compilation should succeed: {:?}",
            result.error
        );
        assert!(result.pdf_data.is_some(), "PDF data should be returned");

        let pdf_data = result.pdf_data.unwrap();
        assert!(
            pdf_data.len() > 100,
            "PDF should have reasonable size, got {} bytes",
            pdf_data.len()
        );
        assert!(
            pdf_data.starts_with(b"%PDF"),
            "PDF should start with %PDF header"
        );
    }

    #[test]
    #[cfg(feature = "typst-render")]
    fn test_typst_compile_empty() {
        let source = "";
        let options = CompileOptions::default();
        let result = compile_typst_to_pdf(source.to_string(), options);

        // Empty source should still produce a valid (empty) PDF
        assert!(
            result.error.is_none(),
            "Empty source should compile: {:?}",
            result.error
        );
    }

    #[test]
    #[cfg(feature = "typst-render")]
    fn test_typst_compile_sample_document() {
        let source = r#"= Sample Document

This is a sample document for UI testing.

== Introduction

Lorem ipsum dolor sit amet, consectetur adipiscing elit.

== Methods

The methodology involves several steps:

+ First step
+ Second step
+ Third step

== Results

The equation $E = m c^2$ is fundamental to physics.

== Conclusion

In conclusion, this sample document demonstrates basic Typst features."#;

        let options = CompileOptions::default();
        let result = compile_typst_to_pdf(source.to_string(), options);

        if let Some(error) = &result.error {
            println!("Compilation error: {}", error);
        }

        assert!(
            result.error.is_none(),
            "Sample document should compile: {:?}",
            result.error
        );
        assert!(result.pdf_data.is_some(), "PDF data should be returned");

        let pdf_data = result.pdf_data.unwrap();
        assert!(
            pdf_data.len() > 100,
            "PDF should have reasonable size, got {} bytes",
            pdf_data.len()
        );
    }
}
// CI trigger
