//! Typst rendering for document compilation
//!
//! This module provides Typst-based rendering capabilities for compiling documents
//! to various output formats (PDF, SVG, PNG). It integrates with the Typst typesetting
//! system to provide high-quality document output.
//!
//! # Feature Flag
//!
//! Typst rendering is behind the `typst-render` feature flag due to the heavyweight
//! dependencies involved. Enable it in your `Cargo.toml`:
//!
//! ```toml
//! [dependencies]
//! imprint-core = { version = "0.1", features = ["typst-render"] }
//! ```
//!
//! # Architecture
//!
//! The rendering system is built around the [`TypstRenderer`] trait which provides
//! a common interface for document compilation. The default implementation uses
//! `typst-as-lib` which provides a simplified API over the raw Typst compiler.
//!
//! ## Components
//!
//! - [`RenderOptions`]: Configuration for page size, fonts, and other render settings
//! - [`RenderOutput`]: The result of rendering (PDF bytes, SVG string, or PNG bytes)
//! - [`RenderCache`]: Cache for incremental rendering to improve performance
//! - [`TypstRenderer`]: Main trait for document compilation
//!
//! # Example
//!
//! ```rust,ignore
//! use imprint_core::render::{TypstRenderer, RenderOptions, DefaultTypstRenderer};
//!
//! let renderer = DefaultTypstRenderer::new();
//! let source = r#"
//! = Hello World
//! This is a #emph[Typst] document.
//! "#;
//!
//! let options = RenderOptions::default();
//! let output = renderer.render(source, &options)?;
//!
//! if let RenderOutput::Pdf(bytes) = output {
//!     std::fs::write("output.pdf", bytes)?;
//! }
//! ```

use thiserror::Error;

/// Errors that can occur during Typst rendering
#[derive(Error, Debug)]
pub enum RenderError {
    /// Typst compilation failed with source errors
    #[error("Typst compilation error: {0}")]
    CompilationError(String),

    /// PDF generation failed after successful compilation
    #[error("PDF generation error: {0}")]
    PdfError(String),

    /// SVG generation failed after successful compilation
    #[error("SVG generation error: {0}")]
    SvgError(String),

    /// PNG generation failed after successful compilation
    #[error("PNG generation error: {0}")]
    PngError(String),

    /// IO error during file operations
    #[error("IO error: {0}")]
    IoError(#[from] std::io::Error),

    /// Font loading or configuration error
    #[error("Font error: {0}")]
    FontError(String),

    /// The typst-render feature is not enabled
    #[error("Typst rendering requires the 'typst-render' feature")]
    FeatureNotEnabled,
}

/// Page size presets for common document formats
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum PageSize {
    /// US Letter (8.5 x 11 inches)
    Letter,
    /// A4 (210 x 297 mm)
    #[default]
    A4,
    /// A5 (148 x 210 mm)
    A5,
    /// Custom size in points (1 point = 1/72 inch)
    Custom { width: f64, height: f64 },
}

impl PageSize {
    /// Get the width in points
    pub fn width_pt(&self) -> f64 {
        match self {
            PageSize::Letter => 612.0, // 8.5 * 72
            PageSize::A4 => 595.28,    // 210mm in points
            PageSize::A5 => 419.53,    // 148mm in points
            PageSize::Custom { width, .. } => *width,
        }
    }

    /// Get the height in points
    pub fn height_pt(&self) -> f64 {
        match self {
            PageSize::Letter => 792.0, // 11 * 72
            PageSize::A4 => 841.89,    // 297mm in points
            PageSize::A5 => 595.28,    // 210mm in points
            PageSize::Custom { height, .. } => *height,
        }
    }
}

/// Render options for Typst compilation
///
/// These options control the output format and document configuration
/// for the Typst rendering process.
#[derive(Debug, Clone)]
pub struct RenderOptions {
    /// Page size for the document
    pub page_size: PageSize,

    /// Base font size in points (default: 11pt)
    pub font_size: f64,

    /// Page margins in points (top, right, bottom, left)
    pub margins: (f64, f64, f64, f64),

    /// Output format to generate
    pub output_format: OutputFormat,

    /// Additional font paths to search
    pub font_paths: Vec<String>,

    /// Whether to include metadata in the output
    pub include_metadata: bool,
}

impl Default for RenderOptions {
    fn default() -> Self {
        Self {
            page_size: PageSize::default(),
            font_size: 11.0,
            margins: (72.0, 72.0, 72.0, 72.0), // 1 inch margins
            output_format: OutputFormat::Pdf,
            font_paths: Vec::new(),
            include_metadata: true,
        }
    }
}

impl RenderOptions {
    /// Create options for A4 paper with default settings
    pub fn a4() -> Self {
        Self {
            page_size: PageSize::A4,
            ..Default::default()
        }
    }

    /// Create options for US Letter paper
    pub fn letter() -> Self {
        Self {
            page_size: PageSize::Letter,
            ..Default::default()
        }
    }

    /// Set the output format
    pub fn with_format(mut self, format: OutputFormat) -> Self {
        self.output_format = format;
        self
    }

    /// Set custom margins (top, right, bottom, left) in points
    pub fn with_margins(mut self, top: f64, right: f64, bottom: f64, left: f64) -> Self {
        self.margins = (top, right, bottom, left);
        self
    }

    /// Set the base font size in points
    pub fn with_font_size(mut self, size: f64) -> Self {
        self.font_size = size;
        self
    }

    /// Add a font search path
    pub fn with_font_path(mut self, path: impl Into<String>) -> Self {
        self.font_paths.push(path.into());
        self
    }

    /// Generate a Typst page setup preamble based on these options
    pub fn to_typst_preamble(&self) -> String {
        format!(
            r#"#set page(
  width: {}pt,
  height: {}pt,
  margin: (top: {}pt, right: {}pt, bottom: {}pt, left: {}pt),
)
#set text(size: {}pt)
"#,
            self.page_size.width_pt(),
            self.page_size.height_pt(),
            self.margins.0,
            self.margins.1,
            self.margins.2,
            self.margins.3,
            self.font_size
        )
    }
}

/// Output format for rendered documents
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OutputFormat {
    /// PDF output (default)
    #[default]
    Pdf,
    /// SVG output (vector graphics)
    Svg,
    /// PNG output (raster image)
    Png {
        /// Pixels per point for rasterization (default: 2.0 for 144 DPI)
        ppi: u32,
    },
}

