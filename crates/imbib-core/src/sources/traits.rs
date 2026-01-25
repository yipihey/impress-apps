//! Common traits for source plugins

#[cfg(feature = "native")]
use crate::http::HttpError;

#[derive(Debug)]
pub enum SourceError {
    #[cfg(feature = "native")]
    Http(HttpError),
    Parse(String),
    RateLimit,
    NotFound,
    InvalidQuery(String),
}

#[cfg(feature = "native")]
impl From<HttpError> for SourceError {
    fn from(e: HttpError) -> Self {
        match e {
            HttpError::RateLimited => SourceError::RateLimit,
            other => SourceError::Http(other),
        }
    }
}

/// Metadata about a source
pub struct SourceMetadata {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub base_url: &'static str,
    pub rate_limit_per_second: f32,
    pub supports_bibtex: bool,
    pub supports_ris: bool,
    pub requires_api_key: bool,
}
