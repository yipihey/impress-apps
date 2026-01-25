//! HTTP client abstraction for source plugins

#[cfg(feature = "native")]
pub mod native;

#[cfg(feature = "native")]
pub use native::*;

use thiserror::Error;

#[derive(Error, Debug)]
pub enum HttpError {
    #[error("Request failed: {message}")]
    RequestFailed { message: String },
    #[error("Invalid URL: {url}")]
    InvalidUrl { url: String },
    #[error("Timeout")]
    Timeout,
    #[error("Rate limited")]
    RateLimited,
    #[error("Parse error: {message}")]
    ParseError { message: String },
}

#[derive(Clone, Debug)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    pub headers: std::collections::HashMap<String, String>,
}