/// A single entry in the real-layout source map.
///
/// Produced by walking the compiled Typst document's frames and resolving each
/// text run's glyph spans back to byte offsets in the *user* source (the
/// compile-time preamble prefix has already been subtracted). Coordinates are in
/// PDF points with a top-left origin (y grows downward), matching the click side
/// used for inverse-sync (preview → source).
///
/// This is an FFI-agnostic plain data struct so it can be produced regardless of
/// whether the `uniffi` feature is enabled, then mapped to `FFISourceMapEntry`
/// at the FFI boundary in `lib.rs`.
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutSourceMapEntry {
    /// Start byte offset in the user source (inclusive).
    pub source_start: usize,
    /// End byte offset in the user source (exclusive).
    pub source_end: usize,
    /// Zero-indexed page number.
    pub page: u32,
    /// Left edge x in points (top-left origin).
    pub x: f64,
    /// Top edge y in points (top-left origin).
    pub y: f64,
    /// Width in points.
    pub width: f64,
    /// Height in points.
    pub height: f64,
}

/// Severity of a structured Typst diagnostic.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TypstDiagnosticSeverity {
    Error,
    Warning,
}

/// One Typst compiler diagnostic, resolved against the *user* source.
///
/// Spans are resolved from Typst's `Span` into byte ranges of the compiled
/// source, then the compile-time preamble prefix is subtracted so offsets and
/// line numbers land in the text the user actually sees in the editor. A
/// diagnostic whose span lives outside the main file (package errors, file
/// errors) carries no range.
///
/// FFI-agnostic plain data, mapped to `FfiTypstDiagnostic` in `lib.rs`.
#[derive(Debug, Clone, PartialEq)]
pub struct TypstDiagnostic {
    pub severity: TypstDiagnosticSeverity,
    pub message: String,
    /// Byte range in the user source (UTF-8, preamble subtracted).
    pub source_start: Option<usize>,
    pub source_end: Option<usize>,
    /// 1-indexed line/character-column derived from `source_start`.
    pub line: Option<u32>,
    pub column: Option<u32>,
    /// Typst's own remediation hints ("did you mean …", "try …").
    pub hints: Vec<String>,
}

impl TypstDiagnostic {
    /// A single human-readable line: `error (line 12): message`.
    pub fn summary_line(&self) -> String {
        let sev = match self.severity {
            TypstDiagnosticSeverity::Error => "error",
            TypstDiagnosticSeverity::Warning => "warning",
        };
        match self.line {
            Some(line) => format!("{} (line {}): {}", sev, line, self.message),
            None => format!("{}: {}", sev, self.message),
        }
    }
}

/// A failed Typst compile: every diagnostic, plus a human-readable summary
/// (one `summary_line` per error, newline-joined) for surfaces that can only
/// show a string.
#[derive(Debug, Clone)]
pub struct TypstCompileError {
    pub summary: String,
    pub diagnostics: Vec<TypstDiagnostic>,
}

impl TypstCompileError {
    pub fn from_diagnostics(diagnostics: Vec<TypstDiagnostic>) -> Self {
        let summary = diagnostics
            .iter()
            .filter(|d| d.severity == TypstDiagnosticSeverity::Error)
            .map(TypstDiagnostic::summary_line)
            .collect::<Vec<_>>()
            .join("\n");
        let summary = if summary.is_empty() {
            "Typst compilation failed".to_string()
        } else {
            summary
        };
        Self {
            summary,
            diagnostics,
        }
    }

    /// A spanless failure (PDF/SVG generation, engine errors).
    pub fn message_only(summary: impl Into<String>) -> Self {
        let summary = summary.into();
        Self {
            diagnostics: vec![TypstDiagnostic {
                severity: TypstDiagnosticSeverity::Error,
                message: summary.clone(),
                source_start: None,
                source_end: None,
                line: None,
                column: None,
                hints: Vec::new(),
            }],
            summary,
        }
    }
}

impl std::fmt::Display for TypstCompileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.summary)
    }
}

impl std::error::Error for TypstCompileError {}

impl From<TypstCompileError> for RenderError {
    fn from(e: TypstCompileError) -> Self {
        RenderError::CompilationError(e.summary)
    }
}

/// 1-indexed (line, character-column) of a byte offset in `text`.
///
/// Columns count characters, not bytes, so they match what an editor's
/// line/column display shows. Offsets past the end clamp to the last position.
pub fn line_column_at(text: &str, byte_offset: usize) -> (u32, u32) {
    let clamped = byte_offset.min(text.len());
    let prefix = &text[..floor_char_boundary(text, clamped)];
    let line = prefix.bytes().filter(|&b| b == b'\n').count() as u32 + 1;
    let line_start = prefix.rfind('\n').map(|i| i + 1).unwrap_or(0);
    let column = prefix[line_start..].chars().count() as u32 + 1;
    (line, column)
}

/// Largest char boundary ≤ `index` (stable substitute for `str::floor_char_boundary`).
fn floor_char_boundary(text: &str, index: usize) -> usize {
    let mut i = index.min(text.len());
    while i > 0 && !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Result of rendering a document
#[derive(Debug)]
pub enum RenderOutput {
    /// PDF document bytes
    Pdf(Vec<u8>),
    /// SVG string (for single page) or vector of SVG strings (for multiple pages)
    Svg(Vec<String>),
    /// PNG image bytes (for single page) or vector of PNG bytes (for multiple pages)
    Png(Vec<Vec<u8>>),
}

impl RenderOutput {
    /// Get the output as PDF bytes, if this is a PDF output
    pub fn as_pdf(&self) -> Option<&[u8]> {
        match self {
            RenderOutput::Pdf(bytes) => Some(bytes),
            _ => None,
        }
    }

    /// Get the output as SVG strings, if this is an SVG output
    pub fn as_svg(&self) -> Option<&[String]> {
        match self {
            RenderOutput::Svg(svgs) => Some(svgs),
            _ => None,
        }
    }

    /// Get the output as PNG bytes, if this is a PNG output
    pub fn as_png(&self) -> Option<&[Vec<u8>]> {
        match self {
            RenderOutput::Png(pngs) => Some(pngs),
            _ => None,
        }
    }
}

/// Cache for incremental rendering
///
/// This cache stores compilation artifacts to speed up subsequent renders
/// of similar documents. The cache is invalidated when the document structure
/// changes significantly.
#[derive(Debug, Default)]
pub struct RenderCache {
    /// Hash of the last compiled source (for cache validation)
    source_hash: Option<u64>,

    /// Cached font data
    #[cfg(feature = "typst-render")]
    fonts_loaded: bool,

    #[cfg(not(feature = "typst-render"))]
    fonts_loaded: bool,
}

impl RenderCache {
    /// Create a new empty cache
    pub fn new() -> Self {
        Self::default()
    }

    /// Check if the cache is valid for the given source
    pub fn is_valid_for(&self, source: &str) -> bool {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        source.hash(&mut hasher);
        let hash = hasher.finish();

        self.source_hash == Some(hash)
    }

    /// Update the cache with a new source hash
    pub fn update_hash(&mut self, source: &str) {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};

        let mut hasher = DefaultHasher::new();
        source.hash(&mut hasher);
        self.source_hash = Some(hasher.finish());
    }

    /// Clear the cache
    pub fn clear(&mut self) {
        self.source_hash = None;
        self.fonts_loaded = false;
    }
}

