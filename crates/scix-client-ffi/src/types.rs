/// SciX/ADS personal library metadata.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixLibrary {
    pub id: String,
    pub name: String,
    pub description: String,
    pub num_documents: i32,
    pub is_public: bool,
    pub owner: String,
    /// User's permission level: "owner" | "admin" | "write" | "read"
    pub permission: String,
}

/// A collaborator permission entry for a SciX library.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixPermission {
    pub email: String,
    /// Permission level: "owner" | "admin" | "write" | "read"
    pub permission: String,
}

/// SciX/ADS personal library with its bibcodes.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixLibraryDetail {
    pub id: String,
    pub name: String,
    pub description: String,
    pub num_documents: i32,
    pub is_public: bool,
    pub owner: String,
    /// Bibcodes of papers in this library
    pub bibcodes: Vec<String>,
}

/// FFI error type for scix-client operations.
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, thiserror::Error)]
pub enum ScixFfiError {
    #[error("API error: {message}")]
    ApiError { message: String },
    #[error("Network error: {message}")]
    NetworkError { message: String },
    #[error("Authentication required (invalid or missing API token)")]
    Unauthorized,
    #[error("Rate limit exceeded")]
    RateLimited,
    #[error("Not found")]
    NotFound,
    #[error("Internal error: {message}")]
    Internal { message: String },
}
