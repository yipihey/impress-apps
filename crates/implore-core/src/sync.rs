//! Sync service for figure-document linking between implore and imprint.
//!
//! This module provides types and services for syncing figures between
//! implore visualizations and imprint documents, enabling auto-updating
//! figures when their source data or view changes.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

use crate::library::{FigureLibrary, ImprintLink, LibraryFigure};

/// Notification sent when a figure is modified
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FigureUpdateNotification {
    /// ID of the figure that changed
    pub figure_id: String,

    /// ID of the session that contains the figure
    pub session_id: String,

    /// New JSON view state
    pub new_view_state: String,

    /// New thumbnail data (PNG)
    pub new_thumbnail: Option<Vec<u8>>,

    /// Exported figure data in various formats
    pub exports: Vec<FigureExportData>,

    /// When this update occurred
    pub updated_at: String,
}

/// Exported figure data for a specific format
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FigureExportData {
    /// Format identifier (png, pdf, svg)
    pub format: String,

    /// Export data
    pub data: Vec<u8>,

    /// Width in pixels
    pub width: u32,

    /// Height in pixels
    pub height: u32,

    /// DPI for raster formats
    pub dpi: u32,
}

/// Result of a sync operation
#[derive(Clone, Debug, Serialize, Deserialize)]
pub enum SyncResult {
    /// Sync completed successfully
    Success {
        document_id: String,
        figure_label: String,
        synced_at: String,
    },

    /// Sync failed
    Failed {
        document_id: String,
        figure_label: String,
        error: String,
    },

    /// Document not found or no longer linked
    NotLinked { document_id: String },
}

/// Service for syncing figures to imprint documents
#[derive(Default)]
pub struct FigureSyncService {
    /// Queue of pending updates
    pending_updates: VecDeque<FigureUpdateNotification>,

    /// Results of recent sync operations
    recent_results: VecDeque<SyncResult>,

    /// Maximum number of results to keep
    max_results: usize,
}

impl FigureSyncService {
    /// Create a new sync service
    pub fn new() -> Self {
        Self {
            pending_updates: VecDeque::new(),
            recent_results: VecDeque::new(),
            max_results: 100,
        }
    }

    /// Queue an update for processing
    pub fn queue_update(&mut self, notification: FigureUpdateNotification) {
        self.pending_updates.push_back(notification);
    }

    /// Process pending updates
    ///
    /// Returns the number of updates processed.
    pub fn process_updates(&mut self, library: &mut FigureLibrary) -> usize {
        let mut processed = 0;

        while let Some(notification) = self.pending_updates.pop_front() {
            if let Some(figure) = library.get_figure_mut(&notification.figure_id) {
                // Update figure's view state
                figure.view_state_snapshot = notification.new_view_state.clone();

                // Update thumbnail if provided
                if let Some(thumbnail) = notification.new_thumbnail.clone() {
                    figure.thumbnail = Some(thumbnail);
                }

                // Mark modified time
                figure.modified_at = notification.updated_at.clone();

                // Find links that need syncing
                for link in &figure.imprint_links {
                    if link.auto_update {
                        let result = self.sync_to_document(figure, link, &notification);
                        self.add_result(result);
                    }
                }
            }

            processed += 1;
        }

        processed
    }

