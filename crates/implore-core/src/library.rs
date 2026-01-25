//! Figure library for organizing visualizations.
//!
//! This module provides types for organizing figures created in implore
//! and linking them to imprint documents for automatic updating.

use serde::{Deserialize, Serialize};

use crate::dataset::DatasetSource;

/// A library of figures organized by folders
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FigureLibrary {
    /// Unique identifier for this library
    pub id: String,

    /// Human-readable name
    pub name: String,

    /// All figures in the library
    pub figures: Vec<LibraryFigure>,

    /// Folder organization
    pub folders: Vec<FigureFolder>,

    /// When this library was created
    pub created_at: String,

    /// When this library was last modified
    pub modified_at: String,
}

/// A figure saved in the library
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LibraryFigure {
    /// Unique identifier for this figure
    pub id: String,

    /// User-given title
    pub title: String,

    /// Optional thumbnail (PNG data)
    pub thumbnail: Option<Vec<u8>>,

    /// Reference to the source session
    pub session_id: String,

    /// JSON-serialized view state for reproducibility
    pub view_state_snapshot: String,

    /// How the data was obtained
    pub dataset_source: DatasetSource,

    /// Links to imprint documents using this figure
    pub imprint_links: Vec<ImprintLink>,

    /// User tags for organization
    pub tags: Vec<String>,

    /// Optional folder ID (None = unfiled)
    pub folder_id: Option<String>,

    /// When this figure was created
    pub created_at: String,

    /// When this figure was last modified
    pub modified_at: String,
}

/// Link to an imprint document
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ImprintLink {
    /// ID of the imprint document
    pub document_id: String,

    /// Title of the document (for display)
    pub document_title: String,

    /// Label used in the document (e.g., "fig:noise-comparison")
    pub figure_label: String,

    /// Whether to auto-update when figure changes
    pub auto_update: bool,

    /// When this figure was last synced to the document
    pub last_synced: Option<String>,
}

/// Folder for organizing figures
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FigureFolder {
    /// Unique identifier
    pub id: String,

    /// Folder name
    pub name: String,

    /// IDs of figures in this folder
    pub figure_ids: Vec<String>,

    /// Whether the folder is collapsed in UI
    pub collapsed: bool,

    /// Sort order (lower = earlier)
    pub sort_order: i32,
}

