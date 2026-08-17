//! Imprint Core - the Typst/LaTeX authoring engine
//!
//! This crate provides the core functionality for the imprint academic writing application:
//!
//! - **Document**: edit modes and metadata (the collaborative-document layer lives in
//!   `impress-core::collab` since ADR-0027 — one Automerge runtime, behind the store verbs)
//! - **Selection**: Multi-cursor selection support (Helix-inspired)
//! - **Transaction**: Atomic editing operations with undo/redo
//! - **SourceMap**: Bidirectional mapping between Typst source and PDF output for direct
//!   manipulation editing
//! - **LaTeX**: Bidirectional LaTeX ↔ Typst conversion for import/export
//! - **Bibliography**: Citation tracking and management integrated with academic-domain
//!   publication types
//! - **Citations**: Trait-based citation provider system for flexible reference management
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
pub mod document;
pub mod latex;
pub mod migration;
pub mod note_import;
#[cfg(feature = "typst-render")]
pub mod plot_ffi;
pub mod presentation;
pub mod render;
pub mod render_project;
pub mod sections;
pub mod selection;
pub mod sourcemap;
pub mod synctex;
pub mod templates;
pub mod transaction;

pub use automation::*;
pub use bibliography::*;
pub use citation_lookup::*;
pub use citations::*;
pub use document::*;
pub use latex::*;
pub use migration::*;
pub use note_import::*;
pub use presentation::*;
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

/// One structured Typst diagnostic crossing the FFI. Positions are in the
/// USER source (the text the editor shows): `line`/`column` are 1-indexed
/// (column counts characters), `source_start`/`source_end` are UTF-8 byte
/// offsets. All are None for diagnostics with no span in the main file.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiTypstDiagnostic {
    /// `"error"` or `"warning"`.
    pub severity: String,
    pub message: String,
    pub line: Option<u32>,
    pub column: Option<u32>,
    pub source_start: Option<u64>,
    pub source_end: Option<u64>,
    /// Typst's remediation hints ("did you mean …").
    pub hints: Vec<String>,
}

/// Result of compiling a Typst document to PDF
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct CompileResult {
    /// PDF bytes if compilation succeeded
    pub pdf_data: Option<Vec<u8>>,
    /// Human-readable error summary if compilation failed (one line per error)
    pub error: Option<String>,
    /// Warning messages from compilation (human-readable lines)
    pub warnings: Vec<String>,
    /// Every structured diagnostic: errors on failure, warnings always
    pub diagnostics: Vec<FfiTypstDiagnostic>,
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
    /// Filesystem root for on-disk figure assets: `image("figures/plot.png")`
    /// in the source resolves to `<figures_root>/figures/plot.png`. Callers
    /// pass the per-manuscript app-group directory; None → no filesystem
    /// assets (in-memory `set_asset` entries still resolve).
    pub figures_root: Option<String>,
    /// BibTeX text served to Typst as a virtual `bibliography.bib`, so
    /// `@citeKey` + `#bibliography("bibliography.bib")` resolve without any
    /// project directory. Callers assemble this from the cited publications'
    /// raw BibTeX (store-backed). None → no virtual bibliography.
    pub bib_source: Option<String>,
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
            figures_root: None,
            bib_source: None,
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
    // Wrap the entire compilation in catch_unwind to prevent panics from crossing
    // the FFI boundary. Any panic inside will be converted to an error result.
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        compile_typst_to_pdf_inner(source, options)
    }));

    match result {
        Ok(compile_result) => compile_result,
        Err(panic_info) => {
            let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic during Typst compilation".to_string()
            };
            CompileResult {
                pdf_data: None,
                error: Some(format!("Internal error: {}", panic_msg)),
                warnings: Vec::new(),
                diagnostics: Vec::new(),
                page_count: 0,
                source_map_entries: Vec::new(),
            }
        }
    }
}

/// Map a structured render diagnostic to the FFI wire type.
#[cfg(feature = "uniffi")]
fn typst_diag_to_ffi(d: &crate::render::TypstDiagnostic) -> FfiTypstDiagnostic {
    FfiTypstDiagnostic {
        severity: match d.severity {
            crate::render::TypstDiagnosticSeverity::Error => "error".to_string(),
            crate::render::TypstDiagnosticSeverity::Warning => "warning".to_string(),
        },
        message: d.message.clone(),
        line: d.line,
        column: d.column,
        source_start: d.source_start.map(|v| v as u64),
        source_end: d.source_end.map(|v| v as u64),
        hints: d.hints.clone(),
    }
}

// ============================================================================
// UniFFI Exports for Tectonic LaTeX Rendering (gated on `tectonic-render`)
// ============================================================================

/// A single LaTeX diagnostic surfaced to Swift. `severity` is
/// `"error" | "warning" | "info"`.
#[cfg(all(feature = "uniffi", feature = "tectonic-render"))]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiLatexDiagnostic {
    pub severity: String,
    pub file: String,
    pub line: u32,
    pub column: Option<u32>,
    pub message: String,
    pub context: Option<String>,
}