    /// Sync a figure to a specific document
    fn sync_to_document(
        &self,
        figure: &LibraryFigure,
        link: &ImprintLink,
        notification: &FigureUpdateNotification,
    ) -> SyncResult {
        // In a real implementation, this would:
        // 1. Call imprint via URL scheme or shared storage
        // 2. Wait for confirmation
        // For now, we simulate success

        // Build URL scheme command
        let _url = format!(
            "imprint://update-figure?id={}&session={}&state={}",
            figure.id,
            figure.session_id,
            urlencoding::encode(&notification.new_view_state),
        );

        // Simulated sync - in real implementation would open URL or write to shared storage
        SyncResult::Success {
            document_id: link.document_id.clone(),
            figure_label: link.figure_label.clone(),
            synced_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    /// Add a result to the recent results queue
    fn add_result(&mut self, result: SyncResult) {
        self.recent_results.push_back(result);

        // Trim to max size
        while self.recent_results.len() > self.max_results {
            self.recent_results.pop_front();
        }
    }

    /// Get pending update count
    pub fn pending_count(&self) -> usize {
        self.pending_updates.len()
    }

    /// Get recent sync results
    pub fn recent_results(&self) -> &VecDeque<SyncResult> {
        &self.recent_results
    }

    /// Clear all pending updates
    pub fn clear_pending(&mut self) {
        self.pending_updates.clear();
    }

    /// Called when a figure is modified in implore
    ///
    /// This method should be called by the visualization session when
    /// the user modifies a figure that has auto-update links.
    pub fn on_figure_modified(
        &mut self,
        library: &FigureLibrary,
        figure_id: &str,
        session_id: &str,
        new_view_state: &str,
        thumbnail: Option<Vec<u8>>,
    ) {
        if let Some(figure) = library.get_figure(figure_id) {
            // Only queue if there are auto-update links
            if figure.has_auto_update_links() {
                self.queue_update(FigureUpdateNotification {
                    figure_id: figure_id.to_string(),
                    session_id: session_id.to_string(),
                    new_view_state: new_view_state.to_string(),
                    new_thumbnail: thumbnail,
                    exports: Vec::new(), // Exports generated on demand
                    updated_at: chrono::Utc::now().to_rfc3339(),
                });
            }
        }
    }

    /// Handle figure being unlinked from a document
    ///
    /// Called when imprint notifies that a figure reference was removed.
    pub fn on_figure_unlinked(library: &mut FigureLibrary, figure_id: &str, document_id: &str) {
        if let Some(figure) = library.get_figure_mut(figure_id) {
            figure.unlink_from_document(document_id);
        }
    }

    /// Generate a URL scheme command for syncing a figure
    pub fn generate_sync_url(figure: &LibraryFigure, link: &ImprintLink) -> String {
        format!(
            "imprint://update-figure?figure_id={}&document_id={}&label={}",
            urlencoding::encode(&figure.id),
            urlencoding::encode(&link.document_id),
            urlencoding::encode(&link.figure_label),
        )
    }

    /// Generate a URL for inserting a figure into a new document
    pub fn generate_insert_url(figure: &LibraryFigure, document_id: &str) -> String {
        format!(
            "imprint://insert-figure?figure_id={}&session_id={}&document_id={}",
            urlencoding::encode(&figure.id),
            urlencoding::encode(&figure.session_id),
            urlencoding::encode(document_id),
        )
    }
}

/// Statistics about sync operations
#[derive(Clone, Debug, Default)]
pub struct SyncStats {
    pub total_synced: u64,
    pub total_failed: u64,
    pub pending: usize,
    pub last_sync_at: Option<String>,
}

impl FigureSyncService {
    /// Get sync statistics
    pub fn stats(&self) -> SyncStats {
        let (synced, failed) = self.recent_results.iter().fold((0u64, 0u64), |(s, f), r| {
            match r {
                SyncResult::Success { .. } => (s + 1, f),
                SyncResult::Failed { .. } => (s, f + 1),
                SyncResult::NotLinked { .. } => (s, f),
            }
        });

        let last_sync = self
            .recent_results
            .iter()
            .filter_map(|r| match r {
                SyncResult::Success { synced_at, .. } => Some(synced_at.clone()),
                _ => None,
            })
            .last();

        SyncStats {
            total_synced: synced,
            total_failed: failed,
            pending: self.pending_updates.len(),
            last_sync_at: last_sync,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dataset::DatasetSource;

    fn create_test_library() -> FigureLibrary {
        let mut library = FigureLibrary::new("Test");

        let mut figure = LibraryFigure::new(
            "Test Figure",
            "session-1",
            r#"{"zoom": 1.0}"#,
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );
        figure.link_to_document("doc-1", "My Paper", "fig:test", true);
        library.add_figure(figure);

        library
    }

    #[test]
    fn test_sync_service_creation() {
        let service = FigureSyncService::new();
        assert_eq!(service.pending_count(), 0);
    }

    #[test]
    fn test_queue_update() {
        let mut service = FigureSyncService::new();

        service.queue_update(FigureUpdateNotification {
            figure_id: "fig-1".to_string(),
            session_id: "session-1".to_string(),
            new_view_state: "{}".to_string(),
            new_thumbnail: None,
            exports: Vec::new(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });

        assert_eq!(service.pending_count(), 1);
    }

    #[test]
    fn test_process_updates() {
        let mut service = FigureSyncService::new();
        let mut library = create_test_library();

        let figure_id = library.figures[0].id.clone();

        service.queue_update(FigureUpdateNotification {
            figure_id: figure_id.clone(),
            session_id: "session-1".to_string(),
            new_view_state: r#"{"zoom": 2.0}"#.to_string(),
            new_thumbnail: None,
            exports: Vec::new(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });

        let processed = service.process_updates(&mut library);
        assert_eq!(processed, 1);
        assert_eq!(service.pending_count(), 0);

        // Check view state was updated
        let figure = library.get_figure(&figure_id).unwrap();
        assert!(figure.view_state_snapshot.contains("2.0"));
    }

    #[test]
    fn test_on_figure_modified() {
        let mut service = FigureSyncService::new();
        let library = create_test_library();
        let figure_id = library.figures[0].id.clone();

        service.on_figure_modified(&library, &figure_id, "session-1", r#"{"zoom": 3.0}"#, None);

        assert_eq!(service.pending_count(), 1);
    }

    #[test]
    fn test_sync_url_generation() {
        let library = create_test_library();
        let figure = &library.figures[0];
        let link = &figure.imprint_links[0];

        let url = FigureSyncService::generate_sync_url(figure, link);
        assert!(url.starts_with("imprint://update-figure"));
        assert!(url.contains("document_id="));
    }

    #[test]
    fn test_stats() {
        let service = FigureSyncService::new();
        let stats = service.stats();

        assert_eq!(stats.total_synced, 0);
        assert_eq!(stats.total_failed, 0);
        assert_eq!(stats.pending, 0);
    }

    #[test]
    fn test_clear_pending() {
        let mut service = FigureSyncService::new();

        // Queue multiple updates
        for i in 0..5 {
            service.queue_update(FigureUpdateNotification {
                figure_id: format!("fig-{}", i),
                session_id: "session-1".to_string(),
                new_view_state: "{}".to_string(),
                new_thumbnail: None,
                exports: Vec::new(),
                updated_at: chrono::Utc::now().to_rfc3339(),
            });
        }

        assert_eq!(service.pending_count(), 5);

        service.clear_pending();
        assert_eq!(service.pending_count(), 0);
    }

    #[test]
    fn test_on_figure_unlinked() {
        let mut library = create_test_library();
        let figure_id = library.figures[0].id.clone();

        // Verify figure has a link initially
        assert_eq!(library.figures[0].imprint_links.len(), 1);

        // Unlink the figure
        FigureSyncService::on_figure_unlinked(&mut library, &figure_id, "doc-1");

        // Verify link was removed
        let figure = library.get_figure(&figure_id).unwrap();
        assert_eq!(figure.imprint_links.len(), 0);
    }

    #[test]
    fn test_on_figure_modified_without_auto_update() {
        let mut service = FigureSyncService::new();
        let mut library = FigureLibrary::new("Test");

        // Create figure WITHOUT auto-update link
        let mut figure = LibraryFigure::new(
            "Test Figure",
            "session-1",
            r#"{"zoom": 1.0}"#,
            DatasetSource::InMemory {
                format: "generated".to_string(),
            },
        );
        // Link with auto_update = false
        figure.imprint_links.push(crate::library::ImprintLink {
            document_id: "doc-1".to_string(),
            document_title: "Paper".to_string(),
            figure_label: "fig:test".to_string(),
            auto_update: false, // Not auto-updating
            last_synced: None,
        });
        let figure_id = figure.id.clone();
        library.add_figure(figure);

        // Try to trigger update
        service.on_figure_modified(&library, &figure_id, "session-1", r#"{"zoom": 2.0}"#, None);

        // Should NOT queue an update since no auto-update links
        assert_eq!(service.pending_count(), 0);
    }

    #[test]
    fn test_process_updates_nonexistent_figure() {
        let mut service = FigureSyncService::new();
        let mut library = FigureLibrary::new("Test");

        // Queue update for figure that doesn't exist
        service.queue_update(FigureUpdateNotification {
            figure_id: "nonexistent".to_string(),
            session_id: "session-1".to_string(),
            new_view_state: "{}".to_string(),
            new_thumbnail: None,
            exports: Vec::new(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });

        // Process should handle gracefully
        let processed = service.process_updates(&mut library);
        assert_eq!(processed, 1); // Still counts as processed
        assert_eq!(service.pending_count(), 0);
    }

    #[test]
    fn test_generate_insert_url() {
        let library = create_test_library();
        let figure = &library.figures[0];

        let url = FigureSyncService::generate_insert_url(figure, "new-doc-id");
        assert!(url.starts_with("imprint://insert-figure"));
        assert!(url.contains("document_id=new-doc-id"));
        assert!(url.contains(&format!("figure_id={}", urlencoding::encode(&figure.id))));
    }

    #[test]
    fn test_stats_after_processing() {
        let mut service = FigureSyncService::new();
        let mut library = create_test_library();
        let figure_id = library.figures[0].id.clone();

        service.queue_update(FigureUpdateNotification {
            figure_id,
            session_id: "session-1".to_string(),
            new_view_state: r#"{"zoom": 2.0}"#.to_string(),
            new_thumbnail: None,
            exports: Vec::new(),
            updated_at: chrono::Utc::now().to_rfc3339(),
        });

        service.process_updates(&mut library);

        let stats = service.stats();
        assert_eq!(stats.total_synced, 1);
        assert!(stats.last_sync_at.is_some());
    }
}
