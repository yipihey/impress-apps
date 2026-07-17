//! Error type for the HTTP client.

use thiserror::Error;

#[derive(Debug, Error)]
pub enum AppClientError {
    #[error("HTTP request failed: {0}")]
    Transport(#[from] reqwest::Error),

    #[error("URL build failed: {0}")]
    Url(#[from] url::ParseError),

    #[error("response decode failed: {0}")]
    Decode(String),

    #[error("API error: {0}")]
    Api(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("server reachable but reports error: {0}")]
    ServerError(String),

    #[error("UUID could not be resolved to a cite-key (publication may not exist): {0}")]
    UnresolvedUuid(String),

    #[error("invalid argument: {0}")]
    InvalidArgument(String),
}

impl From<serde_json::Error> for AppClientError {
    fn from(e: serde_json::Error) -> Self {
        AppClientError::Decode(e.to_string())
    }
}

pub type Result<T> = std::result::Result<T, AppClientError>;