/// Result of compiling a LaTeX document with the embedded Tectonic engine.
#[cfg(all(feature = "uniffi", feature = "tectonic-render"))]
#[derive(uniffi::Record, Debug, Clone)]
pub struct LatexCompileResult {
    /// PDF bytes if compilation produced a PDF.
    pub pdf_data: Option<Vec<u8>>,
    /// Raw `.synctex.gz` bytes if SyncTeX was requested and produced.
    pub synctex_data: Option<Vec<u8>>,
    /// Structured diagnostics (errors + warnings), in source order.
    pub diagnostics: Vec<FfiLatexDiagnostic>,
    /// Wall-clock compile time in milliseconds.
    pub compile_ms: u64,
    /// Fatal-error summary if no PDF was produced.
    pub error: Option<String>,
}

/// Options for a Tectonic compile.
#[cfg(all(feature = "uniffi", feature = "tectonic-render"))]
#[derive(uniffi::Record, Debug, Clone)]
pub struct TectonicOptions {
    /// Request SyncTeX output for source↔PDF sync.
    pub synctex: bool,
    /// Writable directory for Tectonic's on-demand package/format cache
    /// (the sandbox container Caches dir, passed from Swift). `None` = default.
    pub cache_dir: Option<String>,
    /// Directory used to resolve on-disk references (figures, `\input`).
    /// MUST be the document's working dir, else `\includegraphics` fails.
    pub filesystem_root: Option<String>,
}

/// Compile a LaTeX source string to PDF using the embedded Tectonic engine.
///
/// Runs in-process (no external `pdflatex`, no toolbox). Fetches TeX packages
/// on demand into `options.cache_dir` on first use. Panics are caught at the
/// FFI boundary and returned as an error result.
#[cfg(all(feature = "uniffi", feature = "tectonic-render"))]
#[uniffi::export]
pub fn compile_latex_tectonic(source: String, options: TectonicOptions) -> LatexCompileResult {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        crate::latex::compile_latex_tectonic(
            &source,
            options.synctex,
            options.cache_dir.as_deref(),
            options.filesystem_root.as_deref(),
        )
    }));

    match result {
        Ok(r) => LatexCompileResult {
            pdf_data: r.pdf_data,
            synctex_data: r.synctex_data,
            diagnostics: r
                .diagnostics
                .into_iter()
                .map(|d| FfiLatexDiagnostic {
                    severity: match d.severity {
                        crate::latex::diagnostics::Severity::Error => "error",
                        crate::latex::diagnostics::Severity::Warning => "warning",
                        crate::latex::diagnostics::Severity::Info => "info",
                    }
                    .to_string(),
                    file: d.file,
                    line: d.line,
                    column: d.column,
                    message: d.message,
                    context: d.context,
                })
                .collect(),
            compile_ms: r.compile_ms,
            error: r.error,
        },
        Err(panic_info) => {
            let msg = panic_info
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic_info.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "Unknown panic during Tectonic compilation".to_string());
            LatexCompileResult {
                pdf_data: None,
                synctex_data: None,
                diagnostics: Vec::new(),
                compile_ms: 0,
                error: Some(format!("Internal error: {msg}")),
            }
        }
    }
}

// Thread-local persistent renderer — fonts load once per thread, comemo caches persist.
#[cfg(all(feature = "uniffi", feature = "typst-render"))]
thread_local! {
    static PERSISTENT_RENDERER: std::cell::RefCell<crate::render::PersistentTypstRenderer> =
        std::cell::RefCell::new(crate::render::PersistentTypstRenderer::new());
}