/// Typst renderer trait for document compilation
///
/// This trait defines the interface for compiling Typst source code into
/// various output formats. Implementations may provide different backends
/// or optimizations.
pub trait TypstRenderer: Send + Sync {
    /// Render a Typst source document with the given options
    ///
    /// # Arguments
    ///
    /// * `source` - The Typst source code to compile
    /// * `options` - Rendering options (page size, fonts, etc.)
    ///
    /// # Returns
    ///
    /// The rendered output (PDF, SVG, or PNG) or an error
    fn render(&self, source: &str, options: &RenderOptions) -> Result<RenderOutput, RenderError>;

    /// Render with incremental caching for improved performance
    ///
    /// This method uses a cache to speed up repeated renders of similar documents.
    /// The cache stores compilation artifacts that can be reused.
    ///
    /// # Arguments
    ///
    /// * `source` - The Typst source code to compile
    /// * `options` - Rendering options
    /// * `cache` - Optional cache from a previous render
    ///
    /// # Returns
    ///
    /// A tuple of (output, updated_cache) or an error
    fn render_incremental(
        &self,
        source: &str,
        options: &RenderOptions,
        cache: Option<RenderCache>,
    ) -> Result<(RenderOutput, RenderCache), RenderError>;

    /// Check if the renderer is available (i.e., Typst is properly configured)
    fn is_available(&self) -> bool;

    /// Get the Typst version this renderer uses
    fn typst_version(&self) -> &'static str;
}

// ============================================================================
// Typst-enabled implementation (when typst-render feature is enabled)
// ============================================================================

#[cfg(feature = "typst-render")]
mod typst_impl {
    use super::*;
    use std::borrow::Cow;
    use std::collections::hash_map::DefaultHasher;
    use std::collections::HashMap;
    use std::hash::{Hash, Hasher};
    use std::path::PathBuf;
    use std::sync::{Arc, RwLock};
    use typst::diag::{FileError, FileResult};
    use typst::foundations::Bytes;
    use typst::syntax::{FileId, Source, VirtualPath};
    use typst_as_lib::file_resolver::FileResolver;
    use typst_as_lib::{
        typst_kit_options::TypstKitFontOptions, TypstEngine, TypstTemplateCollection,
    };

    /// File ID for the virtual main source file
    fn main_file_id() -> FileId {
        FileId::new(None, VirtualPath::new("/main.typ"))
    }

    /// A file resolver that reads source from shared mutable state.
    ///
    /// This allows updating the source text between compilations without
    /// rebuilding the TypstEngine (and re-scanning fonts).
    struct MutableSourceResolver {
        source: Arc<RwLock<Source>>,
        /// In-memory binary assets addressable from Typst as `image("/path")`.
        /// Enables embedding rasters (e.g. the big-N 2D-histogram fallback) with
        /// no filesystem. Keyed by the rootless virtual path ("hist.png").
        assets: Arc<RwLock<HashMap<PathBuf, Bytes>>>,
        /// Optional filesystem root for binary assets NOT in the in-memory map:
        /// `image("figures/plot.png")` resolves to
        /// `<figures_root>/figures/plot.png`. This is how manuscript figures
        /// (per-manuscript app-group dir) reach the compiler. Checked after the
        /// in-memory map; reads are per-compile (Typst's comemo caches the
        /// bytes between compiles).
        figures_root: Arc<RwLock<Option<PathBuf>>>,
    }

    impl MutableSourceResolver {
        fn new(
            initial_source: &str,
            assets: Arc<RwLock<HashMap<PathBuf, Bytes>>>,
            figures_root: Arc<RwLock<Option<PathBuf>>>,
        ) -> Self {
            let id = main_file_id();
            let source = Source::new(id, initial_source.to_string());
            Self {
                source: Arc::new(RwLock::new(source)),
                assets,
                figures_root,
            }
        }

        fn source_handle(&self) -> Arc<RwLock<Source>> {
            self.source.clone()
        }
    }

    impl FileResolver for MutableSourceResolver {
        fn resolve_binary(&self, id: FileId) -> FileResult<Cow<'_, Bytes>> {
            let key = id.vpath().as_rootless_path().to_path_buf();
            if let Some(bytes) = self.assets.read().unwrap().get(&key) {
                return Ok(Cow::Owned(bytes.clone()));
            }
            // Filesystem fallback: rooted at the manuscript's figures dir.
            // Containment guard: only plain relative components — a manuscript
            // source must not escape the root via `..` (join + starts_with is
            // NOT a containment check; it passes lexically).
            let contained = key
                .components()
                .all(|c| matches!(c, std::path::Component::Normal(_)));
            if contained {
                if let Some(root) = self.figures_root.read().unwrap().as_ref() {
                    if let Ok(bytes) = std::fs::read(root.join(&key)) {
                        return Ok(Cow::Owned(Bytes::new(bytes)));
                    }
                }
            }
            Err(FileError::NotFound(
                id.vpath().as_rootless_path().to_path_buf(),
            ))
        }

