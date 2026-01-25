//! Merge and conflict resolution for sync

use crate::domain::Publication;
use serde::{Deserialize, Serialize};

#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize)]
pub enum MergeStrategy {
    /// Keep local version
    KeepLocal,
    /// Keep remote version
    KeepRemote,
    /// Keep newer (by modified_at)
    KeepNewer,
    /// Merge fields (non-destructive)
    MergeFields,
    /// Manual resolution required
    Manual,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct Conflict {
    pub id: String,
    pub local: Publication,
    pub remote: Publication,
    pub base: Option<Publication>,
    pub conflicting_fields: Vec<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct MergeResult {
    pub merged: Publication,
    pub strategy_used: MergeStrategy,
    pub fields_from_local: Vec<String>,
    pub fields_from_remote: Vec<String>,
}

pub(crate) fn detect_conflict_internal(
    local: &Publication,
    remote: &Publication,
    base: Option<Publication>,
) -> Option<Conflict> {
    let mut conflicting_fields = Vec::new();

    // Check each field for conflicts
    if local.title != remote.title {
        conflicting_fields.push("title".to_string());
    }
    if local.year != remote.year {
        conflicting_fields.push("year".to_string());
    }
    if local.authors != remote.authors {
        conflicting_fields.push("authors".to_string());
    }
    if local.abstract_text != remote.abstract_text {
        conflicting_fields.push("abstract".to_string());
    }
    if local.journal != remote.journal {
        conflicting_fields.push("journal".to_string());
    }
    if local.identifiers != remote.identifiers {
        conflicting_fields.push("identifiers".to_string());
    }
    if local.tags != remote.tags {
        conflicting_fields.push("tags".to_string());
    }
    if local.note != remote.note {
        conflicting_fields.push("note".to_string());
    }

    if conflicting_fields.is_empty() {
        None
    } else {
        Some(Conflict {
            id: local.id.clone(),
            local: local.clone(),
            remote: remote.clone(),
            base,
            conflicting_fields,
        })
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn detect_conflict(
    local: &Publication,
    remote: &Publication,
    base: Option<Publication>,
) -> Option<Conflict> {
    detect_conflict_internal(local, remote, base)
}

pub(crate) fn merge_publications_internal(
    local: &Publication,
    remote: &Publication,
    strategy: MergeStrategy,
) -> MergeResult {
    match strategy {
        MergeStrategy::KeepLocal => MergeResult {
            merged: local.clone(),
            strategy_used: MergeStrategy::KeepLocal,
            fields_from_local: vec!["all".to_string()],
            fields_from_remote: vec![],
        },
        MergeStrategy::KeepRemote => MergeResult {
            merged: remote.clone(),
            strategy_used: MergeStrategy::KeepRemote,
            fields_from_local: vec![],
            fields_from_remote: vec!["all".to_string()],
        },
        MergeStrategy::KeepNewer => {
            let local_newer = match (&local.modified_at, &remote.modified_at) {
                (Some(l), Some(r)) => l > r,
                (Some(_), None) => true,
                (None, Some(_)) => false,
                (None, None) => true, // Default to local
            };
            if local_newer {
                MergeResult {
                    merged: local.clone(),
                    strategy_used: MergeStrategy::KeepNewer,
                    fields_from_local: vec!["all".to_string()],
                    fields_from_remote: vec![],
                }
            } else {
                MergeResult {
                    merged: remote.clone(),
                    strategy_used: MergeStrategy::KeepNewer,
                    fields_from_local: vec![],
                    fields_from_remote: vec!["all".to_string()],
                }
            }
        }
        MergeStrategy::MergeFields => merge_fields(local, remote),
        MergeStrategy::Manual => MergeResult {
            merged: local.clone(),
            strategy_used: MergeStrategy::Manual,
            fields_from_local: vec!["all".to_string()],
            fields_from_remote: vec![],
        },
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn merge_publications(
    local: &Publication,
    remote: &Publication,
    strategy: MergeStrategy,
) -> MergeResult {
    merge_publications_internal(local, remote, strategy)
}

fn merge_fields(local: &Publication, remote: &Publication) -> MergeResult {
    let mut merged = local.clone();
    let mut fields_from_local = Vec::new();
    let mut fields_from_remote = Vec::new();

    // Strategy: prefer non-empty over empty, prefer more complete

    // Title: prefer longer (more complete)
    if remote.title.len() > local.title.len() {
        merged.title = remote.title.clone();
        fields_from_remote.push("title".to_string());
    } else {
        fields_from_local.push("title".to_string());
    }

    // Year: prefer present over absent
    if merged.year.is_none() && remote.year.is_some() {
        merged.year = remote.year;
        fields_from_remote.push("year".to_string());
    } else {
        fields_from_local.push("year".to_string());
    }

    // Authors: prefer more authors
    if remote.authors.len() > local.authors.len() {
        merged.authors = remote.authors.clone();
        fields_from_remote.push("authors".to_string());
    } else {
        fields_from_local.push("authors".to_string());
    }

    // Abstract: prefer present over absent, then longer
    match (&local.abstract_text, &remote.abstract_text) {
        (None, Some(_)) => {
            merged.abstract_text = remote.abstract_text.clone();
            fields_from_remote.push("abstract".to_string());
        }
        (Some(l), Some(r)) if r.len() > l.len() => {
            merged.abstract_text = remote.abstract_text.clone();
            fields_from_remote.push("abstract".to_string());
        }
        _ => {
            fields_from_local.push("abstract".to_string());
        }
    }

    // Identifiers: merge (union)
    if merged.identifiers.doi.is_none() && remote.identifiers.doi.is_some() {
        merged.identifiers.doi = remote.identifiers.doi.clone();
        fields_from_remote.push("doi".to_string());
    }
    if merged.identifiers.arxiv_id.is_none() && remote.identifiers.arxiv_id.is_some() {
        merged.identifiers.arxiv_id = remote.identifiers.arxiv_id.clone();
        fields_from_remote.push("arxiv_id".to_string());
    }
    if merged.identifiers.pmid.is_none() && remote.identifiers.pmid.is_some() {
        merged.identifiers.pmid = remote.identifiers.pmid.clone();
        fields_from_remote.push("pmid".to_string());
    }
    if merged.identifiers.bibcode.is_none() && remote.identifiers.bibcode.is_some() {
        merged.identifiers.bibcode = remote.identifiers.bibcode.clone();
        fields_from_remote.push("bibcode".to_string());
    }

    // Tags: union
    for tag in &remote.tags {
        if !merged.tags.contains(tag) {
            merged.tags.push(tag.clone());
            if !fields_from_remote.contains(&"tags".to_string()) {
                fields_from_remote.push("tags".to_string());
            }
        }
    }

    // Linked files: union (by id)
    let local_file_ids: std::collections::HashSet<_> =
        local.linked_files.iter().map(|f| &f.id).collect();
    for file in &remote.linked_files {
        if !local_file_ids.contains(&file.id) {
            merged.linked_files.push(file.clone());
            if !fields_from_remote.contains(&"linked_files".to_string()) {
                fields_from_remote.push("linked_files".to_string());
            }
        }
    }

    // Citation count: prefer higher (more recent)
    if let Some(remote_count) = remote.citation_count {
        if merged
            .citation_count
            .map(|c| remote_count > c)
            .unwrap_or(true)
        {
            merged.citation_count = Some(remote_count);
            merged.enrichment_date = remote.enrichment_date.clone();
            fields_from_remote.push("citation_count".to_string());
        }
    }

    MergeResult {
        merged,
        strategy_used: MergeStrategy::MergeFields,
        fields_from_local,
        fields_from_remote,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_prefers_complete() {
        let mut local = Publication::new(
            "test2020".to_string(),
            "article".to_string(),
            "Short".to_string(),
        );
        local.year = Some(2020);

        let mut remote = Publication::new(
            "test2020".to_string(),
            "article".to_string(),
            "A Much Longer and More Complete Title".to_string(),
        );
        remote.abstract_text = Some("This is an abstract".to_string());

        let result = merge_publications(&local, &remote, MergeStrategy::MergeFields);

        assert_eq!(result.merged.title, "A Much Longer and More Complete Title");
        assert_eq!(result.merged.year, Some(2020)); // From local
        assert!(result.merged.abstract_text.is_some()); // From remote
    }

    #[test]
    fn test_detect_conflict() {
        let local = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Title A".to_string(),
        );
        let remote = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Title B".to_string(),
        );

        let conflict = detect_conflict(&local, &remote, None);
        assert!(conflict.is_some());
        let conflict = conflict.unwrap();
        assert!(conflict.conflicting_fields.contains(&"title".to_string()));
    }

    #[test]
    fn test_no_conflict_identical() {
        let local = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Same Title".to_string(),
        );
        let remote = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Same Title".to_string(),
        );

        let conflict = detect_conflict(&local, &remote, None);
        assert!(conflict.is_none());
    }

    #[test]
    fn test_keep_local_strategy() {
        let local = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Local Title".to_string(),
        );
        let remote = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Remote Title".to_string(),
        );

        let result = merge_publications(&local, &remote, MergeStrategy::KeepLocal);
        assert_eq!(result.merged.title, "Local Title");
        assert!(matches!(result.strategy_used, MergeStrategy::KeepLocal));
    }

    #[test]
    fn test_keep_remote_strategy() {
        let local = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Local Title".to_string(),
        );
        let remote = Publication::new(
            "test".to_string(),
            "article".to_string(),
            "Remote Title".to_string(),
        );

        let result = merge_publications(&local, &remote, MergeStrategy::KeepRemote);
        assert_eq!(result.merged.title, "Remote Title");
        assert!(matches!(result.strategy_used, MergeStrategy::KeepRemote));
    }
}
