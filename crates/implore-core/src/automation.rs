//! URL scheme handling for implore:// commands
//!
//! This module provides parsing and building for implore:// URLs:
//!
//! - `implore://open?path=/data/sim.hdf5&dataset=/particles`
//! - `implore://new?template=scatter_3d`
//! - `implore://mode?type=art_shader&shader=nebula`
//! - `implore://export?format=pdf&dpi=300&width=1200`
//! - `implore://share?session=xyz&email=user@example.com`
//! - `implore://insert-figure?imprint_document=abc&session=xyz`
//! - `implore://link-publication?dataset=ds1&publication=pub123`

use crate::session::FigureFormat;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

/// Errors that can occur during URL parsing
#[derive(Debug, Error)]
pub enum AutomationError {
    #[error("Invalid URL: {0}")]
    InvalidUrl(String),

    #[error("Unknown command: {0}")]
    UnknownCommand(String),

    #[error("Missing required parameter: {0}")]
    MissingParameter(String),

    #[error("Invalid parameter value: {0}")]
    InvalidValue(String),
}

/// Result type for automation operations
pub type AutomationResult<T> = Result<T, AutomationError>;

/// Commands that can be invoked via implore:// URLs
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ImploreCommand {
    /// Open a dataset
    /// `implore://open?path=/data/sim.hdf5&dataset=/particles`
    Open(OpenDatasetCommand),

    /// Create new visualization
    /// `implore://new?template=scatter_3d`
    New(NewVisualizationCommand),

    /// Set render mode
    /// `implore://mode?type=art_shader&shader=nebula`
    Mode(SetModeCommand),

    /// Export figure
    /// `implore://export?format=pdf&dpi=300&width=1200`
    Export(ExportFigureCommand),

    /// Share session
    /// `implore://share?session=xyz&email=user@example.com`
    Share(ShareSessionCommand),

    /// Insert figure into imprint document
    /// `implore://insert-figure?imprint_document=abc&session=xyz`
    InsertFigure(InsertFigureCommand),

    /// Link dataset to imbib publication
    /// `implore://link-publication?dataset=ds1&publication=pub123`
    LinkPublication(LinkPublicationCommand),

    /// Sync session with collaborators
    /// `implore://sync?session=xyz`
    Sync(SyncCommand),

    /// Generate data from a plugin
    /// `implore://generate?plugin=noise-perlin-2d&resolution=512&frequency=8`
    Generate(GenerateCommand),

    /// List available generators
    /// `implore://generators`
    ListGenerators,

    /// Sync a figure to an imprint document
    /// `implore://sync-figure?figure=fig123&document=doc456`
    SyncFigure(SyncFigureCommand),

    /// Unlink a figure from an imprint document
    /// `implore://unlink-figure?figure=fig123&document=doc456`
    UnlinkFigure(UnlinkFigureCommand),

    /// Open figure library
    /// `implore://library`
    OpenLibrary,

    /// Unknown command (for forward compatibility)
    Unknown(String),
}

/// Open a dataset command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OpenDatasetCommand {
    /// File path
    pub path: String,

    /// Dataset path within file (for HDF5)
    pub dataset_path: Option<String>,

    /// Extension number (for FITS)
    pub extension: Option<u32>,

    /// Session to open into (optional)
    pub session_id: Option<String>,
}

/// Create new visualization command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewVisualizationCommand {
    /// Template name (e.g., "scatter_3d", "histogram", "time_series")
    pub template: Option<String>,

    /// Dataset to visualize (optional)
    pub dataset_id: Option<String>,

    /// Session name
    pub name: Option<String>,
}

/// Set render mode command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SetModeCommand {
    /// Mode type: "science_2d", "box_3d", "art_shader"
    pub mode_type: String,

    /// Shader name (for art mode)
    pub shader: Option<String>,

    /// Additional parameters as JSON
    pub parameters: Option<String>,
}