        fn resolve_source(&self, id: FileId) -> FileResult<Cow<'_, Source>> {
            if id == main_file_id() {
                let source = self.source.read().unwrap();
                Ok(Cow::Owned(source.clone()))
            } else {
                Err(FileError::NotFound(
                    id.vpath().as_rootless_path().to_path_buf(),
                ))
            }
        }
    }

    /// Persistent Typst renderer that reuses the TypstEngine across compilations.
    ///
    /// Fonts are loaded once on first use. comemo caches persist between compiles,
    /// enabling Typst's built-in incremental compilation (only re-laying-out
    /// changed content on small edits).
    #[derive(Default)]
    pub struct PersistentTypstRenderer {
        /// The reusable engine (built lazily on first render)
        engine: Option<TypstEngine<TypstTemplateCollection>>,
        /// Shared mutable source — updated before each compile
        source_handle: Option<Arc<RwLock<Source>>>,
        /// Hash of the last RenderOptions preamble — engine rebuilt if options change
        last_preamble_hash: Option<u64>,
        /// In-memory binary assets served to Typst `image("/path")`. Owned here
        /// (not by the resolver) so registrations survive engine rebuilds; the
        /// resolver holds a clone of this handle.
        assets: Arc<RwLock<HashMap<PathBuf, Bytes>>>,
        /// Filesystem root for on-disk figure assets (see resolver docs). Owned
        /// here for the same engine-rebuild-survival reason.
        figures_root: Arc<RwLock<Option<PathBuf>>>,
    }

    /// What a successful render hands back: the output (PDF bytes or SVG
    /// pages), the page count, the real-layout source map, and the compile
    /// warnings as structured diagnostics.
    #[derive(Debug)]
    pub struct TypstRenderSuccess {
        pub output: RenderOutput,
        pub page_count: u32,
        pub source_map: Vec<LayoutSourceMapEntry>,
        pub warnings: Vec<TypstDiagnostic>,
    }

    impl PersistentTypstRenderer {
        pub fn new() -> Self {
            Self::default()
        }

        /// Register an in-memory binary asset addressable from Typst source as
        /// `image("/<path>")`. This is how rasters reach the compiler without a
        /// filesystem — the intended embedding path for the big-N 2D-histogram
        /// fallback (and, generally, for figure images). Survives engine
        /// rebuilds; overwrites an existing asset at the same path.
        pub fn set_asset(&mut self, path: &str, bytes: Vec<u8>) {
            let key = VirtualPath::new(path).as_rootless_path().to_path_buf();
            self.assets.write().unwrap().insert(key, Bytes::new(bytes));
        }

        /// Drop all registered binary assets.
        pub fn clear_assets(&mut self) {
            self.assets.write().unwrap().clear();
        }

        /// Set (or clear) the filesystem root for on-disk figure assets —
        /// `image("figures/plot.png")` in the source resolves to
        /// `<root>/figures/plot.png`. Per-manuscript callers set this before
        /// each compile (cheap; no engine rebuild).
        pub fn set_figures_root(&mut self, root: Option<&str>) {
            *self.figures_root.write().unwrap() = root.map(PathBuf::from);
        }

        /// Set (or clear) the in-memory bibliography served to Typst as
        /// `bibliography("bibliography.bib")`. Rides the existing asset map
        /// (bib files are loaded through `resolve_binary` like any other
        /// file), so no resolver changes and no engine rebuild — comemo
        /// re-reads on content change exactly as it does for `set_asset`
        /// images. `None` removes the virtual file so a stale bibliography
        /// never outlives its manuscript.
        pub fn set_bib_source(&mut self, bib: Option<&str>) {
            let key = VirtualPath::new("bibliography.bib")
                .as_rootless_path()
                .to_path_buf();
            let mut assets = self.assets.write().unwrap();
            match bib {
                Some(text) => {
                    assets.insert(key, Bytes::new(text.as_bytes().to_vec()));
                }
                None => {
                    assets.remove(&key);
                }
            }
        }

        /// Hash a preamble string for change detection
        fn hash_preamble(preamble: &str) -> u64 {
            let mut hasher = DefaultHasher::new();
            preamble.hash(&mut hasher);
            hasher.finish()
        }

        /// Build or rebuild the engine (loads fonts, sets up resolvers)
        fn ensure_engine(&mut self, preamble: &str, initial_source: &str) {
            let preamble_hash = Self::hash_preamble(preamble);
            let needs_rebuild =
                self.engine.is_none() || self.last_preamble_hash != Some(preamble_hash);

            if needs_rebuild {
                let t0 = std::time::Instant::now();

                let resolver = MutableSourceResolver::new(
                    initial_source,
                    self.assets.clone(),
                    self.figures_root.clone(),
                );
                self.source_handle = Some(resolver.source_handle());

                let mut builder = TypstEngine::builder()
                    .add_file_resolver(resolver)
                    .search_fonts_with(
                        TypstKitFontOptions::default()
                            .include_system_fonts(true)
                            .include_embedded_fonts(true),
                    );
                // Keep comemo caches for 30 eviction cycles (compiles) to enable
                // incremental compilation across small edits
                builder.comemo_evict_max_age(Some(30));
                let engine = builder.build();

                let elapsed = t0.elapsed();
                eprintln!(
                    "[imprint-core] Engine built in {:.1}ms (fonts loaded, preamble_hash={:#x})",
                    elapsed.as_secs_f64() * 1000.0,
                    preamble_hash,
                );

                self.engine = Some(engine);
                self.last_preamble_hash = Some(preamble_hash);
            }
        }

        /// Update the shared source text before compilation.
        ///
        /// Uses `Source::replace()` which diffs against the old text and does a minimal
        /// edit, preserving the Source's internal revision tracking. This is critical for
        /// comemo memoization — a fresh `Source::new()` would increment the revision and
        /// invalidate all cached computation, defeating incremental compilation.
        fn update_source(&self, full_source: &str) {
            if let Some(handle) = &self.source_handle {
                let mut guard = handle.write().unwrap();
                guard.replace(full_source);
            }
        }

        /// Resolve one Typst `SourceDiagnostic` into the structured,
        /// user-source-relative form. `source` is the LIVE compiled source
        /// (preamble included) so spans resolve; `prefix` is the preamble
        /// byte length to subtract.
        fn resolve_diagnostic(
            d: &typst::diag::SourceDiagnostic,
            source: &Source,
            prefix: usize,
        ) -> TypstDiagnostic {
            let severity = match d.severity {
                typst::diag::Severity::Error => TypstDiagnosticSeverity::Error,
                typst::diag::Severity::Warning => TypstDiagnosticSeverity::Warning,
            };
            let mut out = TypstDiagnostic {
                severity,
                message: d.message.to_string(),
                source_start: None,
                source_end: None,
                line: None,
                column: None,
                hints: d.hints.iter().map(|h| h.to_string()).collect(),
            };
            // `Source::range` returns None for spans outside the main file
            // (package/file errors) — those stay spanless.
            if let Some(range) = source.range(d.span) {
                let start = range.start.saturating_sub(prefix);
                let end = range.end.saturating_sub(prefix).max(start);
                let user_text = &source.text()[prefix.min(source.text().len())..];
                let (line, column) = line_column_at(user_text, start);
                out.source_start = Some(start);
                out.source_end = Some(end);
                out.line = Some(line);
                out.column = Some(column);
            }
            out
        }

        /// Resolve every diagnostic in `diags` against the live source handle.
        fn resolve_diagnostics(
            &self,
            diags: &[typst::diag::SourceDiagnostic],
            options: &RenderOptions,
        ) -> Vec<TypstDiagnostic> {
            let prefix = Self::preamble_prefix_len(options);
            let Some(handle) = &self.source_handle else {
                return diags
                    .iter()
                    .map(Self::resolve_diagnostic_spanless)
                    .collect();
            };
            match handle.read() {
                Ok(guard) => diags
                    .iter()
                    .map(|d| Self::resolve_diagnostic(d, &guard, prefix))
                    .collect(),
                Err(_) => diags
                    .iter()
                    .map(Self::resolve_diagnostic_spanless)
                    .collect(),
            }
        }

        /// Fallback when the source handle is unavailable: message + hints only.
        fn resolve_diagnostic_spanless(d: &typst::diag::SourceDiagnostic) -> TypstDiagnostic {
            TypstDiagnostic {
                severity: match d.severity {
                    typst::diag::Severity::Error => TypstDiagnosticSeverity::Error,
                    typst::diag::Severity::Warning => TypstDiagnosticSeverity::Warning,
                },
                message: d.message.to_string(),
                source_start: None,
                source_end: None,
                line: None,
                column: None,
                hints: d.hints.iter().map(|h| h.to_string()).collect(),
            }
        }

        /// Map a compile failure into structured diagnostics. Source errors
        /// resolve to user-source ranges; every other failure mode becomes a
        /// single spanless error (with Typst's hints where it carries them).
        fn compile_error_diagnostics(
            &self,
            e: &typst_as_lib::TypstAsLibError,
            options: &RenderOptions,
        ) -> Vec<TypstDiagnostic> {
            use typst_as_lib::TypstAsLibError;
            match e {
                TypstAsLibError::TypstSource(diags) => self.resolve_diagnostics(diags, options),
                TypstAsLibError::HintedString(hinted) => vec![TypstDiagnostic {
                    severity: TypstDiagnosticSeverity::Error,
                    message: hinted.message().to_string(),
                    source_start: None,
                    source_end: None,
                    line: None,
                    column: None,
                    hints: hinted.hints().iter().map(|h| h.to_string()).collect(),
                }],
                other => vec![TypstDiagnostic {
                    severity: TypstDiagnosticSeverity::Error,
                    message: other.to_string(),
                    source_start: None,
                    source_end: None,
                    line: None,
                    column: None,
                    hints: Vec::new(),
                }],
            }
        }

        /// Compile the current source into a typst PagedDocument.
        ///
        /// Shared by both PDF and SVG export paths. Warnings come back as
        /// structured diagnostics; a failure carries every error diagnostic
        /// resolved to user-source lines.
        fn compile_document(
            &mut self,
            source: &str,
            options: &RenderOptions,
        ) -> Result<(typst::layout::PagedDocument, Vec<TypstDiagnostic>), TypstCompileError>
        {
            let preamble = options.to_typst_preamble();
            let full_source = format!("{}\n{}", preamble, source);

            self.ensure_engine(&preamble, &full_source);
            self.update_source(&full_source);

            let engine = self.engine.as_ref().unwrap();

            let t0 = std::time::Instant::now();
            let compiled: typst::diag::Warned<
                Result<typst::layout::PagedDocument, typst_as_lib::TypstAsLibError>,
            > = engine.compile("/main.typ");
            let compile_elapsed = t0.elapsed();

            let warnings = self.resolve_diagnostics(&compiled.warnings, options);
            for w in &warnings {
                eprintln!("Typst warning: {}", w.summary_line());
            }

            let document = match compiled.output {
                Ok(document) => document,
                Err(e) => {
                    let mut diagnostics = self.compile_error_diagnostics(&e, options);
                    diagnostics.extend(warnings);
                    return Err(TypstCompileError::from_diagnostics(diagnostics));
                }
            };

            eprintln!(
                "[imprint-core] Compiled in {:.1}ms ({} pages)",
                compile_elapsed.as_secs_f64() * 1000.0,
                document.pages.len(),
            );

            Ok((document, warnings))
        }

        /// The byte length of the compile-time preamble prefix prepended to the
        /// user source in `compile_document` (`preamble.len() + 1` for the
        /// joining newline). Resolved spans below this offset are preamble-origin.
        fn preamble_prefix_len(options: &RenderOptions) -> usize {
            options.to_typst_preamble().len() + 1
        }

        /// Build the real-layout source map from the live document + compiled
        /// source held in `source_handle` (which contains the full source,
        /// preamble included).
        fn layout_source_map(
            &self,
            document: &PagedDocument,
            options: &RenderOptions,
        ) -> Vec<LayoutSourceMapEntry> {
            let prefix = Self::preamble_prefix_len(options);
            if let Some(handle) = &self.source_handle {
                if let Ok(guard) = handle.read() {
                    return build_layout_source_map(document, &guard, prefix);
                }
            }
            Vec::new()
        }

        /// Render source to PDF, along with real-layout source-map entries and
        /// structured warnings.
        pub fn render_pdf(
            &mut self,
            source: &str,
            options: &RenderOptions,
        ) -> Result<TypstRenderSuccess, TypstCompileError> {
            let (document, warnings) = self.compile_document(source, options)?;

            // Build the source map while the document + compiled source are live.
            let source_map = self.layout_source_map(&document, options);
            let page_count = document.pages.len() as u32;

            let t0 = std::time::Instant::now();
            let pdf_options = typst_pdf::PdfOptions::default();
            let pdf_bytes = typst_pdf::pdf(&document, &pdf_options).map_err(|e| {
                TypstCompileError::message_only(format!("PDF generation error: {:?}", e))
            })?;
            let elapsed = t0.elapsed();

            eprintln!(
                "[imprint-core] PDF generated in {:.1}ms ({} bytes, {} source-map entries)",
                elapsed.as_secs_f64() * 1000.0,
                pdf_bytes.len(),
                source_map.len(),
            );

            Ok(TypstRenderSuccess {
                output: RenderOutput::Pdf(pdf_bytes),
                page_count,
                source_map,
                warnings,
            })
        }

        /// Render source to SVG (one string per page), along with real-layout
        /// source-map entries and structured warnings.
        pub fn render_svg(
            &mut self,
            source: &str,
            options: &RenderOptions,
        ) -> Result<TypstRenderSuccess, TypstCompileError> {
            let (document, warnings) = self.compile_document(source, options)?;

            // Build the source map while the document + compiled source are live.
            let source_map = self.layout_source_map(&document, options);

            let t0 = std::time::Instant::now();
            let svgs: Vec<String> = document.pages.iter().map(typst_svg::svg).collect();
            let elapsed = t0.elapsed();

            eprintln!(
                "[imprint-core] SVG generated in {:.1}ms ({} pages, {} source-map entries)",
                elapsed.as_secs_f64() * 1000.0,
                svgs.len(),
                source_map.len(),
            );

            let page_count = document.pages.len() as u32;
            Ok(TypstRenderSuccess {
                output: RenderOutput::Svg(svgs),
                page_count,
                source_map,
                warnings,
            })
        }
    }

    // ========================================================================
    // Real-layout source map (inverse-sync: preview click → source offset)
    // ========================================================================

    use typst::layout::{Frame, FrameItem, PagedDocument, Transform};
    use typst::text::TextItem;

    /// Build a source map from the *real* compiled layout.
    ///
    /// Walks every page frame (recursing into groups with an accumulated affine
    /// transform), resolves each text run's glyph spans back into byte ranges of
    /// the compiled `source`, subtracts the preamble prefix so offsets land in the
    /// user's source, and emits a bounding box per run in top-left PDF points.
    ///
    /// `preamble_prefix_len` is the byte length of the compile-time preamble plus
    /// the joining newline (`preamble.len() + 1`). Any span whose range starts
    /// before that boundary originates in the preamble and is skipped.
    ///
    /// Never panics: items with no resolvable span are skipped.
    pub fn build_layout_source_map(
        document: &PagedDocument,
        source: &Source,
        preamble_prefix_len: usize,
    ) -> Vec<LayoutSourceMapEntry> {
        let mut entries = Vec::new();
        for (page_index, page) in document.pages.iter().enumerate() {
            walk_frame(
                &page.frame,
                Transform::identity(),
                page_index as u32,
                source,
                preamble_prefix_len,
                &mut entries,
            );
        }
        entries
    }

    /// Recurse a frame, accumulating the affine transform down into groups.
    fn walk_frame(
        frame: &Frame,
        transform: Transform,
        page: u32,
        source: &Source,
        preamble_prefix_len: usize,
        out: &mut Vec<LayoutSourceMapEntry>,
    ) {
        for (pos, item) in frame.items() {
            // Fold the item's in-frame position into the transform. After this,
            // the transform's translation component (tx, ty) IS the item's
            // absolute on-page origin.
            let item_ts = transform.pre_concat(Transform::translate(pos.x, pos.y));
            match item {
                FrameItem::Group(group) => {
                    // Compose the group's own transform (full affine); this holds
                    // for both Soft and Hard frame kinds when computing absolute
                    // page coordinates (the Soft/Hard split only matters for how
                    // SVG output resets coordinates, not for geometry).
                    let child_ts = item_ts.pre_concat(group.transform);
                    walk_frame(
                        &group.frame,
                        child_ts,
                        page,
                        source,
                        preamble_prefix_len,
                        out,
                    );
                }
                FrameItem::Text(text) => {
                    if let Some(entry) =
                        text_entry(text, item_ts, page, source, preamble_prefix_len)
                    {
                        out.push(entry);
                    }
                }
                // Shapes/images/links/tags carry spans too, but without readily
                // available tight bounds (and shape spans are frequently
                // detached), so text runs are the reliable inverse-sync anchors.
                _ => {}
            }
        }
    }

    /// Build an entry for a text run, or `None` if no glyph span resolves into
    /// user-source territory.
    fn text_entry(
        text: &TextItem,
        item_ts: Transform,
        page: u32,
        source: &Source,
        preamble_prefix_len: usize,
    ) -> Option<LayoutSourceMapEntry> {
        // Union the byte ranges of every glyph that resolves, so the emitted span
        // covers the whole rendered run (e.g. "Hello") rather than one glyph.
        let mut start: Option<usize> = None;
        let mut end: Option<usize> = None;
        for glyph in &text.glyphs {
            if let Some(range) = source.range(glyph.span.0) {
                // Skip preamble-origin content.
                if range.start < preamble_prefix_len {
                    continue;
                }
                let s = range.start - preamble_prefix_len;
                let e = range.end.saturating_sub(preamble_prefix_len);
                start = Some(start.map_or(s, |cur| cur.min(s)));
                end = Some(end.map_or(e, |cur| cur.max(e)));
            }
        }
        let (source_start, source_end) = (start?, end?);
        if source_end <= source_start {
            return None;
        }

        // The transform's translation is the run's baseline start point.
        let baseline_x = item_ts.tx.to_pt();
        let baseline_y = item_ts.ty.to_pt();
        let size_pt = text.size.to_pt();
        let width = text.width().to_pt();
        // Convert the baseline anchor to a top-left box: the ascent is ~1em, so
        // the visual top sits roughly one font-size above the baseline.
        let top_y = baseline_y - size_pt;
        let height = size_pt * 1.2;

        Some(LayoutSourceMapEntry {
            source_start,
            source_end,
            page,
            x: baseline_x,
            y: top_y,
            width,
            height,
        })
    }

    /// Default Typst renderer using typst-as-lib
    ///
    /// This renderer provides a production-ready implementation using the
    /// `typst-as-lib` crate which simplifies the Typst World trait implementation.
    /// NOTE: This is the legacy stateless renderer, kept for backward compatibility.
    /// The PersistentTypstRenderer (used via thread_local! in lib.rs) is preferred.
    pub struct DefaultTypstRenderer {
        // Configuration is handled per-render via RenderOptions
    }

    impl DefaultTypstRenderer {
        /// Create a new Typst renderer
        pub fn new() -> Self {
            Self {}
        }
    }

    impl Default for DefaultTypstRenderer {
        fn default() -> Self {
            Self::new()
        }
    }

    impl TypstRenderer for DefaultTypstRenderer {
        fn render(
            &self,
            source: &str,
            options: &RenderOptions,
        ) -> Result<RenderOutput, RenderError> {
            let source_owned = source.to_string();
            let options_clone = options.clone();

            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                Self::render_inner(&source_owned, &options_clone)
            }));

            match result {
                Ok(inner_result) => inner_result,
                Err(panic_info) => {
                    let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                        s.to_string()
                    } else if let Some(s) = panic_info.downcast_ref::<String>() {
                        s.clone()
                    } else {
                        "Unknown panic during Typst rendering".to_string()
                    };
                    Err(RenderError::CompilationError(format!(
                        "Internal error during rendering: {}",
                        panic_msg
                    )))
                }
            }
        }

        fn render_incremental(
            &self,
            source: &str,
            options: &RenderOptions,
            cache: Option<RenderCache>,
        ) -> Result<(RenderOutput, RenderCache), RenderError> {
            let mut cache = cache.unwrap_or_default();
            let output = self.render(source, options)?;
            cache.update_hash(source);
            Ok((output, cache))
        }

        fn is_available(&self) -> bool {
            true
        }

        fn typst_version(&self) -> &'static str {
            "0.14"
        }
    }

    impl DefaultTypstRenderer {
        /// Inner render function that may panic - wrapped by render()
        fn render_inner(
            source: &str,
            options: &RenderOptions,
        ) -> Result<RenderOutput, RenderError> {
            use typst_as_lib::{typst_kit_options::TypstKitFontOptions, TypstEngine};

            let full_source = format!("{}\n{}", options.to_typst_preamble(), source);

            let engine = TypstEngine::builder()
                .main_file(full_source.as_str())
                .search_fonts_with(
                    TypstKitFontOptions::default()
                        .include_system_fonts(true)
                        .include_embedded_fonts(true),
                )
                .build();

            let compiled = engine.compile();

            if !compiled.warnings.is_empty() {
                for warning in &compiled.warnings {
                    eprintln!("Typst warning: {:?}", warning);
                }
            }

            let document = compiled
                .output
                .map_err(|e| RenderError::CompilationError(format!("{:?}", e)))?;

            match options.output_format {
                OutputFormat::Pdf => {
                    let pdf_options = typst_pdf::PdfOptions::default();
                    let pdf_bytes = typst_pdf::pdf(&document, &pdf_options)
                        .map_err(|e| RenderError::PdfError(format!("{:?}", e)))?;
                    Ok(RenderOutput::Pdf(pdf_bytes))
                }
                OutputFormat::Svg => {
                    let svgs: Vec<String> = document.pages.iter().map(typst_svg::svg).collect();
                    Ok(RenderOutput::Svg(svgs))
                }
                OutputFormat::Png { ppi: _ } => Err(RenderError::PngError(
                    "PNG rendering requires the typst-render crate with resvg. \
                         Consider rendering to SVG and converting with an image library."
                        .to_string(),
                )),
            }
        }
    }
}