impl FigureLibrary {
    /// Create a new empty library
    pub fn new(name: impl Into<String>) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            figures: Vec::new(),
            folders: Vec::new(),
            created_at: now.clone(),
            modified_at: now,
        }
    }

    /// Add a figure to the library
    pub fn add_figure(&mut self, figure: LibraryFigure) {
        self.figures.push(figure);
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }

    /// Get a figure by ID
    pub fn get_figure(&self, id: &str) -> Option<&LibraryFigure> {
        self.figures.iter().find(|f| f.id == id)
    }

    /// Get a mutable reference to a figure by ID
    pub fn get_figure_mut(&mut self, id: &str) -> Option<&mut LibraryFigure> {
        self.figures.iter_mut().find(|f| f.id == id)
    }

    /// Remove a figure by ID
    pub fn remove_figure(&mut self, id: &str) -> Option<LibraryFigure> {
        if let Some(pos) = self.figures.iter().position(|f| f.id == id) {
            self.modified_at = chrono::Utc::now().to_rfc3339();
            Some(self.figures.remove(pos))
        } else {
            None
        }
    }

    /// Get all unfiled figures
    pub fn unfiled_figures(&self) -> Vec<&LibraryFigure> {
        self.figures.iter().filter(|f| f.folder_id.is_none()).collect()
    }

    /// Get figures in a specific folder
    pub fn figures_in_folder(&self, folder_id: &str) -> Vec<&LibraryFigure> {
        self.figures
            .iter()
            .filter(|f| f.folder_id.as_deref() == Some(folder_id))
            .collect()
    }

    /// Create a new folder
    pub fn create_folder(&mut self, name: impl Into<String>) -> &FigureFolder {
        let folder = FigureFolder {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.into(),
            figure_ids: Vec::new(),
            collapsed: false,
            sort_order: self.folders.len() as i32,
        };
        self.folders.push(folder);
        self.modified_at = chrono::Utc::now().to_rfc3339();
        self.folders.last().unwrap()
    }

    /// Move a figure to a folder
    pub fn move_to_folder(&mut self, figure_id: &str, folder_id: Option<&str>) {
        if let Some(figure) = self.get_figure_mut(figure_id) {
            figure.folder_id = folder_id.map(String::from);
            self.modified_at = chrono::Utc::now().to_rfc3339();
        }
    }

    /// Get all figures linked to a specific imprint document
    pub fn figures_in_document(&self, document_id: &str) -> Vec<&LibraryFigure> {
        self.figures
            .iter()
            .filter(|f| f.imprint_links.iter().any(|l| l.document_id == document_id))
            .collect()
    }

    /// Get all unique document IDs that have linked figures
    pub fn linked_documents(&self) -> Vec<String> {
        let mut doc_ids: Vec<String> = self
            .figures
            .iter()
            .flat_map(|f| f.imprint_links.iter().map(|l| l.document_id.clone()))
            .collect();
        doc_ids.sort();
        doc_ids.dedup();
        doc_ids
    }

    /// Search figures by title or tags
    pub fn search(&self, query: &str) -> Vec<&LibraryFigure> {
        let query_lower = query.to_lowercase();
        self.figures
            .iter()
            .filter(|f| {
                f.title.to_lowercase().contains(&query_lower)
                    || f.tags.iter().any(|t| t.to_lowercase().contains(&query_lower))
            })
            .collect()
    }
}

impl LibraryFigure {
    /// Create a new library figure
    pub fn new(
        title: impl Into<String>,
        session_id: impl Into<String>,
        view_state_snapshot: impl Into<String>,
        dataset_source: DatasetSource,
    ) -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            title: title.into(),
            thumbnail: None,
            session_id: session_id.into(),
            view_state_snapshot: view_state_snapshot.into(),
            dataset_source,
            imprint_links: Vec::new(),
            tags: Vec::new(),
            folder_id: None,
            created_at: now.clone(),
            modified_at: now,
        }
    }

    /// Set the thumbnail
    pub fn with_thumbnail(mut self, thumbnail: Vec<u8>) -> Self {
        self.thumbnail = Some(thumbnail);
        self
    }

    /// Add a tag
    pub fn add_tag(&mut self, tag: impl Into<String>) {
        let tag = tag.into();
        if !self.tags.contains(&tag) {
            self.tags.push(tag);
            self.modified_at = chrono::Utc::now().to_rfc3339();
        }
    }

    /// Remove a tag
    pub fn remove_tag(&mut self, tag: &str) {
        if let Some(pos) = self.tags.iter().position(|t| t == tag) {
            self.tags.remove(pos);
            self.modified_at = chrono::Utc::now().to_rfc3339();
        }
    }

    /// Link to an imprint document
    pub fn link_to_document(
        &mut self,
        document_id: impl Into<String>,
        document_title: impl Into<String>,
        figure_label: impl Into<String>,
        auto_update: bool,
    ) {
        let link = ImprintLink {
            document_id: document_id.into(),
            document_title: document_title.into(),
            figure_label: figure_label.into(),
            auto_update,
            last_synced: None,
        };
        self.imprint_links.push(link);
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }

    /// Unlink from an imprint document
    pub fn unlink_from_document(&mut self, document_id: &str) {
        self.imprint_links.retain(|l| l.document_id != document_id);
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }

    /// Check if this figure has any auto-update links
    pub fn has_auto_update_links(&self) -> bool {
        self.imprint_links.iter().any(|l| l.auto_update)
    }

    /// Get all auto-update links
    pub fn auto_update_links(&self) -> Vec<&ImprintLink> {
        self.imprint_links.iter().filter(|l| l.auto_update).collect()
    }

    /// Mark a link as synced
    pub fn mark_synced(&mut self, document_id: &str) {
        if let Some(link) = self.imprint_links.iter_mut().find(|l| l.document_id == document_id) {
            link.last_synced = Some(chrono::Utc::now().to_rfc3339());
        }
    }
}