/// Export figure command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExportFigureCommand {
    /// Export format
    pub format: FigureFormat,

    /// DPI for raster formats
    pub dpi: Option<u32>,

    /// Width in pixels
    pub width: Option<u32>,

    /// Height in pixels
    pub height: Option<u32>,

    /// Output path
    pub output_path: Option<String>,

    /// Session to export from
    pub session_id: Option<String>,
}

/// Share session command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ShareSessionCommand {
    /// Session ID
    pub session_id: String,

    /// Recipient email
    pub email: Option<String>,

    /// Permission level: "view", "comment", "edit"
    pub permission: Option<String>,

    /// Expiration in hours
    pub expires_in_hours: Option<u32>,
}

/// Insert figure into imprint document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InsertFigureCommand {
    /// Target imprint document ID
    pub imprint_document_id: String,

    /// Source session ID
    pub session_id: String,

    /// Figure ID (if inserting existing figure)
    pub figure_id: Option<String>,
}

/// Link dataset to imbib publication
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LinkPublicationCommand {
    /// Dataset ID
    pub dataset_id: String,

    /// imbib publication ID
    pub publication_id: String,
}

/// Sync session command
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncCommand {
    /// Session ID
    pub session_id: String,
}

/// Generate data from a plugin
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GenerateCommand {
    /// Generator plugin ID (e.g., "noise-perlin-2d")
    pub generator_id: String,

    /// Parameters as key-value pairs
    pub params: HashMap<String, String>,

    /// Whether to auto-open in a new visualization
    pub auto_open: bool,
}

/// Sync a figure to an imprint document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncFigureCommand {
    /// Figure ID
    pub figure_id: String,

    /// Target document ID
    pub document_id: String,
}

/// Unlink a figure from an imprint document
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UnlinkFigureCommand {
    /// Figure ID
    pub figure_id: String,

    /// Document ID to unlink from
    pub document_id: String,
}

impl ImploreCommand {
    /// Parse a command from a URL string
    pub fn parse(url_str: &str) -> AutomationResult<Self> {
        let url =
            url::Url::parse(url_str).map_err(|e| AutomationError::InvalidUrl(e.to_string()))?;

        if url.scheme() != "implore" {
            return Err(AutomationError::InvalidUrl(format!(
                "Expected implore:// scheme, got {}://",
                url.scheme()
            )));
        }

        let command = url.host_str().unwrap_or("");
        let params: HashMap<String, String> = url.query_pairs().into_owned().collect();

        match command {
            "open" => Self::parse_open(params),
            "new" => Self::parse_new(params),
            "mode" => Self::parse_mode(params),
            "export" => Self::parse_export(params),
            "share" => Self::parse_share(params),
            "insert-figure" => Self::parse_insert_figure(params),
            "link-publication" => Self::parse_link_publication(params),
            "sync" => Self::parse_sync(params),
            "generate" => Self::parse_generate(params),
            "generators" => Ok(ImploreCommand::ListGenerators),
            "sync-figure" => Self::parse_sync_figure(params),
            "unlink-figure" => Self::parse_unlink_figure(params),
            "library" => Ok(ImploreCommand::OpenLibrary),
            _ => Ok(ImploreCommand::Unknown(url_str.to_string())),
        }
    }

    fn parse_open(params: HashMap<String, String>) -> AutomationResult<Self> {
        let path = params
            .get("path")
            .ok_or_else(|| AutomationError::MissingParameter("path".to_string()))?
            .clone();

        Ok(ImploreCommand::Open(OpenDatasetCommand {
            path,
            dataset_path: params.get("dataset").cloned(),
            extension: params.get("extension").and_then(|s| s.parse().ok()),
            session_id: params.get("session").cloned(),
        }))
    }

    fn parse_new(params: HashMap<String, String>) -> AutomationResult<Self> {
        Ok(ImploreCommand::New(NewVisualizationCommand {
            template: params.get("template").cloned(),
            dataset_id: params.get("dataset_id").cloned(),
            name: params.get("name").cloned(),
        }))
    }