/// Inner compilation function that may panic
#[cfg(feature = "uniffi")]
fn compile_typst_to_pdf_inner(source: String, options: CompileOptions) -> CompileResult {
    use crate::render::PageSize;

    let page_size = match options.page_size {
        FFIPageSize::Letter => PageSize::Letter,
        FFIPageSize::A4 => PageSize::A4,
        FFIPageSize::A5 => PageSize::A5,
    };

    let render_options = crate::render::RenderOptions {
        page_size,
        font_size: options.font_size,
        margins: (
            options.margin_top,
            options.margin_right,
            options.margin_bottom,
            options.margin_left,
        ),
        output_format: crate::render::OutputFormat::Pdf,
        font_paths: Vec::new(),
        include_metadata: true,
    };

    // Use the persistent renderer for incremental compilation
    #[cfg(feature = "typst-render")]
    {
        PERSISTENT_RENDERER.with(|cell| {
            let mut renderer = cell.borrow_mut();
            renderer.set_figures_root(options.figures_root.as_deref());
            renderer.set_bib_source(options.bib_source.as_deref());
            match renderer.render_pdf(&source, &render_options) {
                Ok(success) => {
                    if let Some(pdf_bytes) = success.output.as_pdf() {
                        // Prefer the real-layout source map; fall back to the
                        // text heuristic only if the frame walk yielded nothing.
                        let source_map_entries = if success.source_map.is_empty() {
                            generate_source_map_entries(&source, &render_options)
                        } else {
                            success.source_map.iter().map(layout_entry_to_ffi).collect()
                        };

                        CompileResult {
                            pdf_data: Some(pdf_bytes.to_vec()),
                            error: None,
                            warnings: success.warnings.iter().map(|w| w.summary_line()).collect(),
                            diagnostics: success.warnings.iter().map(typst_diag_to_ffi).collect(),
                            page_count: success.page_count,
                            source_map_entries,
                        }
                    } else {
                        CompileResult {
                            pdf_data: None,
                            error: Some("Unexpected output format".to_string()),
                            warnings: Vec::new(),
                            diagnostics: Vec::new(),
                            page_count: 0,
                            source_map_entries: Vec::new(),
                        }
                    }
                }
                Err(e) => CompileResult {
                    pdf_data: None,
                    error: Some(e.summary.clone()),
                    warnings: Vec::new(),
                    diagnostics: e.diagnostics.iter().map(typst_diag_to_ffi).collect(),
                    page_count: 0,
                    source_map_entries: Vec::new(),
                },
            }
        })
    }

    // Fallback for when typst-render is not enabled
    #[cfg(not(feature = "typst-render"))]
    {
        use crate::render::{DefaultTypstRenderer, TypstRenderer};
        let renderer = DefaultTypstRenderer::new();
        match renderer.render(&source, &render_options) {
            Ok(output) => {
                if let Some(pdf_bytes) = output.as_pdf() {
                    let source_map_entries = generate_source_map_entries(&source, &render_options);
                    CompileResult {
                        pdf_data: Some(pdf_bytes.to_vec()),
                        error: None,
                        warnings: Vec::new(),
                        diagnostics: Vec::new(),
                        page_count: 1,
                        source_map_entries,
                    }
                } else {
                    CompileResult {
                        pdf_data: None,
                        error: Some("Unexpected output format".to_string()),
                        warnings: Vec::new(),
                        diagnostics: Vec::new(),
                        page_count: 0,
                        source_map_entries: Vec::new(),
                    }
                }
            }
            Err(e) => CompileResult {
                pdf_data: None,
                error: Some(e.to_string()),
                warnings: Vec::new(),
                diagnostics: Vec::new(),
                page_count: 0,
                source_map_entries: Vec::new(),
            },
        }
    }
}

/// Map a real-layout source-map entry (points, top-left origin, offsets into the
/// user source) to the FFI wire type. All layout runs are text runs, so the
/// content type is `Text`.
#[cfg(all(feature = "uniffi", feature = "typst-render"))]
fn layout_entry_to_ffi(e: &crate::render::LayoutSourceMapEntry) -> FFISourceMapEntry {
    FFISourceMapEntry {
        source: FFISourceSpan {
            start: e.source_start as u64,
            end: e.source_end as u64,
        },
        page: e.page,
        bbox: FFIBoundingBox {
            x: e.x,
            y: e.y,
            width: e.width,
            height: e.height,
        },
        content_type: FFIContentType::Text,
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

// ============================================================================
// UniFFI Exports for Project (multi-file) Compilation — Phase 8.7
// ============================================================================

/// Result of compiling a project (Typst or LaTeX) to PDF. Mirrors
/// `CompileResult` but does not include source-map entries (project compiles
/// don't surface a per-source-byte map yet).
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct ProjectCompileResult {
    /// PDF bytes if compilation succeeded.
    pub pdf_data: Option<Vec<u8>>,
    /// Error message if compilation failed.
    pub error: Option<String>,
    /// Warning messages from compilation.
    pub warnings: Vec<String>,
    /// Number of pages in the output.
    pub page_count: u32,
    /// Time spent in the compiler in milliseconds.
    pub compile_ms: u64,
}

/// Compile a Typst project to PDF.
///
/// `project_dir` is an absolute path to the project root on disk.
/// `main_file` is relative to `project_dir` (e.g. `"paper.typ"`).
///
/// Multi-file Typst projects work transparently — `image()`, `include`,
/// and `import` all resolve relative to `project_dir`.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compile_typst_project_to_pdf(
    project_dir: String,
    main_file: String,
) -> ProjectCompileResult {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let path = std::path::PathBuf::from(&project_dir);
        let opts = crate::render::RenderOptions::default();
        crate::render_project::compile_typst_project_to_pdf(&path, &main_file, &opts)
    }));
    match result {
        Ok(Ok(out)) => ProjectCompileResult {
            pdf_data: Some(out.pdf_bytes),
            error: None,
            warnings: out.warnings,
            page_count: out.page_count,
            compile_ms: out.compile_ms,
        },
        Ok(Err(e)) => ProjectCompileResult {
            pdf_data: None,
            error: Some(e.to_string()),
            warnings: Vec::new(),
            page_count: 0,
            compile_ms: 0,
        },
        Err(panic_info) => {
            let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic during Typst project compilation".to_string()
            };
            ProjectCompileResult {
                pdf_data: None,
                error: Some(format!("Internal error: {}", panic_msg)),
                warnings: Vec::new(),
                page_count: 0,
                compile_ms: 0,
            }
        }
    }
}

// Note: there is no `compile_tex_project_to_pdf` UniFFI export here.
// LaTeX project compilation is owned by imprint's Swift
// `LaTeXCompilationService`. The journal pipeline's bundle compile
// route dispatches `.tex` bundles to that service directly. Keeping a
// single source of truth for compilation prevents drift between the
// Swift and Rust paths.