#[cfg(feature = "typst-render")]
pub use typst_impl::DefaultTypstRenderer;

#[cfg(feature = "typst-render")]
pub use typst_impl::{PersistentTypstRenderer, TypstRenderSuccess};

// ============================================================================
// Stub implementation (when typst-render feature is NOT enabled)
// ============================================================================

#[cfg(not(feature = "typst-render"))]
mod stub_impl {
    use super::*;

    /// Stub Typst renderer for when the typst-render feature is disabled
    ///
    /// This renderer returns placeholder output and is useful for:
    /// - Testing the API without the full Typst dependency
    /// - Building on systems where Typst compilation is slow
    /// - Developing UI/UX without actual document rendering
    ///
    /// Enable the `typst-render` feature for actual rendering.
    pub struct DefaultTypstRenderer {
        _private: (),
    }

    impl DefaultTypstRenderer {
        /// Create a new stub renderer
        ///
        /// Note: This is a stub implementation. Enable the `typst-render` feature
        /// for actual Typst rendering capabilities.
        pub fn new() -> Self {
            Self { _private: () }
        }
    }

    impl Default for DefaultTypstRenderer {
        fn default() -> Self {
            Self::new()
        }
    }

    impl TypstRenderer for DefaultTypstRenderer {
        fn render(
            &self,
            source: &str,
            options: &RenderOptions,
        ) -> Result<RenderOutput, RenderError> {
            // Return a minimal valid PDF as a placeholder
            // This is a very minimal PDF that shows a message
            let placeholder_pdf = generate_placeholder_pdf(source, options);
            Ok(RenderOutput::Pdf(placeholder_pdf))
        }

