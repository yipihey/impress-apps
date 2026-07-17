//! Semantic Scholar source client (stub).
//!
//! TODO: port from
//! `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/`
//! (the Swift codebase currently uses Semantic Scholar indirectly through
//! other sources; this stub reserves the slot in the trait registry).

use async_trait::async_trait;

use crate::error::SourceError;
use crate::types::{PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

pub struct SemanticScholarSource;

impl Default for SemanticScholarSource {
    fn default() -> Self {
        Self::new()
    }
}

impl SemanticScholarSource {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl SourcePlugin for SemanticScholarSource {
    fn id(&self) -> &str {
        "s2"
    }
    fn display_name(&self) -> &str {
        "Semantic Scholar"
    }
    fn requires_credentials(&self) -> bool {
        false
    }

    async fn search(
        &self,
        _query: &SearchQuery,
        _credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        unimplemented!("Semantic Scholar source: ported in follow-up.");
    }

    async fn fetch_by_id(
        &self,
        _id: &str,
        _credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        unimplemented!("Semantic Scholar source: ported in follow-up.");
    }
}