/// Result of compiling a Typst document to SVG (one SVG string per page)
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct SvgCompileResult {
    /// SVG strings, one per page
    pub svg_pages: Vec<String>,
    /// Number of pages in the output
    pub page_count: u32,
    /// Warning messages from compilation (human-readable lines)
    pub warnings: Vec<String>,
    /// Human-readable error summary if compilation failed (one line per error)
    pub error: Option<String>,
    /// Every structured diagnostic: errors on failure, warnings always
    pub diagnostics: Vec<FfiTypstDiagnostic>,
    /// Source map entries for cursor synchronization
    pub source_map_entries: Vec<FFISourceMapEntry>,
}

/// Compile Typst source code to SVG (one SVG string per page)
///
/// Uses the persistent renderer for incremental compilation.
/// Each page is rendered as a separate SVG string.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compile_typst_to_svg(source: String, options: CompileOptions) -> SvgCompileResult {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        compile_typst_to_svg_inner(source, options)
    }));

    match result {
        Ok(compile_result) => compile_result,
        Err(panic_info) => {
            let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic during Typst SVG compilation".to_string()
            };
            SvgCompileResult {
                svg_pages: Vec::new(),
                page_count: 0,
                warnings: Vec::new(),
                error: Some(format!("Internal error: {}", panic_msg)),
                diagnostics: Vec::new(),
                source_map_entries: Vec::new(),
            }
        }
    }
}

