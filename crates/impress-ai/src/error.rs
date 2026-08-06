use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid AI request: {0}")]
    Invalid(String),
    #[error("oMLX is unavailable: {0}")]
    Omlx(String),
    #[error("shared store failed: {0}")]
    Store(String),
    #[error("content blob failed: {0}")]
    Blob(String),
    #[error("unsupported content: {0}")]
    UnsupportedContent(String),
    #[error("research context failed: {0}")]
    Web(String),
    #[error("serialization failed: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("HTTP request failed: {0}")]
    Http(#[from] reqwest::Error),
    #[error("I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("legacy database failed: {0}")]
    LegacyDatabase(#[from] rusqlite::Error),
}

impl From<impress_core::store::StoreError> for Error {
    fn from(error: impress_core::store::StoreError) -> Self {
        Self::Store(error.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
