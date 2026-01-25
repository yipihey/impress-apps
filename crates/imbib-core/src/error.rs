//! FFI error types

/// FFI-safe error type for parsing operations
#[derive(uniffi::Error, Debug, Clone)]
#[uniffi(flat_error)]
pub enum FfiError {
    ParseError { message: String },
}

impl std::fmt::Display for FfiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FfiError::ParseError { message } => write!(f, "{}", message),
        }
    }
}

impl std::error::Error for FfiError {}

impl From<String> for FfiError {
    fn from(s: String) -> Self {
        FfiError::ParseError { message: s }
    }
}