#[cfg(feature = "uniffi")]
fn compile_typst_to_svg_inner(source: String, options: CompileOptions) -> SvgCompileResult {
    use crate::render::PageSize;

    let page_size = match options.page_size {
        FFIPageSize::Letter => PageSize::Letter,
        FFIPageSize::A4 => PageSize::A4,
        FFIPageSize::A5 => PageSize::A5,
    };

    let render_options = crate::render::RenderOptions {
        page_size,
        font_size: options.font_size,
        margins: (
            options.margin_top,
            options.margin_right,
            options.margin_bottom,
            options.margin_left,
        ),
        output_format: crate::render::OutputFormat::Svg,
        font_paths: Vec::new(),
        include_metadata: true,
    };

    #[cfg(feature = "typst-render")]
    {
        PERSISTENT_RENDERER.with(|cell| {
            let mut renderer = cell.borrow_mut();
            renderer.set_figures_root(options.figures_root.as_deref());
            renderer.set_bib_source(options.bib_source.as_deref());
            match renderer.render_svg(&source, &render_options) {
                Ok(success) => {
                    // Prefer the real-layout source map; fall back to the text
                    // heuristic only if the frame walk yielded nothing.
                    let source_map_entries = if success.source_map.is_empty() {
                        generate_source_map_entries(&source, &render_options)
                    } else {
                        success.source_map.iter().map(layout_entry_to_ffi).collect()
                    };
                    let svg_pages = match success.output {
                        crate::render::RenderOutput::Svg(pages) => pages,
                        _ => Vec::new(),
                    };
                    SvgCompileResult {
                        svg_pages,
                        page_count: success.page_count,
                        warnings: success.warnings.iter().map(|w| w.summary_line()).collect(),
                        error: None,
                        diagnostics: success.warnings.iter().map(typst_diag_to_ffi).collect(),
                        source_map_entries,
                    }
                }
                Err(e) => SvgCompileResult {
                    svg_pages: Vec::new(),
                    page_count: 0,
                    warnings: Vec::new(),
                    error: Some(e.summary.clone()),
                    diagnostics: e.diagnostics.iter().map(typst_diag_to_ffi).collect(),
                    source_map_entries: Vec::new(),
                },
            }
        })
    }

    #[cfg(not(feature = "typst-render"))]
    {
        SvgCompileResult {
            svg_pages: Vec::new(),
            page_count: 0,
            warnings: Vec::new(),
            error: Some("SVG rendering requires the 'typst-render' feature".to_string()),
            diagnostics: Vec::new(),
            source_map_entries: Vec::new(),
        }
    }
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
/// Extract the distinct `@citeKey` references from a Typst source, in first-
/// appearance order.
///
/// Canonical cite-key scanner (keep extraction Rust-side — the Swift copies
/// in BibliographyGenerator/CitationUsageTracker predate this). Rules match
/// `imprint-service::extract_citation_usages` plus an email guard: an `@`
/// immediately preceded by a cite-key character (as in `name@example.org`)
/// is not a citation.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_cite_keys(source: String) -> Vec<String> {
    let bytes = source.as_bytes();
    let len = bytes.len();
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < len {
        if bytes[i] == b'@' {
            // Email guard: `@` glued to a preceding key char is an address.
            let preceded_by_key_char = i > 0
                && (bytes[i - 1].is_ascii_alphanumeric()
                    || bytes[i - 1] == b'_'
                    || bytes[i - 1] == b'.'
                    || bytes[i - 1] == b'-');
            let key_start = i + 1;
            if !preceded_by_key_char && key_start < len && bytes[key_start].is_ascii_alphabetic() {
                let mut j = key_start;
                while j < len {
                    let c = bytes[j];
                    if c.is_ascii_alphanumeric() || c == b'_' || c == b':' || c == b'-' {
                        j += 1;
                    } else {
                        break;
                    }
                }
                if let Ok(key) = std::str::from_utf8(&bytes[key_start..j]) {
                    if seen.insert(key.to_string()) {
                        out.push(key.to_string());
                    }
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out
}

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
// UniFFI Exports for Section Composition (see citations::compose)
// ============================================================================

/// Compose an inline citation token for a manuscript.
///
/// `format` accepts `"typst"` or `"latex"` (case-insensitive; unknown → typst).
/// Typst → `@key`, LaTeX → `\cite{key}`. When `append_space` is true a single
/// leading space is prepended. This is the canonical implementation the Swift
/// router should call instead of its own `composeCitation` helper.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compose_citation(cite_key: String, format: String, append_space: bool) -> String {
    crate::citations::compose::compose_citation(
        &cite_key,
        crate::citations::compose::ComposeFormat::from_str_lenient(&format),
        append_space,
    )
}

/// Compose a heading line at `level` (1-based) for a manuscript.
///
/// `format` accepts `"typst"` or `"latex"`. Typst uses `level` `=` characters
/// (clamped 1..=6); LaTeX maps 1→`\section` … 5+→`\subparagraph`. Canonical
/// replacement for the Swift router's `composeHeading` helper.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn compose_heading(title: String, level: u32, format: String) -> String {
    crate::citations::compose::compose_heading(
        &title,
        level,
        crate::citations::compose::ComposeFormat::from_str_lenient(&format),
    )
}

// ============================================================================
// UniFFI Exports for Cite-Key Hit Testing (see citations::hit)
// ============================================================================

/// One cite-key occurrence, addressed in UTF-16 code units so the Apple text
/// stack (`NSRange`, `UITextView`, `NSTextView`) can use the offsets directly.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FFICiteKeyHit {
    /// The cite key as written, without the `@` sigil or the `\cite{}` wrapper.
    pub key: String,
    /// Which citation command produced this occurrence: `typst-at`, `cite`,
    /// `citep`, `citet`, `cite-author-year`, `cite-other`, `textcite`,
    /// `parencite`, `autocite`, `other-biblatex`.
    pub command: String,
    /// UTF-16 offset of the KEY text.
    pub key_offset: u32,
    /// UTF-16 length of the KEY text.
    pub key_length: u32,
    /// UTF-16 offset of the span that counts as "on the citation" — includes
    /// the Typst `@`; equals `key_offset` for LaTeX.
    pub hit_offset: u32,
    /// UTF-16 length of that span.
    pub hit_length: u32,
}

#[cfg(feature = "uniffi")]
fn ffi_command_name(command: crate::citations::extract::CiteCommand) -> String {
    use crate::citations::extract::CiteCommand as C;
    match command {
        C::Cite => "cite",
        C::Citep => "citep",
        C::Citet => "citet",
        C::CiteAuthorYear => "cite-author-year",
        C::CiteOther => "cite-other",
        C::TextCite => "textcite",
        C::ParenCite => "parencite",
        C::AutoCite => "autocite",
        C::OtherBiblatex => "other-biblatex",
        C::TypstAt => "typst-at",
    }
    .to_string()
}

#[cfg(feature = "uniffi")]
fn ffi_cite_key_hit(source: &str, hit: crate::citations::hit::CiteKeyHit) -> FFICiteKeyHit {
    use crate::citations::hit::byte_offset_to_utf16;
    let key_offset = byte_offset_to_utf16(source, hit.key_byte_offset);
    let key_end = byte_offset_to_utf16(source, hit.key_byte_offset + hit.key_byte_len);
    let hit_offset = byte_offset_to_utf16(source, hit.hit_byte_offset);
    let hit_end = byte_offset_to_utf16(source, hit.hit_byte_offset + hit.hit_byte_len);
    FFICiteKeyHit {
        key: hit.key,
        command: ffi_command_name(hit.command),
        key_offset: key_offset as u32,
        key_length: key_end.saturating_sub(key_offset) as u32,
        hit_offset: hit_offset as u32,
        hit_length: hit_end.saturating_sub(hit_offset) as u32,
    }
}

/// The cite key under a caret / touch point, or `None`.
///
/// `utf16_offset` is a UTF-16 code-unit index into `source` — an `NSRange`
/// location, straight from `UITextView.offset(from:to:)`. `syntax` accepts
/// `typst`, `latex` or `mixed` (unknown values → `mixed`).
///
/// This is the ONLY thing an editor needs in order to implement a hover or
/// long-press citation affordance; it derives from the canonical cite-key
/// scanner (`citations::extract`), so a UI that asks this question cannot grow
/// its own idea of what a cite key is.
///
/// The hit span is half-open: the offset one past the last character of a
/// citation is a miss. Touch callers, where the nearest caret position can land
/// one past the glyph under the finger, should probe `offset` then `offset - 1`.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn cite_key_at_utf16_offset(
    source: String,
    utf16_offset: u32,
    syntax: String,
) -> Option<FFICiteKeyHit> {
    let syntax = crate::citations::extract::CitationSyntax::from_str_lenient(&syntax);
    crate::citations::hit::cite_key_at_utf16_offset(&source, utf16_offset as usize, syntax)
        .map(|hit| ffi_cite_key_hit(&source, hit))
}

