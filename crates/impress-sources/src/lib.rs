//! HTTP source clients for academic paper databases.
//!
//! Ports the Swift source-plugin implementations under
//! `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/`
//! into a single Rust crate so any view layer (Swift UI, ratatui TUI, web,
//! Python notebook, MCP tool, CLI) can run the same queries against the same
//! parsers.
//!
//! Each source implements the [`SourcePlugin`] trait. Credentials (when
//! required) are passed in by the caller — this crate never touches the
//! Keychain or any platform secret store.
//!
//! ## Implemented sources
//! - [`arxiv`] — arXiv Atom-feed API
//! - [`crossref`] — Crossref REST JSON
//! - [`ads`] — NASA ADS / SciX REST JSON (bearer token)
//! - [`openalex`] — OpenAlex REST JSON
//!
//! ## Stubbed (port-in-follow-up)
//! - [`pubmed`] — XML / E-Utilities
//! - [`semantic_scholar`] — REST JSON
//! - [`wos`] — Web of Science Lite REST

pub mod ads;
pub mod arxiv;
pub mod crossref;
pub mod error;
pub mod openalex;
pub mod pubmed;
pub mod semantic_scholar;
pub mod types;
pub mod wos;

pub use error::SourceError;
pub use types::{author_from_names, Author, PaperMetadata, SearchQuery, SearchResult};

use async_trait::async_trait;

/// Common interface implemented by every per-source client.
///
/// Mirrors the Swift `SourcePlugin` protocol but with two simplifications:
///
/// 1. Search returns a `SearchResult` page (items + pagination metadata) in
///    one call, rather than a bare item list — the cursor enables TUI-style
///    progressive loading.
/// 2. Credentials are passed in as an `Option<&str>` (API key, bearer token,
///    or email for the polite pool) rather than fetched from a side store.
#[async_trait]
pub trait SourcePlugin: Send + Sync {
    /// Stable identifier (e.g. `"arxiv"`).
    fn id(&self) -> &str;

    /// Human-readable name (e.g. `"arXiv"`).
    fn display_name(&self) -> &str;

    /// Whether `search`/`fetch_by_id` will refuse to run when
    /// `credentials` is `None`. ADS and Web of Science require credentials;
    /// arXiv, Crossref, OpenAlex do not.
    fn requires_credentials(&self) -> bool;

    async fn search(
        &self,
        query: &SearchQuery,
        credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError>;

    async fn fetch_by_id(
        &self,
        id: &str,
        credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError>;
}
