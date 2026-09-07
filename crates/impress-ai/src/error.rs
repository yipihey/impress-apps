use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("invalid AI request: {0}")]
    Invalid(String),
    #[error("oMLX is unavailable: {0}")]
    Omlx(String),
    /// A non-success HTTP status from the provider, with the status kept
    /// STRUCTURED so the task executor can classify it: a 4xx is a
    /// deterministic request problem (no retry will change it), while a
    /// 5xx/408/429 is environmental. Folding both into `Omlx(String)` made
    /// a permanent 400 retry exactly like a connection refusal.
    #[error("oMLX HTTP {status}: {detail}")]
    OmlxStatus { status: u16, detail: String },
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
