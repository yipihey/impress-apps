//! Figure types for cross-app figure embedding
//!
//! Figures are exported from implore visualization sessions and can be
//! embedded into imprint documents or linked to imbib publications.

use serde::{Deserialize, Serialize};

/// A figure exported from a visualization session
///
/// Figures bridge implore (visualization) with imprint (writing) and
/// imbib (reference management) by capturing a reproducible view state
/// that can be re-rendered or embedded.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Figure {
    /// Unique figure identifier
    pub id: String,

    /// Figure title (appears in figure caption)
    pub title: Option<String>,

    /// Figure caption text
    pub caption: Option<String>,

    /// Reference to the implore session this figure was created from
    pub implore_session_id: String,

    /// Serialized view state (JSON) for reproducibility
    ///
    /// Contains camera position, color mapping, selection state, etc.
    /// Can be used to recreate the exact visualization.
    pub implore_view_state: String,

    /// Exported format versions of this figure
    pub formats: Vec<FigureExport>,

    /// ID of the dataset this figure visualizes
    pub dataset_id: String,

    /// Links to imbib publications that are sources for this data
    ///
    /// Used for automatic citation generation when the figure is
    /// embedded in an imprint document.
    pub dataset_publication_ids: Vec<String>,

    /// Creation timestamp (ISO 8601)
    pub created_at: String,

    /// Last modification timestamp (ISO 8601)
    pub modified_at: String,

    /// User-defined tags for organization
    pub tags: Vec<String>,

    /// Additional metadata
    pub metadata: std::collections::HashMap<String, String>,
}

impl Figure {
    /// Create a new figure
    pub fn new(
        implore_session_id: impl Into<String>,
        implore_view_state: impl Into<String>,
        dataset_id: impl Into<String>,
    ) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: None,
            caption: None,
            implore_session_id: implore_session_id.into(),
            implore_view_state: implore_view_state.into(),
            formats: Vec::new(),
            dataset_id: dataset_id.into(),
            dataset_publication_ids: Vec::new(),
            created_at: now.clone(),
            modified_at: now,
            tags: Vec::new(),
            metadata: std::collections::HashMap::new(),
        }
    }

    /// Set the figure title
    pub fn with_title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self.touch();
        self
    }

    /// Set the figure caption
    pub fn with_caption(mut self, caption: impl Into<String>) -> Self {
        self.caption = Some(caption.into());
        self.touch();
        self
    }

    /// Add a publication link (data source)
    pub fn add_publication_link(&mut self, publication_id: impl Into<String>) {
        self.dataset_publication_ids.push(publication_id.into());
        self.touch();
    }

    /// Add an exported format
    pub fn add_export(&mut self, export: FigureExport) {
        self.formats.push(export);
        self.touch();
    }

    /// Add a tag
    pub fn add_tag(&mut self, tag: impl Into<String>) {
        let tag_str = tag.into();
        if !self.tags.contains(&tag_str) {
            self.tags.push(tag_str);
            self.touch();
        }
    }

    /// Set metadata value
    pub fn set_metadata(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.metadata.insert(key.into(), value.into());
        self.touch();
    }

    /// Get the best available export for a given format
    pub fn get_export(&self, format: FigureFormat) -> Option<&FigureExport> {
        self.formats.iter().find(|e| e.format == format)
    }

    /// Get the highest resolution export
    pub fn best_export(&self) -> Option<&FigureExport> {
        self.formats
            .iter()
            .max_by_key(|e| e.width_px as u64 * e.height_px as u64)
    }

    /// Update modified timestamp
    fn touch(&mut self) {
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }

    /// Generate citation text for data sources
    pub fn generate_data_citation(&self) -> String {
        if self.dataset_publication_ids.is_empty() {
            return String::new();
        }

        // Return cite keys formatted for Typst
        self.dataset_publication_ids
            .iter()
            .map(|id| format!("@{}", id))
            .collect::<Vec<_>>()
            .join(", ")
    }
}

/// An exported version of a figure in a specific format
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct FigureExport {
    /// Export format
    pub format: FigureFormat,

    /// File path (if saved to disk)
    pub path: Option<String>,

    /// Embedded data (for small exports or inline embedding)
    pub embedded_data: Option<Vec<u8>>,

    /// Width in pixels
    pub width_px: u32,

    /// Height in pixels
    pub height_px: u32,

    /// DPI for raster formats (typically 300 for print)
    pub dpi: u32,

    /// Export timestamp (ISO 8601)
    pub exported_at: String,
}