    fn parse_mode(params: HashMap<String, String>) -> AutomationResult<Self> {
        let mode_type = params
            .get("type")
            .ok_or_else(|| AutomationError::MissingParameter("type".to_string()))?
            .clone();

        Ok(ImploreCommand::Mode(SetModeCommand {
            mode_type,
            shader: params.get("shader").cloned(),
            parameters: params.get("parameters").cloned(),
        }))
    }

    fn parse_export(params: HashMap<String, String>) -> AutomationResult<Self> {
        let format_str = params
            .get("format")
            .ok_or_else(|| AutomationError::MissingParameter("format".to_string()))?;

        let format = match format_str.as_str() {
            "png" => FigureFormat::Png,
            "pdf" => FigureFormat::Pdf,
            "svg" => FigureFormat::Svg,
            "eps" => FigureFormat::Eps,
            "typst" | "typ" => FigureFormat::Typst,
            _ => {
                return Err(AutomationError::InvalidValue(format!(
                    "Unknown format: {}",
                    format_str
                )))
            }
        };

        Ok(ImploreCommand::Export(ExportFigureCommand {
            format,
            dpi: params.get("dpi").and_then(|s| s.parse().ok()),
            width: params.get("width").and_then(|s| s.parse().ok()),
            height: params.get("height").and_then(|s| s.parse().ok()),
            output_path: params.get("output").cloned(),
            session_id: params.get("session").cloned(),
        }))
    }

    fn parse_share(params: HashMap<String, String>) -> AutomationResult<Self> {
        let session_id = params
            .get("session")
            .ok_or_else(|| AutomationError::MissingParameter("session".to_string()))?
            .clone();

        Ok(ImploreCommand::Share(ShareSessionCommand {
            session_id,
            email: params.get("email").cloned(),
            permission: params.get("permission").cloned(),
            expires_in_hours: params.get("expires_in_hours").and_then(|s| s.parse().ok()),
        }))
    }

    fn parse_insert_figure(params: HashMap<String, String>) -> AutomationResult<Self> {
        let imprint_document_id = params
            .get("imprint_document")
            .ok_or_else(|| AutomationError::MissingParameter("imprint_document".to_string()))?
            .clone();

        let session_id = params
            .get("session")
            .ok_or_else(|| AutomationError::MissingParameter("session".to_string()))?
            .clone();

        Ok(ImploreCommand::InsertFigure(InsertFigureCommand {
            imprint_document_id,
            session_id,
            figure_id: params.get("figure_id").cloned(),
        }))
    }

    fn parse_link_publication(params: HashMap<String, String>) -> AutomationResult<Self> {
        let dataset_id = params
            .get("dataset")
            .ok_or_else(|| AutomationError::MissingParameter("dataset".to_string()))?
            .clone();

        let publication_id = params
            .get("publication")
            .ok_or_else(|| AutomationError::MissingParameter("publication".to_string()))?
            .clone();

        Ok(ImploreCommand::LinkPublication(LinkPublicationCommand {
            dataset_id,
            publication_id,
        }))
    }

    fn parse_sync(params: HashMap<String, String>) -> AutomationResult<Self> {
        let session_id = params
            .get("session")
            .ok_or_else(|| AutomationError::MissingParameter("session".to_string()))?
            .clone();

        Ok(ImploreCommand::Sync(SyncCommand { session_id }))
    }

    fn parse_generate(params: HashMap<String, String>) -> AutomationResult<Self> {
        let generator_id = params
            .get("plugin")
            .ok_or_else(|| AutomationError::MissingParameter("plugin".to_string()))?
            .clone();

        // Extract all other params as generator params
        let mut gen_params = params.clone();
        gen_params.remove("plugin");
        let auto_open = gen_params
            .remove("auto_open")
            .map(|s| s == "true")
            .unwrap_or(true);

        Ok(ImploreCommand::Generate(GenerateCommand {
            generator_id,
            params: gen_params,
            auto_open,
        }))
    }