/// Every cite-key occurrence in `source`, in source order, with UTF-16 spans.
///
/// The list form of [`cite_key_at_utf16_offset`] — for highlighting every
/// citation in a buffer, or for tests that assert the whole set at once.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn cite_key_hits(source: String, syntax: String) -> Vec<FFICiteKeyHit> {
    let syntax = crate::citations::extract::CitationSyntax::from_str_lenient(&syntax);
    crate::citations::hit::cite_key_hits(&source, syntax)
        .into_iter()
        .map(|hit| ffi_cite_key_hit(&source, hit))
        .collect()
}

// ============================================================================
// UniFFI Exports for Section Extraction (Stage 7 item 6)
// ============================================================================

/// One section of a manuscript source.
///
/// `start` / `end` / `bodyStart` are **Swift `Character` offsets** (extended
/// grapheme clusters) — the offsets every existing consumer splices source text
/// with. `startUtf16` / `endUtf16` / `bodyStartUtf16` are the same positions in
/// UTF-16 code units, which is what `NSRange` and the AppKit/UIKit text stack
/// want; use those for anything that talks to a text view.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FFIExtractedSection {
    /// Lowercase UUID string, deterministic in
    /// `(documentID, normalized title, orderIndex)`. Persisted as the
    /// `manuscript-section` row id — the derivation is frozen.
    pub id: String,
    pub title: String,
    /// Typst: number of `=`. LaTeX: 1 for `\section`, 2 for `\subsection`, ….
    pub level: u32,
    pub start: u32,
    pub end: u32,
    pub body_start: u32,
    pub start_utf16: u32,
    pub end_utf16: u32,
    pub body_start_utf16: u32,
    pub order_index: u32,
    /// `introduction`, `methods`, `results`, … or `None`.
    pub section_type: Option<String>,
    pub word_count: u32,
}

#[cfg(feature = "uniffi")]
fn ffi_section(section: crate::sections::ExtractedSection) -> FFIExtractedSection {
    FFIExtractedSection {
        id: section.id.to_string(),
        title: section.title,
        level: section.level,
        start: section.start as u32,
        end: section.end as u32,
        body_start: section.body_start as u32,
        start_utf16: section.start_utf16 as u32,
        end_utf16: section.end_utf16 as u32,
        body_start_utf16: section.body_start_utf16 as u32,
        order_index: section.order_index as u32,
        section_type: section.section_type,
        word_count: section.word_count as u32,
    }
}

/// Resolve the `format` parameter shared by the section functions.
///
/// `None` (or an empty string) auto-detects from the source; `latex` selects the
/// LaTeX heading grammar; anything else is Typst.
#[cfg(feature = "uniffi")]
fn ffi_section_format(source: &str, format: Option<String>) -> crate::sections::SectionFormat {
    match format.as_deref() {
        None | Some("") => crate::sections::SectionFormat::auto_detect(source),
        Some(name) => crate::sections::SectionFormat::from_str_lenient(name),
    }
}

/// Every section in `source`, in document order.
///
/// `document_id` seeds the deterministic section ids; pass the manuscript's id
/// so the ids match the persisted `manuscript-section` rows. A malformed id is
/// treated as the nil UUID rather than an error — the caller that wants ids to
/// mean something owns passing a real one, and an outline rail that only needs
/// titles and offsets should not have to handle an error case.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_sections(
    source: String,
    document_id: String,
    format: Option<String>,
) -> Vec<FFIExtractedSection> {
    let doc_id = uuid::Uuid::parse_str(&document_id).unwrap_or(uuid::Uuid::nil());
    let fmt = ffi_section_format(&source, format);
    crate::sections::extract(&source, doc_id, Some(fmt))
        .into_iter()
        .map(ffi_section)
        .collect()
}

/// The deterministic id a section with this `(document, title, order index)`
/// would have — for callers that need the id *before* the source re-parses
/// (creating a section and returning its id in the same response).
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn section_id_for(document_id: String, title: String, order_index: u32) -> String {
    let doc_id = uuid::Uuid::parse_str(&document_id).unwrap_or(uuid::Uuid::nil());
    crate::sections::section_id(doc_id, &title, order_index as usize).to_string()
}

/// The heading grammar `source` would be parsed with: `typst` or `latex`.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn detect_section_format(source: String) -> String {
    crate::sections::SectionFormat::auto_detect(&source)
        .as_str()
        .to_string()
}

// ============================================================================
// UniFFI Exports for Presentation Storyboards
// ============================================================================

/// One explicit `#slide(id: "…", beat: "tl-…")[…]` block.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FFIPresentationSlide {
    pub id: String,
    pub beat: Option<String>,
    pub title: Option<String>,
    pub order_index: u32,
    pub start: u32,
    pub end: u32,
    pub start_utf16: u32,
    pub end_utf16: u32,
}

/// Structured result for presentation parsing. Diagnostics are values rather
/// than thrown FFI errors so a half-written slide never destabilizes SwiftUI.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FFIPresentationOutline {
    pub slides: Vec<FFIPresentationSlide>,
    pub error: Option<String>,
}

/// Source mutation result. On error `source` is the untouched input.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FFIPresentationMutation {
    pub source: String,
    pub error: Option<String>,
}