impl ImprintLink {
    /// Check if this link needs syncing (auto-update enabled and never synced or figure modified)
    pub fn needs_sync(&self, figure_modified_at: &str) -> bool {
        if !self.auto_update {
            return false;
        }

        match &self.last_synced {
            None => true,
            Some(synced) => synced.as_str() < figure_modified_at,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_library_creation() {
        let library = FigureLibrary::new("My Figures");
        assert_eq!(library.name, "My Figures");
        assert!(library.figures.is_empty());
        assert!(library.folders.is_empty());
    }

    #[test]
    fn test_add_and_get_figure() {
        let mut library = FigureLibrary::new("Test");

        let figure = LibraryFigure::new(
            "Test Figure",
            "session-1",
            r#"{"zoom": 1.0}"#,
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );
        let figure_id = figure.id.clone();

        library.add_figure(figure);

        assert_eq!(library.figures.len(), 1);
        assert!(library.get_figure(&figure_id).is_some());
    }

    #[test]
    fn test_folder_organization() {
        let mut library = FigureLibrary::new("Test");

        let folder = library.create_folder("Noise Figures");
        let folder_id = folder.id.clone();

        let figure = LibraryFigure::new(
            "Perlin Noise",
            "session-1",
            "{}",
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );
        let figure_id = figure.id.clone();
        library.add_figure(figure);

        library.move_to_folder(&figure_id, Some(&folder_id));

        let figures_in_folder = library.figures_in_folder(&folder_id);
        assert_eq!(figures_in_folder.len(), 1);

        let unfiled = library.unfiled_figures();
        assert!(unfiled.is_empty());
    }

    #[test]
    fn test_imprint_linking() {
        let mut figure = LibraryFigure::new(
            "Test Figure",
            "session-1",
            "{}",
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );

        figure.link_to_document("doc-1", "My Paper", "fig:test", true);

        assert_eq!(figure.imprint_links.len(), 1);
        assert!(figure.has_auto_update_links());

        let auto_links = figure.auto_update_links();
        assert_eq!(auto_links.len(), 1);
        assert_eq!(auto_links[0].figure_label, "fig:test");
    }

    #[test]
    fn test_search() {
        let mut library = FigureLibrary::new("Test");

        let mut fig1 = LibraryFigure::new(
            "Perlin Noise",
            "s1",
            "{}",
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );
        fig1.add_tag("noise");

        let fig2 = LibraryFigure::new(
            "Mandelbrot",
            "s2",
            "{}",
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );

        library.add_figure(fig1);
        library.add_figure(fig2);

        let results = library.search("perlin");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Perlin Noise");

        let results = library.search("noise");
        assert_eq!(results.len(), 1); // Found by tag
    }

    #[test]
    fn test_sync_detection() {
        let link = ImprintLink {
            document_id: "doc-1".to_string(),
            document_title: "Paper".to_string(),
            figure_label: "fig:1".to_string(),
            auto_update: true,
            last_synced: None,
        };

        // Never synced should need sync
        assert!(link.needs_sync("2024-01-01T00:00:00Z"));

        let link_synced = ImprintLink {
            document_id: "doc-1".to_string(),
            document_title: "Paper".to_string(),
            figure_label: "fig:1".to_string(),
            auto_update: true,
            last_synced: Some("2024-01-01T12:00:00Z".to_string()),
        };

        // Synced after modification - no sync needed
        assert!(!link_synced.needs_sync("2024-01-01T10:00:00Z"));

        // Modified after sync - needs sync
        assert!(link_synced.needs_sync("2024-01-01T14:00:00Z"));
    }
}
