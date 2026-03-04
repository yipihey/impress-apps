/// Author info from SciX/ADS API.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixAuthor {
    /// Full formatted name (e.g., "Einstein, Albert")
    pub name: String,
    /// Family/last name
    pub family_name: String,
    /// Given/first name(s)
    pub given_name: Option<String>,
}

/// A PDF or web link associated with a paper.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixPdfLink {
    /// URL of the PDF or landing page
    pub url: String,
    /// Link type: "ArXiv", "Publisher", "AdsScan", "Direct"
    pub link_type: String,
    /// Human-readable label
    pub label: String,
}

/// A paper from the SciX/ADS API.
/// Used for search results, references, citations, similar papers, and co-reads.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct ScixPaper {
    /// ADS bibcode (e.g., "2023ApJ...123..456A")
    pub bibcode: String,
    /// Paper title
    pub title: String,
    /// Authors
    pub authors: Vec<ScixAuthor>,
    /// Publication year
    pub year: Option<i32>,
    /// Journal or publication name
    pub publication: Option<String>,
    /// DOI
    pub doi: Option<String>,
    /// arXiv identifier (e.g., "2301.12345")
    pub arxiv_id: Option<String>,
    /// Abstract text
    pub abstract_text: Option<String>,
    /// Citation count
    pub citation_count: Option<i32>,
    /// PDF and web links
    pub pdf_links: Vec<ScixPdfLink>,
    /// ADS/SciX abstract page URL
    pub web_url: String,
    /// Whether paper is open access
    pub is_open_access: bool,
    /// Document type (e.g., "article", "inproceedings")
    pub doctype: Option<String>,
}

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