#[cfg(feature = "uniffi")]
fn ffi_presentation_slide(slide: crate::presentation::PresentationSlide) -> FFIPresentationSlide {
    FFIPresentationSlide {
        id: slide.id,
        beat: slide.beat,
        title: slide.title,
        order_index: slide.order_index as u32,
        start: slide.start as u32,
        end: slide.end as u32,
        start_utf16: slide.start_utf16 as u32,
        end_utf16: slide.end_utf16 as u32,
    }
}

/// Parse the stable presentation structure used by imprint's storyboard.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_presentation_slides(source: String) -> FFIPresentationOutline {
    match crate::presentation::extract_slides(&source) {
        Ok(slides) => FFIPresentationOutline {
            slides: slides.into_iter().map(ffi_presentation_slide).collect(),
            error: None,
        },
        Err(error) => FFIPresentationOutline {
            slides: Vec::new(),
            error: Some(error.to_string()),
        },
    }
}

/// Move one slide before another, or to the end when `before_slide_id` is nil.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn reorder_presentation_slide(
    source: String,
    slide_id: String,
    before_slide_id: Option<String>,
) -> FFIPresentationMutation {
    match crate::presentation::reorder_slide(&source, &slide_id, before_slide_id.as_deref()) {
        Ok(source) => FFIPresentationMutation {
            source,
            error: None,
        },
        Err(error) => FFIPresentationMutation {
            source,
            error: Some(error.to_string()),
        },
    }
}

/// Assign a slide to a throughline beat label, or clear it with an empty label.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn set_presentation_slide_beat(
    source: String,
    slide_id: String,
    beat: String,
) -> FFIPresentationMutation {
    match crate::presentation::set_slide_beat(&source, &slide_id, &beat) {
        Ok(source) => FFIPresentationMutation {
            source,
            error: None,
        },
        Err(error) => FFIPresentationMutation {
            source,
            error: Some(error.to_string()),
        },
    }
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

/// Seed values for a new document created from a template.
///
/// Everything except `title` may be empty; the scaffolder fills sensible
/// placeholders and omits any argument the chosen template does not declare.
#[cfg(feature = "uniffi")]
#[derive(uniffi::Record, Debug, Clone)]
pub struct FFIScaffoldOptions {
    /// Manuscript title.
    pub title: String,
    /// Author names, in order.
    pub authors: Vec<String>,
    /// Affiliation strings, referenced by superscript index.
    pub affiliations: Vec<String>,
    /// Abstract text (used for the `summary` slot on templates that use it).
    pub abstract_text: Option<String>,
    /// Keywords, for templates that accept them.
    pub keywords: Vec<String>,
    /// Append the standard Introduction/Methods/Results/... skeleton.
    pub include_sections: bool,
}

#[cfg(feature = "uniffi")]
impl Default for FFIScaffoldOptions {
    fn default() -> Self {
        Self {
            title: String::new(),
            authors: Vec::new(),
            affiliations: Vec::new(),
            abstract_text: None,
            keywords: Vec::new(),
            include_sections: true,
        }
    }
}

#[cfg(feature = "uniffi")]
impl From<&FFIScaffoldOptions> for templates::ScaffoldOptions {
    fn from(o: &FFIScaffoldOptions) -> Self {
        templates::ScaffoldOptions {
            title: o.title.clone(),
            authors: o.authors.clone(),
            affiliations: o.affiliations.clone(),
            abstract_text: o.abstract_text.clone(),
            keywords: o.keywords.clone(),
            include_sections: o.include_sections,
        }
    }
}

/// Build a complete, compilable Typst document from a template.
///
/// A template's raw `typst_source` is only a style definition — compiling it
/// alone yields an empty document. This returns the style definition plus the
/// `#show:` invocation seeded with `options`, plus an optional section
/// skeleton, which is what "new manuscript from template X" should store.
///
/// Returns `None` if no template has the given id.
#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn new_document_from_template(
    template_id: String,
    options: FFIScaffoldOptions,
) -> Option<String> {
    let registry = templates::TemplateRegistry::new();
    let template = registry.get(&template_id)?;
    let opts = templates::ScaffoldOptions::from(&options);
    Some(templates::scaffold_document(template, &opts))
}

#[cfg(test)]
mod tests {
    #[allow(unused_imports)]
    use super::*;

    // ========================================================================
    // Template shipping guarantees
    //
    // A template that does not compile is worse than no template: the user
    // picks a journal, gets a document, and it is broken on first compile with
    // an error in code they did not write. These tests are the gate.
    // ========================================================================

