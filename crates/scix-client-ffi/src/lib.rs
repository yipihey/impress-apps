//! scix-client-ffi: UniFFI bindings for scix-client (NASA ADS/SciX API).
//!
//! Provides async-to-blocking FFI wrappers around the `scix-client` crate,
//! suitable for calling from Swift via UniFFI-generated bindings.
//!
//! All exported functions:
//! - Take an API token as the first argument
//! - Run the underlying async operation using a single-threaded tokio runtime
//! - Return results synchronously (the tokio runtime is created per-call)
//!
//! ## Usage from Swift
//!
//! ```swift
//! import ImpressScixCore
//!
//! // Search for papers
//! let papers = try scixSearch(token: apiKey, query: "dark matter year:2023", maxResults: 50)
//!
//! // Export as BibTeX
//! let bibtex = try scixExportBibtex(token: apiKey, bibcodes: ["2023ApJ...123..456A"])
//! ```

mod types;
pub use types::*;

#[cfg(feature = "native")]
use scix_client::SciXClient;

// Setup UniFFI proc-macro scaffolding (native builds only).
#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

// ─── Conversions ─────────────────────────────────────────────────────────────

#[cfg(feature = "native")]
impl From<scix_client::types::Paper> for ScixPaper {
    fn from(p: scix_client::types::Paper) -> Self {
        let is_open_access = p
            .properties
            .iter()
            .any(|prop| prop == "OPENACCESS" || prop == "EPRINT_OPENACCESS");

        let pdf_links = p
            .pdf_links
            .into_iter()
            .map(|link| ScixPdfLink {
                url: link.url,
                link_type: format!("{:?}", link.link_type),
                label: link.label,
            })
            .collect();

        ScixPaper {
            bibcode: p.bibcode,
            title: p.title,
            authors: p
                .authors
                .into_iter()
                .map(|a| ScixAuthor {
                    name: a.name,
                    family_name: a.family_name,
                    given_name: a.given_name,
                })
                .collect(),
            year: p.year.map(|y| y as i32),
            publication: p.publication,
            doi: p.doi,
            arxiv_id: p.arxiv_id,
            abstract_text: p.abstract_text,
            citation_count: p.citation_count.map(|c| c as i32),
            pdf_links,
            web_url: p.url,
            is_open_access,
            doctype: p.doctype,
        }
    }
}

#[cfg(feature = "native")]
impl From<scix_client::types::Library> for ScixLibrary {
    fn from(l: scix_client::types::Library) -> Self {
        ScixLibrary {
            id: l.id,
            name: l.name,
            description: l.description,
            num_documents: l.num_documents as i32,
            is_public: l.public,
            owner: l.owner,
        }
    }
}

#[cfg(feature = "native")]
impl From<scix_client::SciXError> for ScixFfiError {
    fn from(e: scix_client::SciXError) -> Self {
        let msg = e.to_string();
        if msg.contains("401") || msg.contains("Unauthorized") || msg.contains("unauthorized") {
            ScixFfiError::Unauthorized
        } else if msg.contains("429") || msg.contains("rate limit") || msg.contains("Rate limit") {
            ScixFfiError::RateLimited
        } else if msg.contains("404") || msg.contains("Not found") || msg.contains("not found") {
            ScixFfiError::NotFound
        } else if msg.contains("connection") || msg.contains("network") || msg.contains("reqwest") {
            ScixFfiError::NetworkError { message: msg }
        } else {
            ScixFfiError::ApiError { message: msg }
        }
    }
}

/// Build a single-threaded tokio runtime for blocking FFI calls.
#[cfg(feature = "native")]
fn make_runtime() -> Result<tokio::runtime::Runtime, ScixFfiError> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| ScixFfiError::Internal {
            message: e.to_string(),
        })
}

// ─── Search ───────────────────────────────────────────────────────────────────

/// Get total result count for a query without fetching paper data.
///
/// Uses `rows=0` for a lightweight count-only query — no paper data is returned.
/// Useful for query preview features that show how many results a query would return.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_count(token: String, query: String) -> Result<u32, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .search(&query, 0)
            .await
            .map(|r| r.num_found as u32)
            .map_err(ScixFfiError::from)
    })
}

/// Search NASA ADS / SciX for papers matching a query.
///
/// Supports full ADS query syntax:
/// - `author:"Einstein, A" year:2020-2024 abs:"gravitational waves"`
/// - `title:dark matter property:refereed`
/// - `citations(bibcode:2016PhRvL.116f1102A)`
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_search(
    token: String,
    query: String,
    max_results: u32,
) -> Result<Vec<ScixPaper>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .search(&query, max_results)
            .await
            .map(|r| r.papers.into_iter().map(ScixPaper::from).collect())
            .map_err(ScixFfiError::from)
    })
}

