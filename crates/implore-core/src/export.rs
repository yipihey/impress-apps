//! Figure export functionality
//!
//! Supports exporting visualizations to various formats:
//! - PNG: Raster image for web/presentations
//! - PDF: Vector format for publication
//! - SVG: Scalable vector graphics
//! - CSV: Export selected data points

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::view::ViewState;

/// Export format for figures
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ExportFormat {
    /// PNG raster image
    Png,
    /// PDF vector format
    Pdf,
    /// SVG scalable vector graphics
    Svg,
    /// EPS (Encapsulated PostScript) for LaTeX
    Eps,
    /// Typst figure code for imprint embedding
    Typst,
}

impl ExportFormat {
    /// Get file extension for this format
    pub fn extension(&self) -> &'static str {
        match self {
            ExportFormat::Png => "png",
            ExportFormat::Pdf => "pdf",
            ExportFormat::Svg => "svg",
            ExportFormat::Eps => "eps",
            ExportFormat::Typst => "typ",
        }
    }

    /// Get MIME type for this format
    pub fn mime_type(&self) -> &'static str {
        match self {
            ExportFormat::Png => "image/png",
            ExportFormat::Pdf => "application/pdf",
            ExportFormat::Svg => "image/svg+xml",
            ExportFormat::Eps => "application/postscript",
            ExportFormat::Typst => "text/plain",
        }
    }

    /// Check if this format is raster (vs vector)
    pub fn is_raster(&self) -> bool {
        matches!(self, ExportFormat::Png)
    }

    /// Check if this format is vector
    pub fn is_vector(&self) -> bool {
        !self.is_raster()
    }
}

/// Export configuration
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExportConfig {
    /// Output format
    pub format: ExportFormat,

    /// Output path (None = return bytes)
    pub output_path: Option<PathBuf>,

    /// Width in pixels (for raster) or points (for vector)
    pub width: u32,

    /// Height in pixels (for raster) or points (for vector)
    pub height: u32,

    /// DPI for raster exports
    pub dpi: u32,

    /// Scale factor for retina displays
    pub scale: f32,

    /// Whether to include axes and labels
    pub include_axes: bool,

    /// Whether to include colorbar
    pub include_colorbar: bool,

    /// Whether to include title
    pub include_title: bool,

    /// Custom title (overrides auto-generated)
    pub title: Option<String>,

    /// Background: transparent (true) or use view background color (false)
    pub transparent_background: bool,

    /// Anti-aliasing samples (for raster)
    pub anti_aliasing: AntiAliasingMode,

    /// Compression quality for PNG (0-100)
    pub compression_quality: u8,
}

impl Default for ExportConfig {
    fn default() -> Self {
        Self {
            format: ExportFormat::Png,
            output_path: None,
            width: 1200,
            height: 900,
            dpi: 150,
            scale: 1.0,
            include_axes: true,
            include_colorbar: true,
            include_title: false,
            title: None,
            transparent_background: false,
            anti_aliasing: AntiAliasingMode::default(),
            compression_quality: 90,
        }
    }
}

impl ExportConfig {
    /// Create config for PNG export
    pub fn png(width: u32, height: u32, dpi: u32) -> Self {
        Self {
            format: ExportFormat::Png,
            width,
            height,
            dpi,
            ..Default::default()
        }
    }

    /// Create config for PDF export (publication quality)
    pub fn pdf_publication() -> Self {
        Self {
            format: ExportFormat::Pdf,
            width: 504,  // 7 inches at 72 dpi
            height: 378, // 5.25 inches at 72 dpi
            dpi: 300,
            scale: 1.0,
            include_axes: true,
            include_colorbar: true,
            ..Default::default()
        }
    }

    /// Create config for SVG export
    pub fn svg(width: u32, height: u32) -> Self {
        Self {
            format: ExportFormat::Svg,
            width,
            height,
            ..Default::default()
        }
    }

    /// Create config for Typst embedding
    pub fn typst() -> Self {
        Self {
            format: ExportFormat::Typst,
            width: 400,
            height: 300,
            ..Default::default()
        }
    }

    /// Set output path
    pub fn with_path(mut self, path: impl Into<PathBuf>) -> Self {
        self.output_path = Some(path.into());
        self
    }

    /// Set title
    pub fn with_title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self.include_title = true;
        self
    }

    /// Enable transparent background
    pub fn with_transparency(mut self) -> Self {
        self.transparent_background = true;
        self
    }

    /// Get effective width considering scale
    pub fn effective_width(&self) -> u32 {
        (self.width as f32 * self.scale) as u32
    }

    /// Get effective height considering scale
    pub fn effective_height(&self) -> u32 {
        (self.height as f32 * self.scale) as u32
    }

    /// Get suggested filename based on format
    pub fn suggested_filename(&self, base: &str) -> String {
        format!("{}.{}", base, self.format.extension())
    }
}

