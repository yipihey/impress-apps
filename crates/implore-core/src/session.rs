//! Visualization session management
//!
//! A session encapsulates:
//! - The active dataset
//! - Current view state
//! - Collaboration state (participants, permissions)
//! - Exported figures

use crate::dataset::Dataset;
use crate::view::ViewState;
use impress_collab::{Permissions, PresenceInfo};
use serde::{Deserialize, Serialize};

/// A collaborative visualization session
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct VisualizationSession {
    /// Unique session identifier
    pub id: String,

    /// Session name
    pub name: String,

    /// Active dataset
    pub dataset_id: Option<String>,

    /// Current view state (camera, colormap, etc.)
    pub view_state: ViewState,

    /// Collaboration participants
    pub participants: Vec<SessionParticipant>,

    /// Owner's permissions (the base permissions)
    pub permissions: Permissions,

    /// Figures exported from this session
    pub figures: Vec<SessionFigure>,

    /// Session creation timestamp
    pub created_at: String,

    /// Session modification timestamp
    pub modified_at: String,

    /// Session notes or description
    pub notes: Option<String>,
}

impl VisualizationSession {
    /// Create a new empty session
    pub fn new(name: impl Into<String>) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            dataset_id: None,
            view_state: ViewState::default(),
            participants: Vec::new(),
            permissions: Permissions::OWNER,
            figures: Vec::new(),
            created_at: now.clone(),
            modified_at: now,
            notes: None,
        }
    }

    /// Create a session with a dataset
    pub fn with_dataset(name: impl Into<String>, dataset: &Dataset) -> Self {
        let mut session = Self::new(name);
        session.dataset_id = Some(dataset.id.clone());
        session
    }

    /// Add a participant to the session
    pub fn add_participant(&mut self, participant: SessionParticipant) {
        self.participants.push(participant);
        self.touch();
    }

    /// Remove a participant by user ID
    pub fn remove_participant(&mut self, user_id: &str) -> Option<SessionParticipant> {
        if let Some(pos) = self.participants.iter().position(|p| p.user_id == user_id) {
            self.touch();
            Some(self.participants.remove(pos))
        } else {
            None
        }
    }

    /// Get active participants (not offline)
    pub fn active_participants(&self) -> Vec<&SessionParticipant> {
        self.participants
            .iter()
            .filter(|p| !matches!(p.presence.status, impress_collab::PresenceStatus::Offline))
            .collect()
    }

    /// Add a figure to the session
    pub fn add_figure(&mut self, figure: SessionFigure) {
        self.figures.push(figure);
        self.touch();
    }

    /// Get the current view state for serialization
    pub fn view_state_json(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string(&self.view_state)
    }

    /// Restore view state from JSON
    pub fn restore_view_state(&mut self, json: &str) -> Result<(), serde_json::Error> {
        self.view_state = serde_json::from_str(json)?;
        self.touch();
        Ok(())
    }

    /// Update the modification timestamp
    fn touch(&mut self) {
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }
}

impl Default for VisualizationSession {
    fn default() -> Self {
        Self::new("Untitled Session")
    }
}

/// A participant in a visualization session
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SessionParticipant {
    /// User identifier
    pub user_id: String,

    /// Display name
    pub display_name: String,

    /// Presence information
    pub presence: PresenceInfo,

    /// Permissions for this participant
    pub permissions: Permissions,

    /// When this participant joined
    pub joined_at: String,
}