    fn parse_sync_figure(params: HashMap<String, String>) -> AutomationResult<Self> {
        let figure_id = params
            .get("figure")
            .ok_or_else(|| AutomationError::MissingParameter("figure".to_string()))?
            .clone();

        let document_id = params
            .get("document")
            .ok_or_else(|| AutomationError::MissingParameter("document".to_string()))?
            .clone();

        Ok(ImploreCommand::SyncFigure(SyncFigureCommand {
            figure_id,
            document_id,
        }))
    }

    fn parse_unlink_figure(params: HashMap<String, String>) -> AutomationResult<Self> {
        let figure_id = params
            .get("figure")
            .ok_or_else(|| AutomationError::MissingParameter("figure".to_string()))?
            .clone();

        let document_id = params
            .get("document")
            .ok_or_else(|| AutomationError::MissingParameter("document".to_string()))?
            .clone();

        Ok(ImploreCommand::UnlinkFigure(UnlinkFigureCommand {
            figure_id,
            document_id,
        }))
    }
}

// URL builders for constructing URLs programmatically

/// Build an open URL
pub fn build_open_url(path: &str, dataset_path: Option<&str>, extension: Option<u32>) -> String {
    let mut url = format!("implore://open?path={}", urlencoding::encode(path));
    if let Some(dp) = dataset_path {
        url.push_str(&format!("&dataset={}", urlencoding::encode(dp)));
    }
    if let Some(ext) = extension {
        url.push_str(&format!("&extension={}", ext));
    }
    url
}

/// Build an export URL
pub fn build_export_url(format: FigureFormat, dpi: u32, width: u32, height: u32) -> String {
    format!(
        "implore://export?format={}&dpi={}&width={}&height={}",
        format.extension(),
        dpi,
        width,
        height
    )
}

/// Build a share URL
pub fn build_share_url(session_id: &str, email: Option<&str>, permission: Option<&str>) -> String {
    let mut url = format!(
        "implore://share?session={}",
        urlencoding::encode(session_id)
    );
    if let Some(e) = email {
        url.push_str(&format!("&email={}", urlencoding::encode(e)));
    }
    if let Some(p) = permission {
        url.push_str(&format!("&permission={}", p));
    }
    url
}

/// Build an insert-figure URL
pub fn build_insert_figure_url(
    imprint_document_id: &str,
    session_id: &str,
    figure_id: Option<&str>,
) -> String {
    let mut url = format!(
        "implore://insert-figure?imprint_document={}&session={}",
        urlencoding::encode(imprint_document_id),
        urlencoding::encode(session_id)
    );
    if let Some(fid) = figure_id {
        url.push_str(&format!("&figure_id={}", urlencoding::encode(fid)));
    }
    url
}

/// Build a link-publication URL
pub fn build_link_publication_url(dataset_id: &str, publication_id: &str) -> String {
    format!(
        "implore://link-publication?dataset={}&publication={}",
        urlencoding::encode(dataset_id),
        urlencoding::encode(publication_id)
    )
}

/// Build a generate URL
pub fn build_generate_url(generator_id: &str, params: &HashMap<String, String>) -> String {
    let mut url = format!(
        "implore://generate?plugin={}",
        urlencoding::encode(generator_id)
    );
    for (key, value) in params {
        url.push_str(&format!(
            "&{}={}",
            urlencoding::encode(key),
            urlencoding::encode(value)
        ));
    }
    url
}

/// Build a sync-figure URL
pub fn build_sync_figure_url(figure_id: &str, document_id: &str) -> String {
    format!(
        "implore://sync-figure?figure={}&document={}",
        urlencoding::encode(figure_id),
        urlencoding::encode(document_id)
    )
}