        fn render_incremental(
            &self,
            source: &str,
            options: &RenderOptions,
            cache: Option<RenderCache>,
        ) -> Result<(RenderOutput, RenderCache), RenderError> {
            let mut cache = cache.unwrap_or_default();
            let output = self.render(source, options)?;
            cache.update_hash(source);
            Ok((output, cache))
        }

        fn is_available(&self) -> bool {
            // Stub is always "available" but won't produce real output
            false
        }

        fn typst_version(&self) -> &'static str {
            "stub (enable typst-render feature)"
        }
    }

    /// Generate a minimal placeholder PDF
    ///
    /// This creates a valid but minimal PDF file that indicates rendering
    /// is not available without the typst-render feature.
    fn generate_placeholder_pdf(_source: &str, _options: &RenderOptions) -> Vec<u8> {
        // Minimal PDF structure
        // This is a valid PDF that displays a single page with a message
        let pdf = br#"%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>
endobj
4 0 obj
<< /Length 89 >>
stream
BT
/F1 12 Tf
100 700 Td
(Typst rendering requires the typst-render feature) Tj
ET
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 6
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000115 00000 n
0000000266 00000 n
0000000406 00000 n
trailer
<< /Size 6 /Root 1 0 R >>
startxref
478
%%EOF"#;
        pdf.to_vec()
    }
}

