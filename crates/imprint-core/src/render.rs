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

    /// Default Typst renderer using typst-as-lib
    ///
    /// This renderer provides a production-ready implementation using the
    /// `typst-as-lib` crate which simplifies the Typst World trait implementation.
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
            use typst_as_lib::{typst_kit_options::TypstKitFontOptions, TypstEngine};

            // Prepend the page setup preamble to the source
            let full_source = format!("{}\n{}", options.to_typst_preamble(), source);

            // Build the Typst engine with the source
            // Include embedded fonts for math and text rendering
            let engine = TypstEngine::builder()
                .main_file(full_source.as_str())
                .search_fonts_with(
                    TypstKitFontOptions::default()
                        .include_system_fonts(true) // Use system fonts if available
                        .include_embedded_fonts(true), // Use embedded fonts (Libertinus, New CM, DejaVu)
                )
                .build();

            // Compile the document - returns Warned<Result<Doc, TypstAsLibError>>
            let compiled = engine.compile();

            // Check for compilation warnings (non-fatal)
            if !compiled.warnings.is_empty() {
                for warning in &compiled.warnings {
                    eprintln!("Typst warning: {:?}", warning);
                }
            }

            // Extract the document from the compilation result
            let document = compiled
                .output
                .map_err(|e| RenderError::CompilationError(format!("{:?}", e)))?;

            // Generate output based on the requested format
            match options.output_format {
                OutputFormat::Pdf => {
                    let pdf_options = typst_pdf::PdfOptions::default();
                    let pdf_bytes = typst_pdf::pdf(&document, &pdf_options)
                        .map_err(|e| RenderError::PdfError(format!("{:?}", e)))?;
                    Ok(RenderOutput::Pdf(pdf_bytes))
                }
                OutputFormat::Svg => {
                    let svgs: Vec<String> = document
                        .pages
                        .iter()
                        .map(|page| typst_svg::svg(page))
                        .collect();
                    Ok(RenderOutput::Svg(svgs))
                }
                OutputFormat::Png { ppi: _ } => {
                    // PNG rendering requires additional setup with resvg
                    // For now, render to SVG and note that PNG requires post-processing
                    Err(RenderError::PngError(
                        "PNG rendering requires the typst-render crate with resvg. \
                         Consider rendering to SVG and converting with an image library."
                            .to_string(),
                    ))
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

            // For now, we don't do true incremental compilation
            // The comemo crate provides memoization for Typst internals,
            // but we'd need more sophisticated caching at this level
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
}

#[cfg(feature = "typst-render")]
pub use typst_impl::DefaultTypstRenderer;

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
