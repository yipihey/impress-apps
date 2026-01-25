//! Annotation storage and serialization

use super::types::{Annotation, DrawingAnnotation};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use thiserror::Error;

#[derive(uniffi::Error, Error, Debug)]
pub enum AnnotationStorageError {
    #[error("Serialization error: {0}")]
    SerializationError(String),
    #[error("Annotation not found: {0}")]
    NotFound(String),
}

/// All annotations for a publication
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize, Default)]
pub struct PublicationAnnotations {
    pub publication_id: String,
    pub annotations: Vec<Annotation>,
    pub drawings: Vec<DrawingAnnotation>,
    pub version: u32, // For conflict resolution
    pub modified_at: String,
}

impl PublicationAnnotations {
    pub fn new(publication_id: String) -> Self {
        Self {
            publication_id,
            annotations: Vec::new(),
            drawings: Vec::new(),
            version: 1,
            modified_at: chrono::Utc::now().to_rfc3339(),
        }
    }

    pub fn add_annotation(&mut self, annotation: Annotation) {
        self.annotations.push(annotation);
        self.increment_version();
    }

    pub fn remove_annotation(&mut self, annotation_id: &str) -> Option<Annotation> {
        if let Some(pos) = self.annotations.iter().position(|a| a.id == annotation_id) {
            self.increment_version();
            Some(self.annotations.remove(pos))
        } else {
            None
        }
    }

    pub fn get_annotation(&self, annotation_id: &str) -> Option<&Annotation> {
        self.annotations.iter().find(|a| a.id == annotation_id)
    }

    pub fn get_annotation_mut(&mut self, annotation_id: &str) -> Option<&mut Annotation> {
        self.annotations.iter_mut().find(|a| a.id == annotation_id)
    }

    pub fn annotations_for_page(&self, page_number: u32) -> Vec<&Annotation> {
        self.annotations
            .iter()
            .filter(|a| a.page_number == page_number)
            .collect()
    }

    pub fn add_drawing(&mut self, drawing: DrawingAnnotation) {
        self.drawings.push(drawing);
        self.increment_version();
    }

    pub fn drawings_for_page(&self, page_number: u32) -> Vec<&DrawingAnnotation> {
        self.drawings
            .iter()
            .filter(|d| d.page_number == page_number)
            .collect()
    }

    fn increment_version(&mut self) {
        self.version += 1;
        self.modified_at = chrono::Utc::now().to_rfc3339();
    }
}

/// Serialize annotations to JSON
#[cfg(feature = "native")]
#[uniffi::export]
pub fn serialize_annotations(
    annotations: &PublicationAnnotations,
) -> Result<String, AnnotationStorageError> {
    serde_json::to_string(annotations)
        .map_err(|e| AnnotationStorageError::SerializationError(e.to_string()))
}

/// Deserialize annotations from JSON
#[cfg(feature = "native")]
#[uniffi::export]
pub fn deserialize_annotations(
    json: &str,
) -> Result<PublicationAnnotations, AnnotationStorageError> {
    serde_json::from_str(json)
        .map_err(|e| AnnotationStorageError::SerializationError(e.to_string()))
}

/// Merge two annotation sets (for sync conflicts)
///
/// Strategy: Keep all unique annotations, prefer newer versions for conflicts
#[cfg(feature = "native")]
#[uniffi::export]
pub fn merge_annotations(
    local: &PublicationAnnotations,
    remote: &PublicationAnnotations,
) -> PublicationAnnotations {
    let mut merged = PublicationAnnotations::new(local.publication_id.clone());

    // Build maps by ID
    let local_map: HashMap<&str, &Annotation> = local
        .annotations
        .iter()
        .map(|a| (a.id.as_str(), a))
        .collect();

    let remote_map: HashMap<&str, &Annotation> = remote
        .annotations
        .iter()
        .map(|a| (a.id.as_str(), a))
        .collect();

    // Merge annotations
    let mut seen_ids = std::collections::HashSet::new();

    for (id, local_ann) in &local_map {
        if let Some(remote_ann) = remote_map.get(id) {
            // Both have it - keep newer
            if local_ann.modified_at >= remote_ann.modified_at {
                merged.annotations.push((*local_ann).clone());
            } else {
                merged.annotations.push((*remote_ann).clone());
            }
        } else {
            // Only local has it
            merged.annotations.push((*local_ann).clone());
        }
        seen_ids.insert(*id);
    }

    // Add remote-only annotations
    for (id, remote_ann) in &remote_map {
        if !seen_ids.contains(id) {
            merged.annotations.push((*remote_ann).clone());
        }
    }

    // Similar merge for drawings
    let local_drawing_map: HashMap<&str, &DrawingAnnotation> =
        local.drawings.iter().map(|d| (d.id.as_str(), d)).collect();

    let remote_drawing_map: HashMap<&str, &DrawingAnnotation> =
        remote.drawings.iter().map(|d| (d.id.as_str(), d)).collect();

    let mut seen_drawing_ids = std::collections::HashSet::new();

    for (id, local_drawing) in &local_drawing_map {
        if let Some(remote_drawing) = remote_drawing_map.get(id) {
            if local_drawing.modified_at >= remote_drawing.modified_at {
                merged.drawings.push((*local_drawing).clone());
            } else {
                merged.drawings.push((*remote_drawing).clone());
            }
        } else {
            merged.drawings.push((*local_drawing).clone());
        }
        seen_drawing_ids.insert(*id);
    }

    for (id, remote_drawing) in &remote_drawing_map {
        if !seen_drawing_ids.contains(id) {
            merged.drawings.push((*remote_drawing).clone());
        }
    }

    merged.version = local.version.max(remote.version) + 1;
    merged
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::annotations::types::Rect;

    #[test]
    fn test_serialize_deserialize() {
        let mut annotations = PublicationAnnotations::new("test-pub".to_string());
        annotations.add_annotation(Annotation::new_highlight(
            "test-pub".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 100.0, 20.0)],
            Some("Test text".to_string()),
        ));

        let json = serialize_annotations(&annotations).unwrap();
        let restored = deserialize_annotations(&json).unwrap();

        assert_eq!(restored.annotations.len(), 1);
        assert_eq!(
            restored.annotations[0].selected_text,
            Some("Test text".to_string())
        );
    }

    #[test]
    fn test_merge_annotations() {
        let mut local = PublicationAnnotations::new("test".to_string());
        let mut remote = PublicationAnnotations::new("test".to_string());

        // Local-only annotation
        local.add_annotation(Annotation::new_highlight(
            "test".to_string(),
            1,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        ));

        // Remote-only annotation
        remote.add_annotation(Annotation::new_highlight(
            "test".to_string(),
            2,
            vec![Rect::new(0.0, 0.0, 10.0, 10.0)],
            None,
        ));

        let merged = merge_annotations(&local, &remote);
        assert_eq!(merged.annotations.len(), 2);
    }
}