impl FigureExport {
    /// Create a new export specification
    pub fn new(format: FigureFormat, width_px: u32, height_px: u32) -> Self {
        Self {
            format,
            path: None,
            embedded_data: None,
            width_px,
            height_px,
            dpi: 300,
            exported_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Set the DPI for raster export
    pub fn with_dpi(mut self, dpi: u32) -> Self {
        self.dpi = dpi;
        self
    }

    /// Set the output path
    pub fn with_path(mut self, path: impl Into<String>) -> Self {
        self.path = Some(path.into());
        self
    }

    /// Set embedded data (for small exports)
    pub fn with_data(mut self, data: Vec<u8>) -> Self {
        self.embedded_data = Some(data);
        self
    }

    /// Get physical width in inches
    pub fn width_inches(&self) -> f64 {
        self.width_px as f64 / self.dpi as f64
    }

    /// Get physical height in inches
    pub fn height_inches(&self) -> f64 {
        self.height_px as f64 / self.dpi as f64
    }

    /// Check if this export has embedded data
    pub fn has_embedded_data(&self) -> bool {
        self.embedded_data.is_some()
    }
}

/// Figure export formats supported by implore
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FigureFormat {
    /// PNG raster image (best for web)
    Png,

    /// PDF vector format (best for print/LaTeX)
    Pdf,

    /// SVG vector format (best for web with interactivity)
    Svg,

    /// EPS (Encapsulated PostScript) for legacy LaTeX
    Eps,

    /// Native Typst figure for direct imprint embedding
    Typst,
}

impl FigureFormat {
    /// Get the file extension for this format
    pub fn extension(&self) -> &'static str {
        match self {
            FigureFormat::Png => "png",
            FigureFormat::Pdf => "pdf",
            FigureFormat::Svg => "svg",
            FigureFormat::Eps => "eps",
            FigureFormat::Typst => "typ",
        }
    }

    /// Get the MIME type for this format
    pub fn mime_type(&self) -> &'static str {
        match self {
            FigureFormat::Png => "image/png",
            FigureFormat::Pdf => "application/pdf",
            FigureFormat::Svg => "image/svg+xml",
            FigureFormat::Eps => "application/postscript",
            FigureFormat::Typst => "text/plain",
        }
    }

    /// Check if this is a vector format (scales without quality loss)
    pub fn is_vector(&self) -> bool {
        matches!(
            self,
            FigureFormat::Pdf | FigureFormat::Svg | FigureFormat::Eps | FigureFormat::Typst
        )
    }

    /// Check if this is a raster format
    pub fn is_raster(&self) -> bool {
        !self.is_vector()
    }

    /// Get recommended DPI for this format
    pub fn recommended_dpi(&self) -> u32 {
        match self {
            FigureFormat::Png => 300, // Print quality
            _ => 72,                  // Vector formats don't need high DPI
        }
    }
}

impl std::fmt::Display for FigureFormat {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FigureFormat::Png => write!(f, "PNG"),
            FigureFormat::Pdf => write!(f, "PDF"),
            FigureFormat::Svg => write!(f, "SVG"),
            FigureFormat::Eps => write!(f, "EPS"),
            FigureFormat::Typst => write!(f, "Typst"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_figure_creation() {
        let figure = Figure::new("session-1", "{}", "dataset-1")
            .with_title("Figure 1")
            .with_caption("A sample scatter plot");

        assert_eq!(figure.title, Some("Figure 1".to_string()));
        assert_eq!(figure.caption, Some("A sample scatter plot".to_string()));
        assert_eq!(figure.dataset_id, "dataset-1");
    }

    #[test]
    fn test_figure_publication_links() {
        let mut figure = Figure::new("session-1", "{}", "dataset-1");
        figure.add_publication_link("Smith2024");
        figure.add_publication_link("Jones2023");

        assert_eq!(figure.dataset_publication_ids.len(), 2);
        assert_eq!(figure.generate_data_citation(), "@Smith2024, @Jones2023");
    }

    #[test]
    fn test_figure_exports() {
        let mut figure = Figure::new("session-1", "{}", "dataset-1");

        let png_export = FigureExport::new(FigureFormat::Png, 1200, 800).with_dpi(300);
        let pdf_export = FigureExport::new(FigureFormat::Pdf, 1200, 800);

        figure.add_export(png_export);
        figure.add_export(pdf_export);

        assert_eq!(figure.formats.len(), 2);
        assert!(figure.get_export(FigureFormat::Png).is_some());
        assert!(figure.get_export(FigureFormat::Svg).is_none());
    }

    #[test]
    fn test_figure_format_properties() {
        assert_eq!(FigureFormat::Png.extension(), "png");
        assert!(!FigureFormat::Png.is_vector());
        assert!(FigureFormat::Png.is_raster());

        assert_eq!(FigureFormat::Pdf.extension(), "pdf");
        assert!(FigureFormat::Pdf.is_vector());
        assert!(!FigureFormat::Pdf.is_raster());
    }

    #[test]
    fn test_export_dimensions() {
        let export = FigureExport::new(FigureFormat::Png, 600, 400).with_dpi(300);

        assert_eq!(export.width_inches(), 2.0);
        assert_eq!(export.height_inches(), 400.0 / 300.0);
    }

    #[test]
    fn test_figure_tags() {
        let mut figure = Figure::new("session-1", "{}", "dataset-1");
        figure.add_tag("scatter");
        figure.add_tag("cosmology");
        figure.add_tag("scatter"); // Duplicate, should not be added

        assert_eq!(figure.tags.len(), 2);
    }
}