impl SessionParticipant {
    /// Create a new participant
    pub fn new(user_id: impl Into<String>, display_name: impl Into<String>) -> Self {
        let user_id_str = user_id.into();
        let display_name_str = display_name.into();
        Self {
            presence: PresenceInfo::new(
                uuid::Uuid::new_v4().to_string(),
                user_id_str.clone(),
                display_name_str.clone(),
                String::new(), // resource_id set when joining session
            ),
            user_id: user_id_str,
            display_name: display_name_str,
            permissions: Permissions::VIEW,
            joined_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Create a participant with edit permissions
    pub fn with_edit_permissions(mut self) -> Self {
        self.permissions = Permissions::EDITOR;
        self
    }
}

/// A figure exported from a session
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct SessionFigure {
    /// Unique figure identifier
    pub id: String,

    /// Figure title
    pub title: Option<String>,

    /// Figure caption
    pub caption: Option<String>,

    /// View state snapshot (JSON)
    pub view_state_snapshot: String,

    /// Dataset ID this figure was created from
    pub dataset_id: String,

    /// Exported formats
    pub exports: Vec<FigureExport>,

    /// Creation timestamp
    pub created_at: String,
}

impl SessionFigure {
    /// Create a new figure from the current session state
    pub fn from_session(session: &VisualizationSession) -> Option<Self> {
        let dataset_id = session.dataset_id.as_ref()?;
        let view_state_snapshot = session.view_state_json().ok()?;

        Some(Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: None,
            caption: None,
            view_state_snapshot,
            dataset_id: dataset_id.clone(),
            exports: Vec::new(),
            created_at: chrono::Utc::now().to_rfc3339(),
        })
    }

    /// Set the figure title
    pub fn with_title(mut self, title: impl Into<String>) -> Self {
        self.title = Some(title.into());
        self
    }

    /// Set the figure caption
    pub fn with_caption(mut self, caption: impl Into<String>) -> Self {
        self.caption = Some(caption.into());
        self
    }

    /// Add an export
    pub fn add_export(&mut self, export: FigureExport) {
        self.exports.push(export);
    }
}

/// An exported version of a figure
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct FigureExport {
    /// Export format
    pub format: FigureFormat,

    /// File path (if saved to disk)
    pub path: Option<String>,

    /// Embedded data (for small exports)
    pub embedded_data: Option<Vec<u8>>,

    /// Width in pixels
    pub width_px: u32,

    /// Height in pixels
    pub height_px: u32,

    /// DPI for raster formats
    pub dpi: u32,

    /// Export timestamp
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

    /// Set the DPI
    pub fn with_dpi(mut self, dpi: u32) -> Self {
        self.dpi = dpi;
        self
    }

    /// Set the output path
    pub fn with_path(mut self, path: impl Into<String>) -> Self {
        self.path = Some(path.into());
        self
    }
}

/// Figure export formats
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum FigureFormat {
    /// PNG raster image
    Png,

    /// PDF vector format
    Pdf,

    /// SVG vector format
    Svg,

    /// EPS (Encapsulated PostScript)
    Eps,

    /// Native Typst figure for imprint embedding
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

    /// Get the MIME type
    pub fn mime_type(&self) -> &'static str {
        match self {
            FigureFormat::Png => "image/png",
            FigureFormat::Pdf => "application/pdf",
            FigureFormat::Svg => "image/svg+xml",
            FigureFormat::Eps => "application/postscript",
            FigureFormat::Typst => "text/plain",
        }
    }

    /// Check if this is a vector format
    pub fn is_vector(&self) -> bool {
        matches!(
            self,
            FigureFormat::Pdf | FigureFormat::Svg | FigureFormat::Eps | FigureFormat::Typst
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_session_creation() {
        let session = VisualizationSession::new("Test Session");
        assert_eq!(session.name, "Test Session");
        assert!(session.dataset_id.is_none());
        assert!(session.participants.is_empty());
    }

    #[test]
    fn test_participant_management() {
        let mut session = VisualizationSession::new("Test");
        let participant = SessionParticipant::new("user1", "Alice");

        session.add_participant(participant);
        assert_eq!(session.participants.len(), 1);

        let removed = session.remove_participant("user1");
        assert!(removed.is_some());
        assert!(session.participants.is_empty());
    }

    #[test]
    fn test_figure_creation() {
        let mut session = VisualizationSession::new("Test");
        session.dataset_id = Some("dataset1".to_string());

        let figure = SessionFigure::from_session(&session)
            .unwrap()
            .with_title("Figure 1")
            .with_caption("This is a test figure");

        assert_eq!(figure.title, Some("Figure 1".to_string()));
        assert_eq!(figure.dataset_id, "dataset1");
    }

    #[test]
    fn test_figure_format() {
        assert_eq!(FigureFormat::Png.extension(), "png");
        assert!(FigureFormat::Pdf.is_vector());
        assert!(!FigureFormat::Png.is_vector());
    }
}