/// Build an unlink-figure URL
pub fn build_unlink_figure_url(figure_id: &str, document_id: &str) -> String {
    format!(
        "implore://unlink-figure?figure={}&document={}",
        urlencoding::encode(figure_id),
        urlencoding::encode(document_id)
    )
}

/// Build a list-generators URL
pub fn build_list_generators_url() -> String {
    "implore://generators".to_string()
}

/// Build an open-library URL
pub fn build_open_library_url() -> String {
    "implore://library".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_open_command() {
        let url = "implore://open?path=/data/sim.hdf5&dataset=/particles";
        let cmd = ImploreCommand::parse(url).unwrap();

        match cmd {
            ImploreCommand::Open(open) => {
                assert_eq!(open.path, "/data/sim.hdf5");
                assert_eq!(open.dataset_path, Some("/particles".to_string()));
            }
            _ => panic!("Expected Open command"),
        }
    }

    #[test]
    fn test_parse_export_command() {
        let url = "implore://export?format=pdf&dpi=300&width=1200&height=800";
        let cmd = ImploreCommand::parse(url).unwrap();

        match cmd {
            ImploreCommand::Export(export) => {
                assert_eq!(export.format, FigureFormat::Pdf);
                assert_eq!(export.dpi, Some(300));
                assert_eq!(export.width, Some(1200));
            }
            _ => panic!("Expected Export command"),
        }
    }

    #[test]
    fn test_parse_mode_command() {
        let url = "implore://mode?type=art_shader&shader=nebula";
        let cmd = ImploreCommand::parse(url).unwrap();

        match cmd {
            ImploreCommand::Mode(mode) => {
                assert_eq!(mode.mode_type, "art_shader");
                assert_eq!(mode.shader, Some("nebula".to_string()));
            }
            _ => panic!("Expected Mode command"),
        }
    }

    #[test]
    fn test_parse_share_command() {
        let url = "implore://share?session=xyz123&email=user@example.com&permission=edit";
        let cmd = ImploreCommand::parse(url).unwrap();

        match cmd {
            ImploreCommand::Share(share) => {
                assert_eq!(share.session_id, "xyz123");
                assert_eq!(share.email, Some("user@example.com".to_string()));
                assert_eq!(share.permission, Some("edit".to_string()));
            }
            _ => panic!("Expected Share command"),
        }
    }

    #[test]
    fn test_parse_insert_figure_command() {
        let url = "implore://insert-figure?imprint_document=doc123&session=sess456";
        let cmd = ImploreCommand::parse(url).unwrap();

        match cmd {
            ImploreCommand::InsertFigure(insert) => {
                assert_eq!(insert.imprint_document_id, "doc123");
                assert_eq!(insert.session_id, "sess456");
            }
            _ => panic!("Expected InsertFigure command"),
        }
    }

    #[test]
    fn test_build_open_url() {
        let url = build_open_url("/data/test.hdf5", Some("/group/dataset"), None);
        assert!(url.contains("implore://open"));
        assert!(url.contains("path="));
        assert!(url.contains("dataset="));
    }

    #[test]
    fn test_build_export_url() {
        let url = build_export_url(FigureFormat::Png, 300, 1920, 1080);
        assert!(url.contains("format=png"));
        assert!(url.contains("dpi=300"));
    }

    #[test]
    fn test_unknown_command() {
        let url = "implore://unknown-command?foo=bar";
        let cmd = ImploreCommand::parse(url).unwrap();
        assert!(matches!(cmd, ImploreCommand::Unknown(_)));
    }

    #[test]
    fn test_invalid_scheme() {
        let url = "http://open?path=/data";
        let result = ImploreCommand::parse(url);
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_required_param() {
        let url = "implore://open"; // Missing path
        let result = ImploreCommand::parse(url);
        assert!(matches!(result, Err(AutomationError::MissingParameter(_))));
    }
}
