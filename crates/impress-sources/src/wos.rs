//! Web of Science source client (stub).
//!
//! TODO: port from
//! `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/WoS/`.
//! Web of Science Lite uses a key-authenticated REST endpoint
//! (`https://api.clarivate.com/apis/wos-starter/v1/documents`) returning JSON.
//! Auth is via `X-ApiKey` header — the caller passes the key in as
//! `credentials`.

use async_trait::async_trait;

use crate::error::SourceError;
use crate::types::{PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

pub struct WosSource;

impl Default for WosSource {
    fn default() -> Self {
        Self::new()
    }
}

impl WosSource {
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl SourcePlugin for WosSource {
    fn id(&self) -> &str {
        "wos"
    }
    fn display_name(&self) -> &str {
        "Web of Science"
    }
    fn requires_credentials(&self) -> bool {
        true
    }

    async fn search(
        &self,
        _query: &SearchQuery,
        _credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        unimplemented!("WoS source: ported in follow-up. See apps/imbib/.../BuiltIn/WoS/");
    }

    async fn fetch_by_id(
        &self,
        _id: &str,
        _credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        unimplemented!("WoS source: ported in follow-up. See apps/imbib/.../BuiltIn/WoS/");
    }
}