/// Anti-aliasing modes
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum AntiAliasingMode {
    /// No anti-aliasing
    None,
    /// 2x MSAA
    Msaa2x,
    /// 4x MSAA (default, good balance)
    #[default]
    Msaa4x,
    /// 8x MSAA (high quality)
    Msaa8x,
}

impl AntiAliasingMode {
    /// Get sample count
    pub fn sample_count(&self) -> u32 {
        match self {
            AntiAliasingMode::None => 1,
            AntiAliasingMode::Msaa2x => 2,
            AntiAliasingMode::Msaa4x => 4,
            AntiAliasingMode::Msaa8x => 8,
        }
    }
}

/// Export result
#[derive(Clone, Debug)]
pub struct ExportResult {
    /// Exported data (if output_path was None)
    pub data: Option<Vec<u8>>,

    /// Output path (if output_path was Some)
    pub path: Option<PathBuf>,

    /// Format exported
    pub format: ExportFormat,

    /// Actual dimensions exported
    pub dimensions: (u32, u32),

    /// Export metadata
    pub metadata: ExportMetadata,
}

/// Metadata about the export
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ExportMetadata {
    /// Creation timestamp (ISO 8601)
    pub created_at: String,

    /// Source session ID
    pub session_id: Option<String>,

    /// Dataset name
    pub dataset_name: Option<String>,

    /// Number of points rendered
    pub point_count: usize,

    /// View state at export time
    pub view_state: Option<ViewState>,

    /// Software version
    pub software_version: String,
}

impl Default for ExportMetadata {
    fn default() -> Self {
        Self {
            created_at: chrono::Utc::now().to_rfc3339(),
            session_id: None,
            dataset_name: None,
            point_count: 0,
            view_state: None,
            software_version: env!("CARGO_PKG_VERSION").to_string(),
        }
    }
}

/// Export data to CSV format
#[derive(Clone, Debug, Default)]
pub struct CsvExporter {
    /// Whether to include header row
    pub include_header: bool,

    /// Column delimiter
    pub delimiter: char,

    /// Fields to export (empty = all)
    pub fields: Vec<String>,

    /// Only export selected points
    pub selected_only: bool,
}

impl CsvExporter {
    pub fn new() -> Self {
        Self {
            include_header: true,
            delimiter: ',',
            fields: Vec::new(),
            selected_only: false,
        }
    }

    /// Set fields to export
    pub fn with_fields(mut self, fields: Vec<String>) -> Self {
        self.fields = fields;
        self
    }

    /// Only export selected points
    pub fn selected_only(mut self) -> Self {
        self.selected_only = true;
        self
    }

    /// Generate CSV content
    pub fn export(&self, data: &DataForExport) -> String {
        let mut output = String::new();

        // Header
        if self.include_header {
            let fields = if self.fields.is_empty() {
                &data.field_names
            } else {
                &self.fields
            };

            output.push_str(&fields.join(&self.delimiter.to_string()));
            output.push('\n');
        }

        // Data rows
        for row in &data.rows {
            let values: Vec<String> = row.iter().map(|v| format!("{}", v)).collect();
            output.push_str(&values.join(&self.delimiter.to_string()));
            output.push('\n');
        }

        output
    }
}

/// Data prepared for export
#[derive(Clone, Debug)]
pub struct DataForExport {
    /// Field names
    pub field_names: Vec<String>,

    /// Data rows
    pub rows: Vec<Vec<f64>>,

    /// Selection mask (true = selected)
    pub selection: Option<Vec<bool>>,
}

/// Generate Typst figure code
pub fn generate_typst_figure(
    session_id: &str,
    view_state: &ViewState,
    caption: Option<&str>,
) -> String {
    let mode_name = view_state.mode.name();
    let fields = match &view_state.mode {
        crate::view::RenderMode::Science2D(cfg) => format!("{} vs {}", cfg.x_field, cfg.y_field),
        crate::view::RenderMode::Box3D(cfg) => {
            format!("{}, {}, {}", cfg.x_field, cfg.y_field, cfg.z_field)
        }
        crate::view::RenderMode::ArtShader(cfg) => cfg.shader_name.clone(),
    };

    let caption_text = caption.unwrap_or("Figure generated by implore");

    format!(
        r#"#figure(
  image("figures/{session_id}.png"),
  caption: [{caption_text}],
) <fig:{session_id}>

// Generated by implore
// Mode: {mode_name}
// Fields: {fields}
// Colormap: {colormap}
"#,
        session_id = session_id,
        caption_text = caption_text,
        mode_name = mode_name,
        fields = fields,
        colormap = view_state.color_mapping.colormap,
    )
}

