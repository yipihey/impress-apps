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
pub mod note_import;
pub mod render;
pub mod selection;
pub mod sourcemap;
pub mod transaction;

pub use automation::*;
pub use bibliography::*;
pub use citation_lookup::*;
pub use citations::*;
pub use collaboration::*;
pub use document::*;
pub use latex::*;
pub use note_import::*;
pub use render::*;
pub use selection::*;
pub use sourcemap::*;
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
                CompileResult {
                    pdf_data: Some(pdf_bytes.to_vec()),
                    error: None,
                    warnings: Vec::new(),
                    page_count: 1, // TODO: Extract actual page count
                }
            } else {
                CompileResult {
                    pdf_data: None,
                    error: Some("Unexpected output format".to_string()),
                    warnings: Vec::new(),
                    page_count: 0,
                }
            }
        }
        Err(e) => CompileResult {
            pdf_data: None,
            error: Some(e.to_string()),
            warnings: Vec::new(),
            page_count: 0,
        },
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