/// Fetch papers that the given paper references (papers it cites).
///
/// Uses ADS `references(bibcode:XXXX)` functional operator.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_fetch_references(
    token: String,
    bibcode: String,
    max_results: u32,
) -> Result<Vec<ScixPaper>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .references(&bibcode, max_results)
            .await
            .map(|r| r.papers.into_iter().map(ScixPaper::from).collect())
            .map_err(ScixFfiError::from)
    })
}

/// Fetch papers that cite the given paper.
///
/// Uses ADS `citations(bibcode:XXXX)` functional operator.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_fetch_citations(
    token: String,
    bibcode: String,
    max_results: u32,
) -> Result<Vec<ScixPaper>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .citations(&bibcode, max_results)
            .await
            .map(|r| r.papers.into_iter().map(ScixPaper::from).collect())
            .map_err(ScixFfiError::from)
    })
}

/// Fetch papers with similar content to the given paper.
///
/// Uses ADS `similar(bibcode:XXXX)` functional operator.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_fetch_similar(
    token: String,
    bibcode: String,
    max_results: u32,
) -> Result<Vec<ScixPaper>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .similar(&bibcode, max_results)
            .await
            .map(|r| r.papers.into_iter().map(ScixPaper::from).collect())
            .map_err(ScixFfiError::from)
    })
}

/// Fetch papers frequently co-read with the given paper.
///
/// Uses ADS `trending(bibcode:XXXX)` functional operator.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_fetch_coreads(
    token: String,
    bibcode: String,
    max_results: u32,
) -> Result<Vec<ScixPaper>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .coreads(&bibcode, max_results)
            .await
            .map(|r| r.papers.into_iter().map(ScixPaper::from).collect())
            .map_err(ScixFfiError::from)
    })
}

// ─── Export ───────────────────────────────────────────────────────────────────

/// Export papers as BibTeX.
///
/// Returns a BibTeX string with entries for all provided bibcodes.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_export_bibtex(
    token: String,
    bibcodes: Vec<String>,
) -> Result<String, ScixFfiError> {
    make_runtime()?.block_on(async move {
        let refs: Vec<&str> = bibcodes.iter().map(String::as_str).collect();
        SciXClient::new(&token)
            .export_bibtex(&refs)
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Export papers as RIS format.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_export_ris(
    token: String,
    bibcodes: Vec<String>,
) -> Result<String, ScixFfiError> {
    use scix_client::types::ExportFormat;
    make_runtime()?.block_on(async move {
        let refs: Vec<&str> = bibcodes.iter().map(String::as_str).collect();
        SciXClient::new(&token)
            .export(&refs, ExportFormat::Ris, None)
            .await
            .map_err(ScixFfiError::from)
    })
}

// ─── Libraries ────────────────────────────────────────────────────────────────

/// List all personal libraries for the authenticated user.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_list_libraries(token: String) -> Result<Vec<ScixLibrary>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .list_libraries()
            .await
            .map(|libs| libs.into_iter().map(ScixLibrary::from).collect())
            .map_err(ScixFfiError::from)
    })
}

/// Get a library's details including its bibcodes.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_get_library(
    token: String,
    library_id: String,
) -> Result<ScixLibraryDetail, ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .get_library(&library_id)
            .await
            .map(|detail| ScixLibraryDetail {
                id: detail.metadata.id,
                name: detail.metadata.name,
                description: detail.metadata.description,
                num_documents: detail.metadata.num_documents as i32,
                is_public: detail.metadata.public,
                owner: detail.metadata.owner,
                bibcodes: detail.documents,
            })
            .map_err(ScixFfiError::from)
    })
}

/// Create a new personal library.
///
/// Returns the ID of the newly created library.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_create_library(
    token: String,
    name: String,
    description: String,
    is_public: bool,
    bibcodes: Vec<String>,
) -> Result<String, ScixFfiError> {
    make_runtime()?.block_on(async move {
        let refs: Vec<&str> = bibcodes.iter().map(String::as_str).collect();
        let refs_opt: Option<&[&str]> = if refs.is_empty() { None } else { Some(&refs) };
        SciXClient::new(&token)
            .create_library(&name, &description, is_public, refs_opt)
            .await
            .map(|lib| lib.id)
            .map_err(ScixFfiError::from)
    })
}

/// Add bibcodes to an existing library.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_add_to_library(
    token: String,
    library_id: String,
    bibcodes: Vec<String>,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        let refs: Vec<&str> = bibcodes.iter().map(String::as_str).collect();
        SciXClient::new(&token)
            .add_documents(&library_id, &refs)
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Remove bibcodes from a library.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_remove_from_library(
    token: String,
    library_id: String,
    bibcodes: Vec<String>,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        let refs: Vec<&str> = bibcodes.iter().map(String::as_str).collect();
        SciXClient::new(&token)
            .remove_documents(&library_id, &refs)
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Delete a library.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_delete_library(
    token: String,
    library_id: String,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .delete_library(&library_id)
            .await
            .map_err(ScixFfiError::from)
    })
}