    /// Every built-in template, scaffolded into a starter document, must
    /// compile to a non-empty PDF with at least one page.
    #[test]
    #[cfg(all(feature = "typst-render", feature = "uniffi"))]
    fn test_every_builtin_template_scaffolds_and_compiles() {
        let registry = templates::TemplateRegistry::new();
        let mut failures: Vec<String> = Vec::new();

        for template in registry.list() {
            let id = template.id().to_string();

            let options = FFIScaffoldOptions {
                title: "Constraints on the Growth of Structure".to_string(),
                authors: vec!["Jane Doe".to_string(), "Richard Roe".to_string()],
                affiliations: vec![
                    "Department of Physics, Stanford University".to_string(),
                    "Kavli Institute for Particle Astrophysics".to_string(),
                ],
                abstract_text: Some(
                    "We measure the amplitude of matter clustering and find agreement \
                     with the concordance cosmology."
                        .to_string(),
                ),
                keywords: vec!["cosmology".to_string(), "large-scale structure".to_string()],
                include_sections: true,
            };

            let Some(source) = new_document_from_template(id.clone(), options) else {
                failures.push(format!("{}: scaffolding returned None", id));
                continue;
            };

            let page_size = match template.metadata.page_defaults.size.as_str() {
                "letter" | "us-letter" => FFIPageSize::Letter,
                "a5" => FFIPageSize::A5,
                _ => FFIPageSize::A4,
            };
            let compile_options = CompileOptions {
                page_size,
                font_size: template.metadata.page_defaults.font_size,
                ..CompileOptions::default()
            };

            let result = compile_typst_to_pdf(source, compile_options);

            if let Some(error) = &result.error {
                failures.push(format!("{}: {}", id, error.replace('\n', " | ")));
                continue;
            }
            if result.page_count == 0 {
                failures.push(format!("{}: compiled to zero pages", id));
                continue;
            }
            match &result.pdf_data {
                Some(data) if !data.is_empty() => {}
                _ => failures.push(format!("{}: compiled but produced no PDF bytes", id)),
            }
        }

        assert!(
            failures.is_empty(),
            "{} of {} built-in templates failed to compile:\n  {}",
            failures.len(),
            registry.len(),
            failures.join("\n  ")
        );
    }

    /// The raw template source is a style definition only: it is valid Typst,
    /// but compiling it yields a single *blank* page because the show-function
    /// it declares is never invoked. This pins the distinction that motivates
    /// the scaffolder — storing `typst_source` directly as a new manuscript
    /// would hand the user an empty document.
    #[test]
    #[cfg(all(feature = "typst-render", feature = "uniffi"))]
    fn test_raw_template_source_is_valid_typst_but_renders_nothing() {
        let registry = templates::TemplateRegistry::new();
        let apj = registry.get("apj").expect("apj template should exist");

        let raw = compile_typst_to_pdf(apj.typst_source.clone(), CompileOptions::default());
        assert!(
            raw.error.is_none(),
            "raw apj source should be valid Typst, got: {:?}",
            raw.error
        );
        // The template mentions `#show: apj.with(...)` only inside its trailing
        // `// Usage:` comment — it never actually invokes it.
        let invokes_show = apj
            .typst_source
            .lines()
            .any(|l| !l.trim_start().starts_with("//") && l.trim_start().starts_with("#show:"));
        assert!(
            !invokes_show,
            "raw template source should declare a show-function, never invoke it"
        );

        let scaffolded = new_document_from_template(
            "apj".to_string(),
            FFIScaffoldOptions {
                title: "A Real Title".to_string(),
                ..FFIScaffoldOptions::default()
            },
        )
        .expect("apj should scaffold");
        assert!(scaffolded.contains("#show: apj.with("));

        let seeded = compile_typst_to_pdf(scaffolded, CompileOptions::default());
        assert!(
            seeded.error.is_none(),
            "scaffold should compile: {:?}",
            seeded.error
        );

        // The raw source renders a blank page; the scaffold renders a title,
        // an abstract and five sections. The byte counts are not close.
        let raw_bytes = raw.pdf_data.as_ref().map(|d| d.len()).unwrap_or(0);
        let seeded_bytes = seeded.pdf_data.as_ref().map(|d| d.len()).unwrap_or(0);
        assert!(
            seeded_bytes > raw_bytes * 2,
            "scaffolded PDF ({} bytes) should carry far more content than the \
             raw template's blank page ({} bytes)",
            seeded_bytes,
            raw_bytes
        );
    }

    #[test]
    #[cfg(feature = "uniffi")]
    fn test_ffi_template_listing_surface() {
        let listed = list_templates();
        assert_eq!(listed.len() as u32, template_count());
        assert!(
            listed.iter().any(|t| t.id == "apj"),
            "apj must be listed; ids seen: {:?}",
            listed.iter().map(|t| &t.id).collect::<Vec<_>>()
        );

        let apj = get_template("apj".to_string()).expect("apj should resolve");
        assert_eq!(apj.metadata.category, FFITemplateCategory::Journal);
        assert!(apj.metadata.is_builtin);
        assert!(!apj.typst_source.is_empty());
        assert_eq!(
            get_template_source("apj".to_string()).as_deref(),
            Some(apj.typst_source.as_str())
        );

        assert!(get_template("no-such-template".to_string()).is_none());
        assert!(new_document_from_template(
            "no-such-template".to_string(),
            FFIScaffoldOptions::default()
        )
        .is_none());

        let journals = list_templates_by_category(FFITemplateCategory::Journal);
        assert!(journals
            .iter()
            .all(|t| t.category == FFITemplateCategory::Journal));
        assert!(journals.iter().any(|t| t.id == "apj"));

        let hits = search_templates("astronomy".to_string());
        assert!(
            hits.iter().any(|t| t.id == "apj"),
            "searching 'astronomy' should surface apj"
        );
    }

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
