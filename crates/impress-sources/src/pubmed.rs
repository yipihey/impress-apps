//! PubMed source client (stub).
//!
//! TODO: port from
//! `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/PubMedSource.swift`.
//!
//! PubMed uses NCBI's E-Utilities (esearch + efetch) with XML responses.
//! The Swift implementation also handles a two-step ID-list → records flow
//! and decodes MEDLINE article XML. Both are substantial — keep this stub
//! ABI-compatible so the trait surface stays stable while the implementation
//! is filled in by a follow-up session.

use async_trait::async_trait;

use crate::error::SourceError;
use crate::types::{PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

pub struct PubmedSource;

impl Default for PubmedSource {
    fn default() -> Self {
        Self::new()
    }
}

impl PubmedSource {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl SourcePlugin for PubmedSource {
    fn id(&self) -> &str {
        "pubmed"
    }
    fn display_name(&self) -> &str {
        "PubMed"
    }
    fn requires_credentials(&self) -> bool {
        false
    }

    async fn search(
        &self,
        _query: &SearchQuery,
        _credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        unimplemented!(
            "PubMed source: ported in follow-up. See apps/imbib/.../BuiltIn/PubMedSource.swift"
        );
    }

    async fn fetch_by_id(
        &self,
        _id: &str,
        _credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        unimplemented!(
            "PubMed source: ported in follow-up. See apps/imbib/.../BuiltIn/PubMedSource.swift"
        );
    }
}
