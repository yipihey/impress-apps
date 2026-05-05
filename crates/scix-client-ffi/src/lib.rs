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

#[cfg(feature = "native")]
use reqwest;

#[cfg(feature = "native")]
use serde_json;

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
            // scix_client::types::Library does not expose the permission field;
            // scix_list_libraries parses it directly from the raw JSON response.
            permission: String::new(),
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
///
/// Fetches the raw ADS response to capture the `permission` field, which is not
/// exposed by `scix_client::types::Library`.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_list_libraries(token: String) -> Result<Vec<ScixLibrary>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .map_err(|e| ScixFfiError::Internal { message: e.to_string() })?;

        let response = client
            .get("https://api.adsabs.harvard.edu/v1/biblib/libraries")
            .header("Authorization", format!("Bearer {}", token))
            .header("User-Agent", "scix-client-ffi/0.1")
            .send()
            .await
            .map_err(|e| ScixFfiError::NetworkError { message: e.to_string() })?;

        let status = response.status().as_u16();
        if status == 401 { return Err(ScixFfiError::Unauthorized); }
        if status == 429 { return Err(ScixFfiError::RateLimited); }
        if status == 404 { return Err(ScixFfiError::NotFound); }
        if !(200..=299).contains(&status) {
            return Err(ScixFfiError::ApiError { message: format!("HTTP {}", status) });
        }

        let body = response.text().await
            .map_err(|e| ScixFfiError::NetworkError { message: e.to_string() })?;
        let parsed: serde_json::Value = serde_json::from_str(&body)
            .map_err(|e| ScixFfiError::Internal { message: e.to_string() })?;

        let empty_arr = vec![];
        let libraries = parsed["libraries"]
            .as_array()
            .unwrap_or(&empty_arr)
            .iter()
            .filter_map(|lib| {
                Some(ScixLibrary {
                    id: lib["id"].as_str()?.to_string(),
                    name: lib["name"].as_str().unwrap_or("").to_string(),
                    description: lib["description"].as_str().unwrap_or("").to_string(),
                    num_documents: lib["num_documents"].as_u64().unwrap_or(0) as i32,
                    is_public: lib["public"].as_bool().unwrap_or(false),
                    owner: lib["owner"].as_str().unwrap_or("").to_string(),
                    permission: lib["permission"].as_str().unwrap_or("").to_string(),
                })
            })
            .collect();

        Ok(libraries)
    })
}

/// Get a library's details including its bibcodes.
///
/// Paginates through the ADS `/biblib/libraries/{id}` endpoint to fetch all
/// bibcodes, since the API defaults to returning only 20 per page.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_get_library(
    token: String,
    library_id: String,
) -> Result<ScixLibraryDetail, ScixFfiError> {
    make_runtime()?.block_on(async move {
        let base_url = "https://api.adsabs.harvard.edu/v1";
        let client = reqwest::Client::new();
        let page_size = 500;
        let mut start = 0;
        let mut all_bibcodes: Vec<String> = Vec::new();
        let mut metadata: Option<(String, String, i32, bool, String)> = None;

        loop {
            let url = format!("{}/biblib/libraries/{}", base_url, library_id);
            let resp = client
                .get(&url)
                .header("Authorization", format!("Bearer {}", token))
                .header("User-Agent", "scix-client-ffi/0.3.1")
                .query(&[
                    ("rows", page_size.to_string()),
                    ("start", start.to_string()),
                ])
                .send()
                .await
                .map_err(|e| ScixFfiError::NetworkError { message: e.to_string() })?;

            if !resp.status().is_success() {
                let status = resp.status().as_u16();
                let body = resp.text().await.unwrap_or_default();
                if status == 404 {
                    return Err(ScixFfiError::NotFound);
                }
                return Err(ScixFfiError::ApiError {
                    message: format!("HTTP {}: {}", status, body),
                });
            }

            let body = resp
                .text()
                .await
                .map_err(|e| ScixFfiError::NetworkError { message: e.to_string() })?;
            let parsed: serde_json::Value = serde_json::from_str(&body)
                .map_err(|e| ScixFfiError::Internal { message: format!("Invalid library response: {}", e) })?;

            // Extract metadata from first page
            if metadata.is_none() {
                let m = &parsed["metadata"];
                metadata = Some((
                    m["name"].as_str().unwrap_or("").to_string(),
                    m["description"].as_str().unwrap_or("").to_string(),
                    m["num_documents"].as_u64().unwrap_or(0) as i32,
                    m["public"].as_bool().unwrap_or(false),
                    m["owner"].as_str().unwrap_or("").to_string(),
                ));
            }

            // Extract bibcodes from this page
            let docs: Vec<String> = parsed["documents"]
                .as_array()
                .unwrap_or(&Vec::new())
                .iter()
                .filter_map(|d| d.as_str().map(String::from))
                .collect();

            let page_count = docs.len();
            all_bibcodes.extend(docs);
            start += page_size;

            // Stop when we got fewer than page_size (last page) or reached num_documents
            if page_count < page_size as usize {
                break;
            }
        }

        let (name, description, num_documents, is_public, owner) =
            metadata.unwrap_or_default();

        Ok(ScixLibraryDetail {
            id: library_id,
            name,
            description,
            num_documents,
            is_public,
            owner,
            bibcodes: all_bibcodes,
        })
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

/// Edit a library's metadata (name, description, public status).
///
/// Pass `None` for fields that should not be changed.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_edit_library(
    token: String,
    library_id: String,
    name: Option<String>,
    description: Option<String>,
    is_public: Option<bool>,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .edit_library(
                &library_id,
                name.as_deref(),
                description.as_deref(),
                is_public,
            )
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Get collaborator permissions for a library.
///
/// Returns a list of email/permission pairs for all collaborators.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_get_permissions(
    token: String,
    library_id: String,
) -> Result<Vec<ScixPermission>, ScixFfiError> {
    make_runtime()?.block_on(async move {
        let json = SciXClient::new(&token)
            .get_permissions(&library_id)
            .await
            .map_err(ScixFfiError::from)?;

        // ADS response: { "<key>": [["email", "permission"], ...] }
        // Take the first array value in the object, regardless of key name.
        let empty_arr = vec![];
        let pairs = json
            .as_object()
            .and_then(|obj| obj.values().next())
            .and_then(|v| v.as_array())
            .unwrap_or(&empty_arr);

        let permissions = pairs
            .iter()
            .filter_map(|pair| {
                let arr = pair.as_array()?;
                let email = arr.first()?.as_str()?.to_string();
                let permission = arr.get(1)?.as_str()?.to_string();
                Some(ScixPermission { email, permission })
            })
            .collect();

        Ok(permissions)
    })
}

/// Set (or update) a collaborator's permission level on a library.
///
/// `permission` must be one of: "owner", "admin", "write", "read".
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_update_permission(
    token: String,
    library_id: String,
    email: String,
    permission: String,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .update_permissions(&library_id, &email, &permission)
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Remove a collaborator from a library by setting their permission to "none".
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_remove_permission(
    token: String,
    library_id: String,
    email: String,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .update_permissions(&library_id, &email, "none")
            .await
            .map_err(ScixFfiError::from)
    })
}

/// Transfer ownership of a library to another user.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn scix_transfer_library(
    token: String,
    library_id: String,
    email: String,
) -> Result<(), ScixFfiError> {
    make_runtime()?.block_on(async move {
        SciXClient::new(&token)
            .transfer_library(&library_id, &email)
            .await
            .map_err(ScixFfiError::from)
    })
}