#[cfg(not(feature = "typst-render"))]
pub use stub_impl::DefaultTypstRenderer;

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_render_options_default() {
        let options = RenderOptions::default();
        assert_eq!(options.page_size, PageSize::A4);
        assert_eq!(options.font_size, 11.0);
    }

    #[test]
    fn test_render_options_builder() {
        let options = RenderOptions::letter()
            .with_font_size(12.0)
            .with_margins(36.0, 36.0, 36.0, 36.0)
            .with_format(OutputFormat::Svg);

        assert_eq!(options.page_size, PageSize::Letter);
        assert_eq!(options.font_size, 12.0);
        assert_eq!(options.output_format, OutputFormat::Svg);
    }

    #[test]
    fn test_page_size_dimensions() {
        let letter = PageSize::Letter;
        assert!((letter.width_pt() - 612.0).abs() < 0.01);
        assert!((letter.height_pt() - 792.0).abs() < 0.01);

        let a4 = PageSize::A4;
        assert!((a4.width_pt() - 595.28).abs() < 0.01);
        assert!((a4.height_pt() - 841.89).abs() < 0.01);
    }

    #[test]
    fn test_typst_preamble_generation() {
        let options = RenderOptions::default();
        let preamble = options.to_typst_preamble();

        assert!(preamble.contains("#set page("));
        assert!(preamble.contains("#set text(size:"));
    }

    #[test]
    fn test_render_cache() {
        let mut cache = RenderCache::new();
        let source = "= Test\nHello world";

        assert!(!cache.is_valid_for(source));

        cache.update_hash(source);
        assert!(cache.is_valid_for(source));

        // Different source should invalidate
        assert!(!cache.is_valid_for("= Different\nContent"));

        cache.clear();
        assert!(!cache.is_valid_for(source));
    }

    #[test]
    fn test_stub_renderer_produces_valid_pdf() {
        let renderer = DefaultTypstRenderer::new();
        let source = "= Hello\nWorld";
        let options = RenderOptions::default();

        let result = renderer.render(source, &options);
        assert!(result.is_ok());

        if let Ok(RenderOutput::Pdf(bytes)) = result {
            // Check PDF magic bytes
            assert!(bytes.starts_with(b"%PDF-"));
        }
    }

    /// Real-layout source map: compiling a small document and walking its frames
    /// must produce entries whose byte ranges slice back to the rendered tokens in
    /// the *user* source (preamble prefix already subtracted), on page 0, with
    /// finite positive geometry.
    #[cfg(feature = "typst-render")]
    #[test]
    fn test_layout_source_map_real_frames() {
        let source = "= Heading\n\nHello world";
        let options = RenderOptions::default();

        let mut renderer = PersistentTypstRenderer::new();
        let success = renderer
            .render_pdf(source, &options)
            .expect("compile should succeed");
        let entries = success.source_map;

        // (a) entries are non-empty
        assert!(
            !entries.is_empty(),
            "expected real-layout source map entries, got none"
        );

        // (c) every entry is on page 0 with finite, positive geometry, and its
        //     byte range lies within the user source.
        for e in &entries {
            assert_eq!(e.page, 0, "single-page doc → all entries on page 0");
            assert!(
                e.x.is_finite() && e.x >= 0.0,
                "x finite & non-negative: {}",
                e.x
            );
            assert!(e.y.is_finite(), "y finite: {}", e.y);
            assert!(
                e.width.is_finite() && e.width > 0.0,
                "width positive: {}",
                e.width
            );
            assert!(
                e.height.is_finite() && e.height > 0.0,
                "height positive: {}",
                e.height
            );
            assert!(
                e.source_start < e.source_end && e.source_end <= source.len(),
                "range [{}, {}) within user source (len {})",
                e.source_start,
                e.source_end,
                source.len()
            );
        }

        // (b) the entries' slices of the USER source recover the rendered tokens.
        let slices: Vec<&str> = entries
            .iter()
            .map(|e| &source[e.source_start..e.source_end])
            .collect();
        let joined = slices.join("|");
        assert!(
            slices.iter().any(|s| s.contains("Heading")),
            "expected an entry covering 'Heading', slices: {joined}"
        );
        assert!(
            slices.iter().any(|s| s.contains("Hello")),
            "expected an entry covering 'Hello', slices: {joined}"
        );

        // At least one entry must have a strictly positive top-left x inside the
        // page margins (sanity that coordinates are page-absolute points).
        assert!(
            entries.iter().any(|e| e.x > 1.0),
            "expected page-absolute x coordinates (> 1pt margin)"
        );
    }

    #[test]
    fn test_line_column_at() {
        let text = "abc\ndef\nghi";
        assert_eq!(line_column_at(text, 0), (1, 1));
        assert_eq!(line_column_at(text, 2), (1, 3));
        assert_eq!(line_column_at(text, 4), (2, 1));
        assert_eq!(line_column_at(text, 9), (3, 2));
        // Past the end clamps to the last position.
        assert_eq!(line_column_at(text, 999), (3, 4));
        // Multi-byte: column counts characters, not bytes.
        let uni = "é✓\nx";
        assert_eq!(line_column_at(uni, uni.find('\n').unwrap()), (1, 3));
    }

    /// A compile error must come back as a structured diagnostic whose line
    /// number is in USER-source coordinates (preamble subtracted), with
    /// Typst's hints attached — not as a stringified Debug dump.
    #[cfg(feature = "typst-render")]
    #[test]
    fn test_compile_error_structured_diagnostics() {
        // Line 3 of the user source references an unknown variable.
        let source = "= Title\n\n#undefined_variable_xyz\n";
        let options = RenderOptions::default();

        let mut renderer = PersistentTypstRenderer::new();
        let err = renderer
            .render_pdf(source, &options)
            .expect_err("compile should fail");

        // The summary is human-readable: no Debug formatting artifacts.
        assert!(
            !err.summary.contains("SourceDiagnostic"),
            "summary must not be a Debug dump: {}",
            err.summary
        );
        assert!(
            err.summary.contains("unknown variable"),
            "summary should carry the Typst message: {}",
            err.summary
        );

        let diag = err
            .diagnostics
            .iter()
            .find(|d| d.severity == TypstDiagnosticSeverity::Error)
            .expect("at least one error diagnostic");
        assert_eq!(
            diag.line,
            Some(3),
            "error is on user-source line 3: {diag:?}"
        );
        assert!(diag.column.is_some());
        let (s, e) = (diag.source_start.unwrap(), diag.source_end.unwrap());
        assert!(
            source[s..e].contains("undefined_variable_xyz"),
            "span should cover the offending token, got {:?}",
            &source[s..e]
        );
    }

    /// A missing file (the exact class from the bug report: a #bibliography
    /// pointing at a file that is not there) resolves to the right line too.
    #[cfg(feature = "typst-render")]
    #[test]
    fn test_missing_file_error_has_line() {
        let source = "= Title\n#bibliography(\"analytic-path-references.bib\")\n";
        let options = RenderOptions::default();

        let mut renderer = PersistentTypstRenderer::new();
        let err = renderer
            .render_pdf(source, &options)
            .expect_err("compile should fail");
        let diag = &err.diagnostics[0];
        assert!(
            diag.message.contains("file not found"),
            "message: {}",
            diag.message
        );
        assert_eq!(diag.line, Some(2), "{diag:?}");
    }

    #[test]
    fn test_render_output_accessors() {
        let pdf = RenderOutput::Pdf(vec![1, 2, 3]);
        assert!(pdf.as_pdf().is_some());
        assert!(pdf.as_svg().is_none());
        assert!(pdf.as_png().is_none());

        let svg = RenderOutput::Svg(vec!["<svg></svg>".to_string()]);
        assert!(svg.as_pdf().is_none());
        assert!(svg.as_svg().is_some());

        let png = RenderOutput::Png(vec![vec![1, 2, 3]]);
        assert!(png.as_png().is_some());
    }
}
