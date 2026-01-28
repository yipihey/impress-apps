//! Manuscript tracking for works in progress

use crate::Author;
use serde::{Deserialize, Serialize};

/// A manuscript being written (links imprint document to imbib)
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Manuscript {
    pub id: String,
    pub imprint_document_id: String,
    pub title: String,
    pub authors: Vec<Author>,
    pub status: ManuscriptStatus,
    pub target_journal: Option<String>,
    pub cited_publication_ids: Vec<String>,
    pub versions: Vec<ManuscriptVersion>,
    pub created_at: String,
    pub modified_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum ManuscriptStatus {
    Draft,
    InReview,
    Revision,
    Accepted,
    Published { doi: String },
    Archived,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ManuscriptVersion {
    pub version_id: String,
    pub snapshot_id: String,
    pub label: Option<String>,
    pub created_at: String,
    pub word_count: u32,
    pub citation_count: u32,
}
