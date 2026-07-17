//! Error type for `imprint-service`.
//!
//! The variants mirror what the Swift `ImprintHTTPRouter` returns today (status,
//! invalid argument, not found, internal error) so the eventual Phase 3 UniFFI
//! bridge can map cleanly onto Swift `LocalizedError`. This trait conformance
//! is also what the Phase-0 `impress-service-core` `ServiceError` is expected to
//! look like — when that crate stabilises we'll re-export from there instead of
//! hand-rolling this enum.

use std::path::PathBuf;

use thiserror::Error;

/// Domain error for the imprint service layer.
///
/// All public methods of `ManuscriptService` and `DefaultImprintHttpHandlers`
/// return `Result<T, ServiceError>`. Each variant carries a human-readable
/// message that is safe to surface in an HTTP body, an MCP error object, or a
/// CLI stderr message.
#[derive(Debug, Error)]
pub enum ServiceError {
    /// Caller supplied input that failed validation before the request hit the
    /// store (bad UUID, empty section key, oversize payload, …).
    #[error("invalid argument: {0}")]
    InvalidArgument(String),

    /// The requested object does not exist.
    #[error("not found: {0}")]
    NotFound(String),

    /// I/O failure when reading or writing a content-addressed blob.
    #[error("blob I/O error at {path:?}: {source}")]
    BlobIo {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    /// Failure in the underlying shared item store
    /// (`impress-store-ffi::SharedStore` / `impress-core::SqliteItemStore`).
    #[error("store error: {0}")]
    Store(String),

    /// Failure in the search index (tantivy open / index / query).
    #[error("search index error: {0}")]
    Search(String),

    /// Failure to encode/decode the JSON payload for a stored item.
    #[error("serialization error: {0}")]
    Serialization(String),

    /// Catch-all for anything we did not classify explicitly.
    #[error("internal error: {0}")]
    Internal(String),
}

impl ServiceError {
    /// Convenience: build a `Store` variant from anything `Display`-able.
    pub fn store<E: std::fmt::Display>(err: E) -> Self {
        ServiceError::Store(err.to_string())
    }

    /// Convenience: build a `Search` variant from anything `Display`-able.
    pub fn search<E: std::fmt::Display>(err: E) -> Self {
        ServiceError::Search(err.to_string())
    }
}

impl From<serde_json::Error> for ServiceError {
    fn from(e: serde_json::Error) -> Self {
        ServiceError::Serialization(e.to_string())
    }
}

impl From<impress_store_ffi::SharedStoreError> for ServiceError {
    fn from(e: impress_store_ffi::SharedStoreError) -> Self {
        use impress_store_ffi::SharedStoreError as S;
        match e {
            S::NotFound { message } => ServiceError::NotFound(message),
            S::AlreadyExists { message } => {
                ServiceError::Store(format!("already exists: {message}"))
            }
            S::InvalidArgument { message } => ServiceError::InvalidArgument(message),
            S::Storage { message } => ServiceError::Store(message),
        }
    }
}

impl From<uuid::Error> for ServiceError {
    fn from(e: uuid::Error) -> Self {
        ServiceError::InvalidArgument(format!("invalid UUID: {e}"))
    }
}

impl From<tantivy::TantivyError> for ServiceError {
    fn from(e: tantivy::TantivyError) -> Self {
        ServiceError::Search(e.to_string())
    }
}

impl From<tantivy::query::QueryParserError> for ServiceError {
    fn from(e: tantivy::query::QueryParserError) -> Self {
        ServiceError::Search(format!("query parse: {e}"))
    }
}