/// Preset export configurations
pub mod presets {
    use super::*;

    /// Preset for journal figures (MNRAS, ApJ, etc.)
    pub fn journal_figure() -> ExportConfig {
        ExportConfig {
            format: ExportFormat::Pdf,
            width: 252, // 3.5 inches (single column)
            height: 252,
            dpi: 300,
            include_axes: true,
            include_colorbar: true,
            include_title: false,
            ..Default::default()
        }
    }

    /// Preset for full-page journal figures
    pub fn journal_figure_wide() -> ExportConfig {
        ExportConfig {
            format: ExportFormat::Pdf,
            width: 504, // 7 inches (double column)
            height: 378,
            dpi: 300,
            include_axes: true,
            include_colorbar: true,
            include_title: false,
            ..Default::default()
        }
    }

    /// Preset for presentation slides
    pub fn presentation() -> ExportConfig {
        ExportConfig {
            format: ExportFormat::Png,
            width: 1920,
            height: 1080,
            dpi: 150,
            include_axes: true,
            include_colorbar: true,
            include_title: true,
            transparent_background: false,
            ..Default::default()
        }
    }

    /// Preset for web display
    pub fn web() -> ExportConfig {
        ExportConfig {
            format: ExportFormat::Png,
            width: 800,
            height: 600,
            dpi: 72,
            scale: 2.0, // Retina
            compression_quality: 85,
            ..Default::default()
        }
    }

    /// Preset for social media
    pub fn social_media() -> ExportConfig {
        ExportConfig {
            format: ExportFormat::Png,
            width: 1200,
            height: 1200,
            dpi: 72,
            include_axes: false,
            include_colorbar: false,
            include_title: true,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_export_format_extension() {
        assert_eq!(ExportFormat::Png.extension(), "png");
        assert_eq!(ExportFormat::Pdf.extension(), "pdf");
        assert_eq!(ExportFormat::Svg.extension(), "svg");
        assert_eq!(ExportFormat::Typst.extension(), "typ");
    }

    #[test]
    fn test_export_format_is_vector() {
        assert!(!ExportFormat::Png.is_vector());
        assert!(ExportFormat::Pdf.is_vector());
        assert!(ExportFormat::Svg.is_vector());
    }

    #[test]
    fn test_export_config_defaults() {
        let config = ExportConfig::default();
        assert_eq!(config.format, ExportFormat::Png);
        assert_eq!(config.width, 1200);
        assert_eq!(config.height, 900);
        assert_eq!(config.dpi, 150);
    }

    #[test]
    fn test_export_config_png() {
        let config = ExportConfig::png(1920, 1080, 300);
        assert_eq!(config.format, ExportFormat::Png);
        assert_eq!(config.width, 1920);
        assert_eq!(config.height, 1080);
        assert_eq!(config.dpi, 300);
    }

    #[test]
    fn test_export_config_effective_dimensions() {
        let mut config = ExportConfig::default();
        config.width = 1000;
        config.height = 800;
        config.scale = 2.0;

        assert_eq!(config.effective_width(), 2000);
        assert_eq!(config.effective_height(), 1600);
    }

    #[test]
    fn test_anti_aliasing_sample_count() {
        assert_eq!(AntiAliasingMode::None.sample_count(), 1);
        assert_eq!(AntiAliasingMode::Msaa4x.sample_count(), 4);
        assert_eq!(AntiAliasingMode::Msaa8x.sample_count(), 8);
    }

    #[test]
    fn test_csv_exporter() {
        let exporter = CsvExporter::new();
        let data = DataForExport {
            field_names: vec!["x".to_string(), "y".to_string(), "z".to_string()],
            rows: vec![vec![1.0, 2.0, 3.0], vec![4.0, 5.0, 6.0]],
            selection: None,
        };

        let csv = exporter.export(&data);
        assert!(csv.contains("x,y,z"));
        assert!(csv.contains("1,2,3"));
        assert!(csv.contains("4,5,6"));
    }

    #[test]
    fn test_generate_typst_figure() {
        let view_state = ViewState::default();
        let typst = generate_typst_figure("test123", &view_state, Some("Test figure"));

        assert!(typst.contains("test123"));
        assert!(typst.contains("Test figure"));
        assert!(typst.contains("#figure"));
    }

    #[test]
    fn test_presets() {
        let journal = presets::journal_figure();
        assert_eq!(journal.format, ExportFormat::Pdf);
        assert_eq!(journal.width, 252);

        let presentation = presets::presentation();
        assert_eq!(presentation.format, ExportFormat::Png);
        assert_eq!(presentation.width, 1920);
    }
}
