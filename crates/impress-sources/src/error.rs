//! Error types for source clients.

use thiserror::Error;

/// Errors that can occur during a source-plugin operation.
///
/// Mirrors the Swift `SourceError` enum used in
/// `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/Plugin/SourceError.swift`.
#[derive(Debug, Error)]
pub enum SourceError {
    /// HTTP transport failure (DNS, timeout, TLS, etc.)
    #[error("network error: {0}")]
    Network(String),

    /// The server returned a non-success status code.
    #[error("HTTP {status}: {message}")]
    Http { status: u16, message: String },

    /// The request was malformed before transport.
    #[error("invalid request: {0}")]
    InvalidRequest(String),

    /// The response could not be parsed.
    #[error("invalid response: {0}")]
    InvalidResponse(String),

    /// Generic parser failure.
    #[error("parse error: {0}")]
    Parse(String),

    /// Rate limited; caller should back off. `retry_after_secs` from the
    /// `Retry-After` header when available.
    #[error("rate limited (retry after {retry_after_secs:?} s)")]
    RateLimited { retry_after_secs: Option<u64> },

    /// The source required credentials but none were supplied.
    #[error("authentication required for source `{0}`")]
    AuthenticationRequired(String),

    /// 404 or empty result.
    #[error("not found: {0}")]
    NotFound(String),
}

impl From<reqwest::Error> for SourceError {
    fn from(err: reqwest::Error) -> Self {
        if let Some(status) = err.status() {
            if status.as_u16() == 429 {
                return SourceError::RateLimited {
                    retry_after_secs: None,
                };
            }
            return SourceError::Http {
                status: status.as_u16(),
                message: err.to_string(),
            };
        }
        SourceError::Network(err.to_string())
    }
}

impl From<serde_json::Error> for SourceError {
    fn from(err: serde_json::Error) -> Self {
        SourceError::Parse(format!("json: {err}"))
    }
}

impl From<url::ParseError> for SourceError {
    fn from(err: url::ParseError) -> Self {
        SourceError::InvalidRequest(format!("url: {err}"))
    }
}
