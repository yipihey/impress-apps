# Rust Migration Phase 2: Source Plugins, Query Parsing, and Utilities

You are implementing Phase 2 of the Rust core expansion for imbib. Phase 1 (domain models, import/export, basic ArXiv source) should already be complete. This phase focuses on moving all source plugins, query parsing, and utilities to Rust.

## Project Context

**imbib** is a cross-platform (macOS/iOS) scientific publication manager. The goal is to maximize code sharing for a future web app by moving all platform-agnostic logic to Rust.

**Current State (Post Phase 1):**
- Rust core has: domain models, BibTeX/RIS parsing, import/export, deduplication, basic HTTP client
- Swift still has: all source plugins, query parsing, MathML parser, most utilities

**Target State (Post Phase 2):**
- Rust handles: ALL source plugins, query parsing, MathML, URL parsing
- Swift only: HTTP orchestration (URLSession), UI, Core Data, CloudKit

---

## Phase 2 Implementation

Execute these phases in order. After each phase, run `cargo build && cargo test`.

---

### Phase 2.1: ADS Source Plugin in Rust

The ADS (NASA Astrophysics Data System) plugin is the most complex. It handles JSON responses, multiple query types, and PDF link logic.

**Current Swift:** `PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/ADSSource.swift` (751 lines)

**Create:** `imbib-core/src/sources/ads.rs`

```rust
//! NASA ADS (Astrophysics Data System) source plugin
//!
//! API docs: https://ui.adsabs.harvard.edu/help/api/
//! Rate limit: 5000 requests/day, 5 requests/second burst

use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use crate::http::HttpClient;
use super::traits::{SourceError, SourceMetadata};
use serde::{Deserialize, Serialize};

/// ADS API response wrapper
#[derive(Debug, Deserialize)]
struct ADSResponse {
    response: ADSResponseBody,
}

#[derive(Debug, Deserialize)]
struct ADSResponseBody {
    docs: Vec<ADSDocument>,
    #[serde(rename = "numFound")]
    num_found: Option<u32>,
}

/// Single document from ADS search results
#[derive(Debug, Deserialize)]
struct ADSDocument {
    bibcode: String,
    title: Option<Vec<String>>,
    author: Option<Vec<String>>,
    year: Option<String>,
    #[serde(rename = "pub")]
    publication: Option<String>,
    #[serde(rename = "abstract")]
    abstract_text: Option<String>,
    doi: Option<Vec<String>>,
    identifier: Option<Vec<String>>,
    doctype: Option<String>,
    esources: Option<Vec<String>>,
    citation_count: Option<i32>,
    #[serde(rename = "reference")]
    references: Option<Vec<String>>,
    property: Option<Vec<String>>,
}

/// ADS BibTeX export response
#[derive(Debug, Deserialize)]
struct ADSExportResponse {
    export: String,
}

/// Paper stub for references/citations
#[derive(uniffi::Record, Clone, Debug)]
pub struct PaperStub {
    pub id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub year: Option<i32>,
    pub venue: Option<String>,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub citation_count: Option<i32>,
    pub reference_count: Option<i32>,
    pub is_open_access: bool,
    pub abstract_text: Option<String>,
}

pub struct ADSSource {
    client: HttpClient,
    base_url: String,
}

impl ADSSource {
    pub fn new() -> Self {
        Self {
            client: HttpClient::new("imbib/1.0 (https://imbib.app)"),
            base_url: "https://api.adsabs.harvard.edu/v1".to_string(),
        }
    }

    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "ads",
            name: "NASA ADS",
            description: "Astrophysics Data System for astronomy and physics",
            base_url: "https://ui.adsabs.harvard.edu",
            rate_limit_per_second: 5.0,
            supports_bibtex: true,
            supports_ris: true,
            requires_api_key: true,
        }
    }

    /// Parse ADS JSON response to SearchResults
    pub fn parse_search_response(json: &str) -> Result<Vec<SearchResult>, SourceError> {
        let response: ADSResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid ADS JSON: {}", e)))?;

        Ok(response.response.docs.into_iter()
            .filter_map(|doc| Self::parse_document(doc))
            .collect())
    }

    /// Parse single ADS document to SearchResult
    fn parse_document(doc: ADSDocument) -> Option<SearchResult> {
        let bibcode = doc.bibcode;
        let title = doc.title.and_then(|t| t.into_iter().next()).unwrap_or_default();

        if title.is_empty() {
            return None;
        }

        let authors: Vec<Author> = doc.author.unwrap_or_default()
            .into_iter()
            .map(|name| parse_ads_author(&name))
            .collect();

        let year = doc.year.as_ref().and_then(|y| y.parse().ok());

        let doi = doc.doi.and_then(|d| d.into_iter().next());
        let arxiv_id = extract_arxiv_id_from_identifiers(&doc.identifier);

        let pdf_links = build_pdf_links(
            &doc.esources.unwrap_or_default(),
            doi.as_deref(),
            arxiv_id.as_deref(),
            &bibcode,
        );

        Some(SearchResult {
            source_id: bibcode.clone(),
            source: Source::ADS,
            title,
            authors,
            year,
            identifiers: Identifiers {
                doi,
                arxiv_id,
                bibcode: Some(bibcode.clone()),
                ..Default::default()
            },
            abstract_text: doc.abstract_text,
            journal: doc.publication,
            volume: None,
            pages: None,
            pdf_links,
            bibtex: None,
            url: Some(format!("https://ui.adsabs.harvard.edu/abs/{}", bibcode)),
            citation_count: doc.citation_count,
        })
    }

    /// Parse references/citations response to PaperStubs
    pub fn parse_paper_stubs_response(json: &str) -> Result<Vec<PaperStub>, SourceError> {
        let response: ADSResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid ADS JSON: {}", e)))?;

        Ok(response.response.docs.into_iter()
            .filter_map(|doc| Self::parse_paper_stub(doc))
            .collect())
    }

    fn parse_paper_stub(doc: ADSDocument) -> Option<PaperStub> {
        let title = doc.title.and_then(|t| t.into_iter().next()).unwrap_or_default();
        if title.is_empty() {
            return None;
        }

        let year = doc.year.as_ref().and_then(|y| y.parse().ok());
        let doi = doc.doi.and_then(|d| d.into_iter().next());
        let arxiv_id = extract_arxiv_id_from_identifiers(&doc.identifier);

        let properties = doc.property.unwrap_or_default();
        let is_open_access = properties.iter()
            .any(|p| p == "OPENACCESS" || p == "EPRINT_OPENACCESS");

        Some(PaperStub {
            id: doc.bibcode,
            title,
            authors: doc.author.unwrap_or_default(),
            year,
            venue: doc.publication,
            doi,
            arxiv_id,
            citation_count: doc.citation_count,
            reference_count: doc.references.map(|r| r.len() as i32),
            is_open_access,
            abstract_text: doc.abstract_text,
        })
    }

    /// Parse BibTeX export response
    pub fn parse_bibtex_export(json: &str) -> Result<String, SourceError> {
        let response: ADSExportResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid export response: {}", e)))?;
        Ok(response.export)
    }
}

/// Parse ADS author format "Last, First M." to Author struct
fn parse_ads_author(name: &str) -> Author {
    let parts: Vec<&str> = name.splitn(2, ',').collect();
    if parts.len() == 2 {
        Author {
            id: uuid::Uuid::new_v4().to_string(),
            family_name: parts[0].trim().to_string(),
            given_name: Some(parts[1].trim().to_string()),
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    } else {
        // No comma, try to extract last word as family name
        let words: Vec<&str> = name.split_whitespace().collect();
        if words.len() > 1 {
            Author {
                id: uuid::Uuid::new_v4().to_string(),
                family_name: words.last().unwrap().to_string(),
                given_name: Some(words[..words.len()-1].join(" ")),
                suffix: None,
                orcid: None,
                affiliation: None,
            }
        } else {
            Author::new(name.to_string())
        }
    }
}

/// Extract arXiv ID from ADS identifier array
fn extract_arxiv_id_from_identifiers(identifiers: &Option<Vec<String>>) -> Option<String> {
    identifiers.as_ref()?.iter().find_map(|id| {
        if id.starts_with("arXiv:") {
            Some(id[6..].to_string())
        } else if id.chars().next()?.is_digit(10) && id.contains('.') {
            // New format: 2301.12345
            Some(id.clone())
        } else {
            None
        }
    })
}

/// Build PDF links from ADS esources field
///
/// Priority:
/// 1. Direct arXiv PDF for preprints
/// 2. DOI resolver for publisher
/// 3. ADS scans for historical papers
///
/// Note: We avoid ADS link_gateway URLs as they're unreliable
#[uniffi::export]
pub fn build_pdf_links(
    esources: &[String],
    doi: Option<&str>,
    arxiv_id: Option<&str>,
    bibcode: &str,
) -> Vec<PdfLink> {
    let mut links = Vec::new();
    let mut has_preprint = false;
    let mut has_publisher = false;

    for esource in esources {
        let upper = esource.to_uppercase();

        if upper == "EPRINT_PDF" {
            if let Some(arxiv) = arxiv_id {
                links.push(PdfLink {
                    url: format!("https://arxiv.org/pdf/{}.pdf", arxiv),
                    link_type: PdfLinkType::ArXiv,
                    description: Some("arXiv PDF".to_string()),
                });
                has_preprint = true;
            }
        } else if upper == "PUB_PDF" || upper == "PUB_HTML" {
            if let Some(d) = doi {
                if !d.is_empty() {
                    links.push(PdfLink {
                        url: format!("https://doi.org/{}", d),
                        link_type: PdfLinkType::Publisher,
                        description: Some("Publisher".to_string()),
                    });
                    has_publisher = true;
                }
            }
        } else if upper == "ADS_PDF" || upper == "ADS_SCAN" {
            links.push(PdfLink {
                url: format!("https://articles.adsabs.harvard.edu/pdf/{}", bibcode),
                link_type: PdfLinkType::Direct,
                description: Some("ADS Scan".to_string()),
            });
        }
    }

    // Add fallback links if not already present
    if !has_preprint {
        if let Some(arxiv) = arxiv_id {
            links.push(PdfLink {
                url: format!("https://arxiv.org/pdf/{}.pdf", arxiv),
                link_type: PdfLinkType::ArXiv,
                description: Some("arXiv PDF".to_string()),
            });
        }
    }

    if !has_publisher {
        if let Some(d) = doi {
            if !d.is_empty() {
                links.push(PdfLink {
                    url: format!("https://doi.org/{}", d),
                    link_type: PdfLinkType::Publisher,
                    description: Some("Publisher".to_string()),
                });
            }
        }
    }

    links
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_RESPONSE: &str = r#"{
        "response": {
            "docs": [{
                "bibcode": "2023ApJ...123..456A",
                "title": ["A Great Paper About Stars"],
                "author": ["Author, First", "Researcher, Second"],
                "year": "2023",
                "pub": "The Astrophysical Journal",
                "doi": ["10.3847/1234-5678"],
                "identifier": ["arXiv:2301.12345"],
                "esources": ["EPRINT_PDF", "PUB_PDF"]
            }],
            "numFound": 1
        }
    }"#;

    #[test]
    fn test_parse_search_response() {
        let results = ADSSource::parse_search_response(SAMPLE_RESPONSE).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Great Paper About Stars");
        assert_eq!(results[0].authors.len(), 2);
        assert_eq!(results[0].year, Some(2023));
    }

    #[test]
    fn test_build_pdf_links() {
        let esources = vec!["EPRINT_PDF".to_string(), "PUB_PDF".to_string()];
        let links = build_pdf_links(&esources, Some("10.1234/test"), Some("2301.12345"), "2023ApJ...");

        assert!(links.iter().any(|l| l.url.contains("arxiv.org")));
        assert!(links.iter().any(|l| l.url.contains("doi.org")));
    }
}
```

**Update:** `imbib-core/src/sources/mod.rs`

```rust
pub mod ads;
pub mod arxiv;
pub mod crossref;
pub mod pubmed;
pub mod openalex;
pub mod dblp;
pub mod semantic_scholar;
pub mod traits;

pub use ads::*;
pub use arxiv::*;
pub use crossref::*;
pub use pubmed::*;
pub use openalex::*;
pub use dblp::*;
pub use semantic_scholar::*;
pub use traits::*;
```

**Checkpoint:** Run `cargo build && cargo test`

---

### Phase 2.2: Complete ArXiv Plugin with XML Parsing

ArXiv uses Atom XML format. We need a proper XML parser.

**Add to Cargo.toml:**
```toml
[dependencies]
quick-xml = "0.31"
```

**Update:** `imbib-core/src/sources/arxiv.rs`

```rust
//! arXiv source plugin with XML Atom feed parsing
//!
//! API docs: https://arxiv.org/help/api/user-manual
//! Rate limit: 1 request per 3 seconds

use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use super::traits::{SourceError, SourceMetadata};
use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;
use lazy_static::lazy_static;

lazy_static! {
    static ref ARXIV_NEW_ID: Regex = Regex::new(r"(\d{4}\.\d{4,5})(v\d+)?").unwrap();
    static ref ARXIV_OLD_ID: Regex = Regex::new(r"([a-z-]+/\d{7})").unwrap();
}

pub struct ArxivSource;

impl ArxivSource {
    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "arxiv",
            name: "arXiv",
            description: "Open-access preprint server for physics, math, CS, and more",
            base_url: "https://arxiv.org",
            rate_limit_per_second: 0.33, // 1 per 3 seconds
            supports_bibtex: true,
            supports_ris: false,
            requires_api_key: false,
        }
    }

    /// Build arXiv API query from user query
    ///
    /// Supports field prefixes:
    /// - cat:cs.LG - Category
    /// - au:Author - Author
    /// - ti:Title - Title
    /// - abs:Abstract - Abstract
    /// - id:2301.12345 - arXiv ID
    #[uniffi::export]
    pub fn build_api_query(user_query: &str) -> String {
        let query = user_query.trim();

        // If already has API prefix, use directly
        let api_prefixes = ["all:", "ti:", "au:", "abs:", "co:", "jr:", "cat:", "rn:", "id:"];
        if api_prefixes.iter().any(|p| query.starts_with(p)) {
            return query.to_string();
        }

        // Map user-friendly prefixes to API prefixes
        let mappings = [
            ("category:", "cat:"),
            ("author:", "au:"),
            ("title:", "ti:"),
            ("abstract:", "abs:"),
            ("arxiv:", "id:"),
            ("comment:", "co:"),
            ("journal:", "jr:"),
            ("report:", "rn:"),
        ];

        for (user_prefix, api_prefix) in mappings {
            if query.to_lowercase().starts_with(user_prefix) {
                let value = &query[user_prefix.len()..].trim();
                return format_field_value(api_prefix, value);
            }
        }

        // Handle short prefixes (cat:, au:, ti:, etc.)
        let short_mappings = [
            ("cat:", "cat:"),
            ("au:", "au:"),
            ("ti:", "ti:"),
            ("abs:", "abs:"),
            ("id:", "id:"),
            ("co:", "co:"),
            ("jr:", "jr:"),
            ("rn:", "rn:"),
        ];

        for (prefix, api_prefix) in short_mappings {
            if query.to_lowercase().starts_with(prefix) {
                let value = &query[prefix.len()..].trim();
                return format_field_value(api_prefix, value);
            }
        }

        // Handle AND/OR combinations
        if query.contains(" AND ") {
            let parts: Vec<&str> = query.split(" AND ").collect();
            let transformed: Vec<String> = parts.iter()
                .map(|p| Self::build_api_query(p.trim()))
                .collect();
            return transformed.join(" AND ");
        }

        if query.contains(" OR ") {
            let parts: Vec<&str> = query.split(" OR ").collect();
            let transformed: Vec<String> = parts.iter()
                .map(|p| Self::build_api_query(p.trim()))
                .collect();
            return transformed.join(" OR ");
        }

        // Default: search all fields
        format!("all:{}", query)
    }

    /// Parse arXiv Atom XML feed to SearchResults
    #[uniffi::export]
    pub fn parse_atom_feed(xml: &str) -> Result<Vec<SearchResult>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut results = Vec::new();
        let mut buf = Vec::new();

        // Current entry being parsed
        let mut in_entry = false;
        let mut current_element = String::new();
        let mut entry_id = String::new();
        let mut entry_title = String::new();
        let mut entry_summary = String::new();
        let mut entry_published = String::new();
        let mut entry_doi: Option<String> = None;
        let mut entry_authors: Vec<String> = Vec::new();
        let mut entry_pdf_url: Option<String> = None;
        let mut entry_web_url: Option<String> = None;
        let mut entry_primary_category: Option<String> = None;
        let mut entry_categories: Vec<String> = Vec::new();
        let mut in_author = false;

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    current_element = name.clone();

                    if name == "entry" {
                        in_entry = true;
                        entry_id.clear();
                        entry_title.clear();
                        entry_summary.clear();
                        entry_published.clear();
                        entry_doi = None;
                        entry_authors.clear();
                        entry_pdf_url = None;
                        entry_web_url = None;
                        entry_primary_category = None;
                        entry_categories.clear();
                    } else if name == "author" {
                        in_author = true;
                    } else if name == "link" && in_entry {
                        // Parse link attributes
                        let mut href = None;
                        let mut rel = None;
                        let mut link_type = None;

                        for attr in e.attributes().flatten() {
                            match attr.key.as_ref() {
                                b"href" => href = Some(String::from_utf8_lossy(&attr.value).to_string()),
                                b"rel" => rel = Some(String::from_utf8_lossy(&attr.value).to_string()),
                                b"type" => link_type = Some(String::from_utf8_lossy(&attr.value).to_string()),
                                _ => {}
                            }
                        }

                        if let Some(h) = href {
                            if rel.as_deref() == Some("alternate") {
                                entry_web_url = Some(h);
                            } else if link_type.as_deref() == Some("application/pdf") {
                                entry_pdf_url = Some(h);
                            }
                        }
                    } else if name == "arxiv:primary_category" && in_entry {
                        for attr in e.attributes().flatten() {
                            if attr.key.as_ref() == b"term" {
                                let cat = String::from_utf8_lossy(&attr.value).to_string();
                                entry_primary_category = Some(cat.clone());
                                if !entry_categories.contains(&cat) {
                                    entry_categories.push(cat);
                                }
                            }
                        }
                    } else if name == "category" && in_entry {
                        for attr in e.attributes().flatten() {
                            if attr.key.as_ref() == b"term" {
                                let cat = String::from_utf8_lossy(&attr.value).to_string();
                                if !entry_categories.contains(&cat) {
                                    entry_categories.push(cat);
                                }
                            }
                        }
                    }
                }
                Ok(Event::End(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();

                    if name == "entry" {
                        // Build SearchResult from collected data
                        if let Some(result) = build_search_result(
                            &entry_id,
                            &entry_title,
                            &entry_summary,
                            &entry_published,
                            &entry_authors,
                            entry_doi.as_deref(),
                            entry_pdf_url.as_deref(),
                            entry_web_url.as_deref(),
                            entry_primary_category.as_deref(),
                            &entry_categories,
                        ) {
                            results.push(result);
                        }
                        in_entry = false;
                    } else if name == "author" {
                        in_author = false;
                    }
                    current_element.clear();
                }
                Ok(Event::Text(e)) => {
                    if in_entry {
                        let text = e.unescape().unwrap_or_default().to_string();
                        match current_element.as_str() {
                            "id" => entry_id = text,
                            "title" => entry_title = clean_title(&text),
                            "summary" => entry_summary = text,
                            "published" => entry_published = text,
                            "name" if in_author => entry_authors.push(text),
                            "arxiv:doi" => entry_doi = Some(text),
                            _ => {}
                        }
                    }
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(SourceError::Parse(format!("XML parse error: {}", e))),
                _ => {}
            }
            buf.clear();
        }

        Ok(results)
    }
}

fn format_field_value(prefix: &str, value: &str) -> String {
    let clean = value.trim_matches('"');
    if clean.contains(' ') && !clean.contains(" AND ") && !clean.contains(" OR ") {
        format!("{}\"{}\"", prefix, clean)
    } else {
        format!("{}{}", prefix, clean)
    }
}

fn clean_title(title: &str) -> String {
    title
        .replace('\n', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn build_search_result(
    id: &str,
    title: &str,
    summary: &str,
    published: &str,
    authors: &[String],
    doi: Option<&str>,
    pdf_url: Option<&str>,
    web_url: Option<&str>,
    primary_category: Option<&str>,
    _categories: &[String],
) -> Option<SearchResult> {
    if title.is_empty() {
        return None;
    }

    // Extract arXiv ID from URL
    let arxiv_id = extract_arxiv_id(id);

    // Extract year from published date (YYYY-MM-DDTHH:MM:SSZ)
    let year = published.get(..4).and_then(|y| y.parse().ok());

    // Parse authors
    let parsed_authors: Vec<Author> = authors.iter()
        .map(|name| {
            let parts: Vec<&str> = name.trim().split_whitespace().collect();
            if parts.len() >= 2 {
                Author {
                    id: uuid::Uuid::new_v4().to_string(),
                    given_name: Some(parts[..parts.len()-1].join(" ")),
                    family_name: parts.last().unwrap().to_string(),
                    suffix: None,
                    orcid: None,
                    affiliation: None,
                }
            } else {
                Author::new(name.clone())
            }
        })
        .collect();

    // Build PDF links
    let mut pdf_links = Vec::new();
    if let Some(url) = pdf_url {
        pdf_links.push(PdfLink {
            url: url.to_string(),
            link_type: PdfLinkType::ArXiv,
            description: Some("arXiv PDF".to_string()),
        });
    }

    Some(SearchResult {
        source_id: arxiv_id.clone().unwrap_or_else(|| id.to_string()),
        source: Source::ArXiv,
        title: title.to_string(),
        authors: parsed_authors,
        year,
        identifiers: Identifiers {
            arxiv_id,
            doi: doi.map(String::from),
            ..Default::default()
        },
        abstract_text: if summary.is_empty() { None } else { Some(summary.to_string()) },
        journal: primary_category.map(|c| format!("arXiv:{}", c)),
        volume: None,
        pages: None,
        pdf_links,
        bibtex: None,
        url: web_url.map(String::from),
        citation_count: None,
    })
}

/// Extract arXiv ID from URL or ID string
fn extract_arxiv_id(id: &str) -> Option<String> {
    // New format: 2301.12345
    if let Some(cap) = ARXIV_NEW_ID.captures(id) {
        return Some(cap.get(1).unwrap().as_str().to_string());
    }
    // Old format: hep-th/9901001
    if let Some(cap) = ARXIV_OLD_ID.captures(id) {
        return Some(cap.get(1).unwrap().as_str().to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_api_query() {
        assert_eq!(ArxivSource::build_api_query("machine learning"), "all:machine learning");
        assert_eq!(ArxivSource::build_api_query("cat:cs.LG"), "cat:cs.LG");
        assert_eq!(ArxivSource::build_api_query("author:Einstein"), "au:Einstein");
        assert_eq!(ArxivSource::build_api_query("ti:quantum"), "ti:quantum");
    }

    #[test]
    fn test_extract_arxiv_id() {
        assert_eq!(extract_arxiv_id("http://arxiv.org/abs/2301.12345v1"), Some("2301.12345".to_string()));
        assert_eq!(extract_arxiv_id("hep-th/9901001"), Some("hep-th/9901001".to_string()));
    }

    const SAMPLE_ATOM: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
  <entry>
    <id>http://arxiv.org/abs/2301.12345v1</id>
    <title>A Test Paper About Machine Learning</title>
    <summary>This is the abstract.</summary>
    <published>2023-01-15T00:00:00Z</published>
    <author><name>John Smith</name></author>
    <author><name>Jane Doe</name></author>
    <link href="http://arxiv.org/abs/2301.12345v1" rel="alternate" type="text/html"/>
    <link href="http://arxiv.org/pdf/2301.12345v1" rel="related" type="application/pdf"/>
    <arxiv:primary_category term="cs.LG"/>
  </entry>
</feed>"#;

    #[test]
    fn test_parse_atom_feed() {
        let results = ArxivSource::parse_atom_feed(SAMPLE_ATOM).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Test Paper About Machine Learning");
        assert_eq!(results[0].authors.len(), 2);
        assert_eq!(results[0].identifiers.arxiv_id, Some("2301.12345".to_string()));
    }
}
```

**Checkpoint:** Run `cargo build && cargo test`

---

### Phase 2.3: Crossref Plugin

Crossref is the primary source for DOI metadata.

**Create:** `imbib-core/src/sources/crossref.rs`

```rust
//! Crossref source plugin for DOI metadata
//!
//! API docs: https://api.crossref.org/swagger-ui/index.html
//! Rate limit: Polite pool with email header, ~50 req/sec

use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use super::traits::{SourceError, SourceMetadata};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct CrossrefResponse {
    message: CrossrefMessage,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum CrossrefMessage {
    WorkList(CrossrefWorkList),
    Work(Box<CrossrefWork>),
}

#[derive(Debug, Deserialize)]
struct CrossrefWorkList {
    items: Vec<CrossrefWork>,
}

#[derive(Debug, Deserialize)]
struct CrossrefWork {
    #[serde(rename = "DOI")]
    doi: String,
    title: Option<Vec<String>>,
    author: Option<Vec<CrossrefAuthor>>,
    #[serde(rename = "container-title")]
    container_title: Option<Vec<String>>,
    #[serde(rename = "published-print")]
    published_print: Option<CrossrefDate>,
    #[serde(rename = "published-online")]
    published_online: Option<CrossrefDate>,
    volume: Option<String>,
    page: Option<String>,
    #[serde(rename = "abstract")]
    abstract_text: Option<String>,
    link: Option<Vec<CrossrefLink>>,
    #[serde(rename = "is-referenced-by-count")]
    citation_count: Option<i32>,
    #[serde(rename = "URL")]
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CrossrefAuthor {
    given: Option<String>,
    family: Option<String>,
    #[serde(rename = "ORCID")]
    orcid: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CrossrefDate {
    #[serde(rename = "date-parts")]
    date_parts: Option<Vec<Vec<i32>>>,
}

#[derive(Debug, Deserialize)]
struct CrossrefLink {
    #[serde(rename = "URL")]
    url: String,
    #[serde(rename = "content-type")]
    content_type: Option<String>,
}

pub struct CrossrefSource;

impl CrossrefSource {
    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "crossref",
            name: "Crossref",
            description: "DOI registration agency with metadata for scholarly works",
            base_url: "https://api.crossref.org",
            rate_limit_per_second: 50.0,
            supports_bibtex: false,
            supports_ris: false,
            requires_api_key: false,
        }
    }

    /// Parse Crossref search response
    #[uniffi::export]
    pub fn parse_search_response(json: &str) -> Result<Vec<SearchResult>, SourceError> {
        let response: CrossrefResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid Crossref JSON: {}", e)))?;

        match response.message {
            CrossrefMessage::WorkList(list) => {
                Ok(list.items.into_iter()
                    .filter_map(|w| Self::parse_work(w))
                    .collect())
            }
            CrossrefMessage::Work(work) => {
                Ok(Self::parse_work(*work).into_iter().collect())
            }
        }
    }

    /// Parse single work response (for DOI lookup)
    #[uniffi::export]
    pub fn parse_work_response(json: &str) -> Result<SearchResult, SourceError> {
        let response: CrossrefResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid Crossref JSON: {}", e)))?;

        match response.message {
            CrossrefMessage::Work(work) => {
                Self::parse_work(*work)
                    .ok_or_else(|| SourceError::Parse("Could not parse work".to_string()))
            }
            _ => Err(SourceError::Parse("Unexpected response format".to_string())),
        }
    }

    fn parse_work(work: CrossrefWork) -> Option<SearchResult> {
        let title = work.title.and_then(|t| t.into_iter().next())?;

        let authors: Vec<Author> = work.author.unwrap_or_default()
            .into_iter()
            .filter_map(|a| {
                let family = a.family?;
                Some(Author {
                    id: uuid::Uuid::new_v4().to_string(),
                    family_name: family,
                    given_name: a.given,
                    suffix: None,
                    orcid: a.orcid.map(|o| o.trim_start_matches("http://orcid.org/").to_string()),
                    affiliation: None,
                })
            })
            .collect();

        let year = work.published_print
            .or(work.published_online)
            .and_then(|d| d.date_parts)
            .and_then(|dp| dp.first().cloned())
            .and_then(|parts| parts.first().copied());

        let journal = work.container_title.and_then(|t| t.into_iter().next());

        // Build PDF links
        let mut pdf_links = Vec::new();
        if let Some(links) = work.link {
            for link in links {
                if link.content_type.as_deref() == Some("application/pdf") {
                    pdf_links.push(PdfLink {
                        url: link.url,
                        link_type: PdfLinkType::Publisher,
                        description: Some("Publisher PDF".to_string()),
                    });
                }
            }
        }
        // Always add DOI resolver as fallback
        pdf_links.push(PdfLink {
            url: format!("https://doi.org/{}", work.doi),
            link_type: PdfLinkType::Publisher,
            description: Some("DOI Link".to_string()),
        });

        // Clean abstract (Crossref often includes XML/JATS markup)
        let abstract_text = work.abstract_text.map(|a| strip_jats_markup(&a));

        Some(SearchResult {
            source_id: work.doi.clone(),
            source: Source::Crossref,
            title,
            authors,
            year,
            identifiers: Identifiers {
                doi: Some(work.doi),
                ..Default::default()
            },
            abstract_text,
            journal,
            volume: work.volume,
            pages: work.page,
            pdf_links,
            bibtex: None,
            url: work.url,
            citation_count: work.citation_count,
        })
    }
}

/// Strip JATS XML markup from Crossref abstracts
fn strip_jats_markup(text: &str) -> String {
    // Remove <jats:p>, <jats:italic>, etc.
    let re = regex::Regex::new(r"</?jats:[^>]+>").unwrap();
    let cleaned = re.replace_all(text, "");
    cleaned.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_RESPONSE: &str = r#"{
        "message": {
            "items": [{
                "DOI": "10.1234/test",
                "title": ["A Test Paper"],
                "author": [{"given": "John", "family": "Smith"}],
                "container-title": ["Test Journal"],
                "published-print": {"date-parts": [[2023, 1, 15]]},
                "is-referenced-by-count": 42
            }]
        }
    }"#;

    #[test]
    fn test_parse_search_response() {
        let results = CrossrefSource::parse_search_response(SAMPLE_RESPONSE).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Test Paper");
        assert_eq!(results[0].identifiers.doi, Some("10.1234/test".to_string()));
        assert_eq!(results[0].citation_count, Some(42));
    }
}
```

---

### Phase 2.4: PubMed Plugin

**Create:** `imbib-core/src/sources/pubmed.rs`

```rust
//! PubMed source plugin for biomedical literature
//!
//! API docs: https://www.ncbi.nlm.nih.gov/books/NBK25501/
//! Rate limit: 3 requests/second without API key, 10 with key

use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use super::traits::{SourceError, SourceMetadata};
use quick_xml::events::Event;
use quick_xml::Reader;

pub struct PubMedSource;

impl PubMedSource {
    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "pubmed",
            name: "PubMed",
            description: "Biomedical literature from MEDLINE and life science journals",
            base_url: "https://pubmed.ncbi.nlm.nih.gov",
            rate_limit_per_second: 3.0,
            supports_bibtex: false,
            supports_ris: true,
            requires_api_key: false, // Optional but recommended
        }
    }

    /// Parse PubMed XML response (efetch format)
    #[uniffi::export]
    pub fn parse_efetch_response(xml: &str) -> Result<Vec<SearchResult>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut results = Vec::new();
        let mut buf = Vec::new();

        let mut in_article = false;
        let mut current_element = String::new();
        let mut pmid = String::new();
        let mut title = String::new();
        let mut abstract_text = String::new();
        let mut journal = String::new();
        let mut volume = String::new();
        let mut pages = String::new();
        let mut year: Option<i32> = None;
        let mut doi: Option<String> = None;
        let mut authors: Vec<Author> = Vec::new();
        let mut current_author_last = String::new();
        let mut current_author_first = String::new();
        let mut in_author = false;

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    current_element = name.clone();

                    if name == "PubmedArticle" {
                        in_article = true;
                        pmid.clear();
                        title.clear();
                        abstract_text.clear();
                        journal.clear();
                        volume.clear();
                        pages.clear();
                        year = None;
                        doi = None;
                        authors.clear();
                    } else if name == "Author" {
                        in_author = true;
                        current_author_last.clear();
                        current_author_first.clear();
                    }
                }
                Ok(Event::End(ref e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();

                    if name == "PubmedArticle" && in_article {
                        if !title.is_empty() {
                            let mut pdf_links = Vec::new();

                            // PubMed Central link if available
                            pdf_links.push(PdfLink {
                                url: format!("https://pubmed.ncbi.nlm.nih.gov/{}/", pmid),
                                link_type: PdfLinkType::Landing,
                                description: Some("PubMed".to_string()),
                            });

                            if let Some(ref d) = doi {
                                pdf_links.push(PdfLink {
                                    url: format!("https://doi.org/{}", d),
                                    link_type: PdfLinkType::Publisher,
                                    description: Some("Publisher".to_string()),
                                });
                            }

                            results.push(SearchResult {
                                source_id: pmid.clone(),
                                source: Source::PubMed,
                                title: title.clone(),
                                authors: authors.clone(),
                                year,
                                identifiers: Identifiers {
                                    pmid: Some(pmid.clone()),
                                    doi: doi.clone(),
                                    ..Default::default()
                                },
                                abstract_text: if abstract_text.is_empty() { None } else { Some(abstract_text.clone()) },
                                journal: if journal.is_empty() { None } else { Some(journal.clone()) },
                                volume: if volume.is_empty() { None } else { Some(volume.clone()) },
                                pages: if pages.is_empty() { None } else { Some(pages.clone()) },
                                pdf_links,
                                bibtex: None,
                                url: Some(format!("https://pubmed.ncbi.nlm.nih.gov/{}/", pmid)),
                                citation_count: None,
                            });
                        }
                        in_article = false;
                    } else if name == "Author" && in_author {
                        if !current_author_last.is_empty() {
                            authors.push(Author {
                                id: uuid::Uuid::new_v4().to_string(),
                                family_name: current_author_last.clone(),
                                given_name: if current_author_first.is_empty() { None } else { Some(current_author_first.clone()) },
                                suffix: None,
                                orcid: None,
                                affiliation: None,
                            });
                        }
                        in_author = false;
                    }
                    current_element.clear();
                }
                Ok(Event::Text(e)) => {
                    if in_article {
                        let text = e.unescape().unwrap_or_default().to_string();
                        match current_element.as_str() {
                            "PMID" if pmid.is_empty() => pmid = text,
                            "ArticleTitle" => title = text,
                            "AbstractText" => {
                                if !abstract_text.is_empty() {
                                    abstract_text.push(' ');
                                }
                                abstract_text.push_str(&text);
                            }
                            "Title" if journal.is_empty() => journal = text, // Journal title
                            "Volume" => volume = text,
                            "MedlinePgn" => pages = text,
                            "Year" if year.is_none() => year = text.parse().ok(),
                            "LastName" if in_author => current_author_last = text,
                            "ForeName" if in_author => current_author_first = text,
                            "ArticleId" => {
                                // Check if this is DOI (need to check attribute)
                                if text.starts_with("10.") {
                                    doi = Some(text);
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(SourceError::Parse(format!("XML parse error: {}", e))),
                _ => {}
            }
            buf.clear();
        }

        Ok(results)
    }

    /// Parse esearch response to get PMIDs
    #[uniffi::export]
    pub fn parse_esearch_response(xml: &str) -> Result<Vec<String>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut pmids = Vec::new();
        let mut buf = Vec::new();
        let mut in_id = false;

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    if e.name().as_ref() == b"Id" {
                        in_id = true;
                    }
                }
                Ok(Event::End(ref e)) => {
                    if e.name().as_ref() == b"Id" {
                        in_id = false;
                    }
                }
                Ok(Event::Text(e)) if in_id => {
                    let text = e.unescape().unwrap_or_default().to_string();
                    pmids.push(text);
                }
                Ok(Event::Eof) => break,
                Err(e) => return Err(SourceError::Parse(format!("XML parse error: {}", e))),
                _ => {}
            }
            buf.clear();
        }

        Ok(pmids)
    }
}
```

---

### Phase 2.5: Query Parsing in Rust

Move the regex-based query parsing from SearchViewModel to Rust.

**Create:** `imbib-core/src/query/mod.rs`

```rust
//! Query parsing and building for ADS and arXiv

pub mod parser;
pub mod builder;

pub use parser::*;
pub use builder::*;
```

**Create:** `imbib-core/src/query/parser.rs`

```rust
//! Parse ADS/arXiv query strings back to form fields

use regex::Regex;
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};

lazy_static! {
    static ref AUTHOR_PATTERN: Regex = Regex::new(r#"author:"([^"]+)""#).unwrap();
    static ref OBJECT_PATTERN: Regex = Regex::new(r#"object:"([^"]+)""#).unwrap();
    static ref TITLE_PATTERN: Regex = Regex::new(r#"title:(\([^)]+\)|[^\s]+)"#).unwrap();
    static ref ABS_PATTERN: Regex = Regex::new(r#"abs:(\([^)]+\)|[^\s]+)"#).unwrap();
    static ref YEAR_PATTERN: Regex = Regex::new(r#"year:(\d{4})?-?(\d{4})?"#).unwrap();
    static ref COLLECTION_PATTERN: Regex = Regex::new(r#"collection:(astronomy|physics)"#).unwrap();
    static ref BIBCODE_PATTERN: Regex = Regex::new(r#"bibcode:([^\s]+)"#).unwrap();
    static ref DOI_PATTERN: Regex = Regex::new(r#"doi:([^\s]+)"#).unwrap();
    static ref ARXIV_PATTERN: Regex = Regex::new(r#"arXiv:([^\s]+)"#).unwrap();
    static ref CAT_PATTERN: Regex = Regex::new(r#"cat:([^\s()]+)"#).unwrap();
    static ref DATE_RANGE_PATTERN: Regex = Regex::new(r#"submittedDate:\[(\d+|\*) TO (\d+|\*)\]"#).unwrap();
}

/// Logic operator for multi-term queries
#[derive(uniffi::Enum, Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub enum QueryLogic {
    #[default]
    And,
    Or,
}

/// ADS database selection
#[derive(uniffi::Enum, Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub enum ADSDatabase {
    #[default]
    All,
    Astronomy,
    Physics,
    ArXiv,
}

/// Parsed ADS Classic form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedClassicForm {
    pub authors: String,
    pub objects: String,
    pub title_words: String,
    pub title_logic: QueryLogic,
    pub abstract_words: String,
    pub abstract_logic: QueryLogic,
    pub year_from: Option<i32>,
    pub year_to: Option<i32>,
    pub database: ADSDatabase,
    pub refereed_only: bool,
    pub articles_only: bool,
}

/// Parsed ADS Paper form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedPaperForm {
    pub bibcode: String,
    pub doi: String,
    pub arxiv_id: String,
}

/// Parsed arXiv form state
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct ParsedArXivForm {
    pub search_terms: Vec<ParsedArXivTerm>,
    pub categories: Vec<String>,
    pub date_from: Option<String>,
    pub date_to: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ParsedArXivTerm {
    pub term: String,
    pub field: String,
    pub logic: String,
}

/// Try to parse an ADS query back to classic form fields
#[uniffi::export]
pub fn parse_classic_query(query: &str) -> Option<ParsedClassicForm> {
    let mut state = ParsedClassicForm::default();
    let mut has_content = false;

    // Extract authors
    for cap in AUTHOR_PATTERN.captures_iter(query) {
        if let Some(m) = cap.get(1) {
            if !state.authors.is_empty() {
                state.authors.push('\n');
            }
            state.authors.push_str(m.as_str());
            has_content = true;
        }
    }

    // Extract objects
    if let Some(cap) = OBJECT_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.objects = m.as_str().to_string();
            has_content = true;
        }
    }

    // Extract title
    if let Some(cap) = TITLE_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            let title_part = m.as_str();
            state.title_words = clean_query_part(title_part);
            if title_part.contains(" OR ") {
                state.title_logic = QueryLogic::Or;
            }
            has_content = true;
        }
    }

    // Extract abstract
    if let Some(cap) = ABS_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            let abs_part = m.as_str();
            state.abstract_words = clean_query_part(abs_part);
            if abs_part.contains(" OR ") {
                state.abstract_logic = QueryLogic::Or;
            }
            has_content = true;
        }
    }

    // Extract year range
    if let Some(cap) = YEAR_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.year_from = m.as_str().parse().ok();
            has_content = true;
        }
        if let Some(m) = cap.get(2) {
            state.year_to = m.as_str().parse().ok();
            has_content = true;
        }
    }

    // Extract collection/database
    if let Some(cap) = COLLECTION_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.database = match m.as_str() {
                "astronomy" => ADSDatabase::Astronomy,
                "physics" => ADSDatabase::Physics,
                _ => ADSDatabase::All,
            };
            has_content = true;
        }
    }

    // Check for property flags
    if query.contains("property:eprint") {
        state.database = ADSDatabase::ArXiv;
        has_content = true;
    }
    if query.contains("property:refereed") {
        state.refereed_only = true;
    }
    if query.contains("doctype:article") {
        state.articles_only = true;
    }

    if has_content { Some(state) } else { None }
}

/// Try to parse an ADS query to paper form fields
#[uniffi::export]
pub fn parse_paper_query(query: &str) -> Option<ParsedPaperForm> {
    let mut state = ParsedPaperForm::default();
    let mut has_match = false;

    if let Some(cap) = BIBCODE_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.bibcode = m.as_str().to_string();
            has_match = true;
        }
    }

    if let Some(cap) = DOI_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.doi = m.as_str().to_string();
            has_match = true;
        }
    }

    if let Some(cap) = ARXIV_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            state.arxiv_id = m.as_str().to_string();
            has_match = true;
        }
    }

    // Paper form queries should only contain identifiers
    let mut cleaned = query.to_string();
    cleaned = BIBCODE_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = DOI_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = ARXIV_PATTERN.replace_all(&cleaned, "").to_string();
    cleaned = cleaned.replace(" OR ", "").trim().to_string();

    if !cleaned.is_empty() {
        return None; // Has non-identifier content
    }

    if has_match { Some(state) } else { None }
}

/// Try to parse an arXiv query back to form fields
#[uniffi::export]
pub fn parse_arxiv_query(query: &str) -> Option<ParsedArXivForm> {
    let mut state = ParsedArXivForm::default();

    // Check if this looks like an arXiv query
    let has_category = query.contains("cat:");
    let has_arxiv_fields = ["ti:", "au:", "abs:", "co:", "jr:", "rn:", "id:", "submittedDate:"]
        .iter()
        .any(|f| query.contains(f));

    if !has_category && !has_arxiv_fields {
        return None;
    }

    // Parse categories
    for cap in CAT_PATTERN.captures_iter(query) {
        if let Some(m) = cap.get(1) {
            state.categories.push(m.as_str().to_string());
        }
    }

    // Parse date range
    if let Some(cap) = DATE_RANGE_PATTERN.captures(query) {
        if let Some(m) = cap.get(1) {
            let from = m.as_str();
            if from != "*" {
                state.date_from = Some(from.to_string());
            }
        }
        if let Some(m) = cap.get(2) {
            let to = m.as_str();
            if to != "*" {
                state.date_to = Some(to.to_string());
            }
        }
    }

    // Parse search terms (simplified)
    let remaining = query
        .replace(&*CAT_PATTERN.replace_all(query, "").to_string(), "")
        .replace(&*DATE_RANGE_PATTERN.replace_all(query, "").to_string(), "");

    let field_prefixes = [
        ("ti:", "title"),
        ("au:", "author"),
        ("abs:", "abstract"),
        ("co:", "comments"),
        ("jr:", "journal"),
        ("rn:", "report"),
        ("id:", "arxiv_id"),
        ("doi:", "doi"),
        ("all:", "all"),
    ];

    for part in remaining.split_whitespace() {
        if part == "AND" || part == "OR" || part == "ANDNOT" {
            continue;
        }

        let mut field = "all".to_string();
        let mut value = part.to_string();

        for (prefix, field_name) in &field_prefixes {
            if part.to_lowercase().starts_with(prefix) {
                field = field_name.to_string();
                value = part[prefix.len()..].trim_matches('"').to_string();
                break;
            }
        }

        if !value.is_empty() {
            state.search_terms.push(ParsedArXivTerm {
                term: value,
                field,
                logic: "AND".to_string(),
            });
        }
    }

    Some(state)
}

fn clean_query_part(part: &str) -> String {
    part.replace('(', "")
        .replace(')', "")
        .replace(" AND ", " ")
        .replace(" OR ", " ")
        .trim()
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_classic_query() {
        let query = r#"author:"Einstein, A." title:(relativity theory) year:1905-1920"#;
        let parsed = parse_classic_query(query).unwrap();
        assert_eq!(parsed.authors, "Einstein, A.");
        assert!(parsed.title_words.contains("relativity"));
        assert_eq!(parsed.year_from, Some(1905));
        assert_eq!(parsed.year_to, Some(1920));
    }

    #[test]
    fn test_parse_paper_query() {
        let query = "bibcode:2023ApJ...123..456A doi:10.1234/test";
        let parsed = parse_paper_query(query).unwrap();
        assert_eq!(parsed.bibcode, "2023ApJ...123..456A");
        assert_eq!(parsed.doi, "10.1234/test");
    }

    #[test]
    fn test_parse_arxiv_query() {
        let query = "cat:cs.LG au:Smith ti:machine learning";
        let parsed = parse_arxiv_query(query).unwrap();
        assert!(parsed.categories.contains(&"cs.LG".to_string()));
        assert_eq!(parsed.search_terms.len(), 3);
    }
}
```

**Update `src/lib.rs`:**
```rust
pub mod query;
pub use query::*;
```

---

### Phase 2.6: MathML Parser in Rust

**Create:** `imbib-core/src/text/mathml.rs`

```rust
//! MathML parser for scientific abstracts

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashMap;

lazy_static! {
    static ref INLINE_FORMULA: Regex = Regex::new(r"(?is)<inline-formula[^>]*>(.*?)</inline-formula>").unwrap();
    static ref MML_MATH: Regex = Regex::new(r"(?is)<mml:math[^>]*>(.*?)</mml:math>").unwrap();
    static ref MML_MSUP: Regex = Regex::new(r"(?is)<mml:msup[^>]*>(.*?)</mml:msup>").unwrap();
    static ref MML_MSUB: Regex = Regex::new(r"(?is)<mml:msub[^>]*>(.*?)</mml:msub>").unwrap();
    static ref MML_TAG: Regex = Regex::new(r"(?i)</?mml:[a-z]+[^>]*>").unwrap();

    static ref SUPERSCRIPT_MAP: HashMap<char, char> = {
        let mut m = HashMap::new();
        m.insert('0', '⁰'); m.insert('1', '¹'); m.insert('2', '²');
        m.insert('3', '³'); m.insert('4', '⁴'); m.insert('5', '⁵');
        m.insert('6', '⁶'); m.insert('7', '⁷'); m.insert('8', '⁸');
        m.insert('9', '⁹'); m.insert('+', '⁺'); m.insert('-', '⁻');
        m.insert('=', '⁼'); m.insert('(', '⁽'); m.insert(')', '⁾');
        m.insert('n', 'ⁿ'); m.insert('i', 'ⁱ'); m.insert('a', 'ᵃ');
        m.insert('b', 'ᵇ'); m.insert('c', 'ᶜ'); m.insert('d', 'ᵈ');
        m.insert('e', 'ᵉ'); m.insert('f', 'ᶠ'); m.insert('g', 'ᵍ');
        m.insert('h', 'ʰ'); m.insert('j', 'ʲ'); m.insert('k', 'ᵏ');
        m.insert('l', 'ˡ'); m.insert('m', 'ᵐ'); m.insert('o', 'ᵒ');
        m.insert('p', 'ᵖ'); m.insert('r', 'ʳ'); m.insert('s', 'ˢ');
        m.insert('t', 'ᵗ'); m.insert('u', 'ᵘ'); m.insert('v', 'ᵛ');
        m.insert('w', 'ʷ'); m.insert('x', 'ˣ'); m.insert('y', 'ʸ');
        m.insert('z', 'ᶻ');
        m
    };

    static ref SUBSCRIPT_MAP: HashMap<char, char> = {
        let mut m = HashMap::new();
        m.insert('0', '₀'); m.insert('1', '₁'); m.insert('2', '₂');
        m.insert('3', '₃'); m.insert('4', '₄'); m.insert('5', '₅');
        m.insert('6', '₆'); m.insert('7', '₇'); m.insert('8', '₈');
        m.insert('9', '₉'); m.insert('+', '₊'); m.insert('-', '₋');
        m.insert('=', '₌'); m.insert('(', '₍'); m.insert(')', '₎');
        m.insert('a', 'ₐ'); m.insert('e', 'ₑ'); m.insert('h', 'ₕ');
        m.insert('i', 'ᵢ'); m.insert('j', 'ⱼ'); m.insert('k', 'ₖ');
        m.insert('l', 'ₗ'); m.insert('m', 'ₘ'); m.insert('n', 'ₙ');
        m.insert('o', 'ₒ'); m.insert('p', 'ₚ'); m.insert('r', 'ᵣ');
        m.insert('s', 'ₛ'); m.insert('t', 'ₜ'); m.insert('u', 'ᵤ');
        m.insert('v', 'ᵥ'); m.insert('x', 'ₓ');
        m
    };
}

/// Parse MathML and convert to readable Unicode text
#[uniffi::export]
pub fn parse_mathml(text: &str) -> String {
    let mut result = text.to_string();

    // Process inline-formula tags
    result = INLINE_FORMULA.replace_all(&result, |caps: &regex::Captures| {
        let content = &caps[1];
        parse_mathml_content(content)
    }).to_string();

    // Process standalone mml:math tags
    result = MML_MATH.replace_all(&result, |caps: &regex::Captures| {
        let content = &caps[1];
        parse_mathml_content(content)
    }).to_string();

    result
}

fn parse_mathml_content(content: &str) -> String {
    let mut result = content.to_string();

    // Process superscripts (msup) - iterate until none left (handles nesting)
    while MML_MSUP.is_match(&result) {
        result = MML_MSUP.replace_all(&result, |caps: &regex::Captures| {
            let inner = &caps[1];
            let (base, sup) = extract_two_children(inner);
            let base_text = strip_mml_tags(&base);
            let sup_text = to_superscript(&strip_mml_tags(&sup));
            format!("{}{}", base_text, sup_text)
        }).to_string();
    }

    // Process subscripts (msub)
    while MML_MSUB.is_match(&result) {
        result = MML_MSUB.replace_all(&result, |caps: &regex::Captures| {
            let inner = &caps[1];
            let (base, sub) = extract_two_children(inner);
            let base_text = strip_mml_tags(&base);
            let sub_text = to_subscript(&strip_mml_tags(&sub));
            format!("{}{}", base_text, sub_text)
        }).to_string();
    }

    // Strip remaining MathML tags
    result = strip_mml_tags(&result);

    // Normalize whitespace
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_mml_tags(text: &str) -> String {
    MML_TAG.replace_all(text, "").to_string()
}

fn extract_two_children(content: &str) -> (String, String) {
    // Simple extraction: find first two top-level elements
    // This is a simplified version - a full implementation would use proper XML parsing
    let trimmed = content.trim();

    // Try to find opening tags
    let parts: Vec<&str> = trimmed.splitn(3, |c| c == '<' || c == '>').collect();
    if parts.len() >= 2 {
        // Just split roughly in half for simple cases
        let mid = trimmed.len() / 2;
        (trimmed[..mid].to_string(), trimmed[mid..].to_string())
    } else {
        (trimmed.to_string(), String::new())
    }
}

fn to_superscript(text: &str) -> String {
    text.chars()
        .map(|c| {
            SUPERSCRIPT_MAP.get(&c.to_ascii_lowercase())
                .copied()
                .unwrap_or(c)
        })
        .collect()
}

fn to_subscript(text: &str) -> String {
    text.chars()
        .map(|c| {
            SUBSCRIPT_MAP.get(&c.to_ascii_lowercase())
                .copied()
                .unwrap_or(c)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_simple_mathml() {
        let input = "<inline-formula><mml:math><mml:mi>S</mml:mi><mml:mo>/</mml:mo><mml:mi>N</mml:mi></mml:math></inline-formula>";
        let result = parse_mathml(input);
        assert_eq!(result.trim(), "S/N");
    }

    #[test]
    fn test_to_superscript() {
        assert_eq!(to_superscript("2"), "²");
        assert_eq!(to_superscript("10"), "¹⁰");
    }

    #[test]
    fn test_to_subscript() {
        assert_eq!(to_subscript("2"), "₂");
        assert_eq!(to_subscript("H2O"), "H₂O");
    }
}
```

**Update:** `imbib-core/src/text/mod.rs`

```rust
pub mod mathml;
pub mod author_parser;
pub mod latex_decoder;
// ... existing modules

pub use mathml::*;
```

---

### Phase 2.7: URL Command Parser

**Create:** `imbib-core/src/automation/mod.rs`

```rust
//! URL scheme and command parsing for imbib:// URLs

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum URLCommand {
    Search { query: String, source: Option<String> },
    Import { bibtex: Option<String>, doi: Option<String>, arxiv: Option<String> },
    Open { cite_key: String },
    Export { cite_keys: Vec<String>, format: String },
    AddToCollection { cite_key: String, collection: String },
    Unknown,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ParsedURL {
    pub command: URLCommand,
    pub parameters: HashMap<String, String>,
}

/// Parse an imbib:// URL into a command
#[uniffi::export]
pub fn parse_imbib_url(url: &str) -> Option<ParsedURL> {
    // Expected format: imbib://command?param1=value1&param2=value2

    let without_scheme = url.strip_prefix("imbib://")?;

    let (path, query) = if let Some(pos) = without_scheme.find('?') {
        (&without_scheme[..pos], Some(&without_scheme[pos+1..]))
    } else {
        (without_scheme, None)
    };

    // Parse query parameters
    let mut params: HashMap<String, String> = HashMap::new();
    if let Some(q) = query {
        for pair in q.split('&') {
            if let Some(pos) = pair.find('=') {
                let key = &pair[..pos];
                let value = urlencoding::decode(&pair[pos+1..])
                    .unwrap_or_else(|_| pair[pos+1..].into())
                    .to_string();
                params.insert(key.to_string(), value);
            }
        }
    }

    let command = match path {
        "search" => {
            let query = params.get("q").or(params.get("query")).cloned().unwrap_or_default();
            let source = params.get("source").cloned();
            URLCommand::Search { query, source }
        }
        "import" => {
            URLCommand::Import {
                bibtex: params.get("bibtex").cloned(),
                doi: params.get("doi").cloned(),
                arxiv: params.get("arxiv").cloned(),
            }
        }
        "open" => {
            let cite_key = params.get("key").or(params.get("cite_key")).cloned().unwrap_or_default();
            URLCommand::Open { cite_key }
        }
        "export" => {
            let keys = params.get("keys")
                .map(|k| k.split(',').map(String::from).collect())
                .unwrap_or_default();
            let format = params.get("format").cloned().unwrap_or_else(|| "bibtex".to_string());
            URLCommand::Export { cite_keys: keys, format }
        }
        "add-to-collection" => {
            let cite_key = params.get("key").cloned().unwrap_or_default();
            let collection = params.get("collection").cloned().unwrap_or_default();
            URLCommand::AddToCollection { cite_key, collection }
        }
        _ => URLCommand::Unknown,
    };

    Some(ParsedURL {
        command,
        parameters: params,
    })
}

/// Build an imbib:// URL from a command
#[uniffi::export]
pub fn build_imbib_url(command: &URLCommand) -> String {
    match command {
        URLCommand::Search { query, source } => {
            let mut url = format!("imbib://search?q={}", urlencoding::encode(query));
            if let Some(s) = source {
                url.push_str(&format!("&source={}", urlencoding::encode(s)));
            }
            url
        }
        URLCommand::Import { bibtex, doi, arxiv } => {
            let mut parts = vec!["imbib://import?".to_string()];
            let mut params = Vec::new();
            if let Some(b) = bibtex {
                params.push(format!("bibtex={}", urlencoding::encode(b)));
            }
            if let Some(d) = doi {
                params.push(format!("doi={}", urlencoding::encode(d)));
            }
            if let Some(a) = arxiv {
                params.push(format!("arxiv={}", urlencoding::encode(a)));
            }
            parts.push(params.join("&"));
            parts.join("")
        }
        URLCommand::Open { cite_key } => {
            format!("imbib://open?key={}", urlencoding::encode(cite_key))
        }
        URLCommand::Export { cite_keys, format } => {
            format!("imbib://export?keys={}&format={}",
                urlencoding::encode(&cite_keys.join(",")),
                urlencoding::encode(format))
        }
        URLCommand::AddToCollection { cite_key, collection } => {
            format!("imbib://add-to-collection?key={}&collection={}",
                urlencoding::encode(cite_key),
                urlencoding::encode(collection))
        }
        URLCommand::Unknown => "imbib://".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_search_url() {
        let url = "imbib://search?q=machine%20learning&source=arxiv";
        let parsed = parse_imbib_url(url).unwrap();

        if let URLCommand::Search { query, source } = parsed.command {
            assert_eq!(query, "machine learning");
            assert_eq!(source, Some("arxiv".to_string()));
        } else {
            panic!("Expected Search command");
        }
    }

    #[test]
    fn test_build_url() {
        let cmd = URLCommand::Search {
            query: "quantum computing".to_string(),
            source: None
        };
        let url = build_imbib_url(&cmd);
        assert!(url.contains("imbib://search"));
        assert!(url.contains("quantum%20computing"));
    }
}
```

**Add dependency to Cargo.toml:**
```toml
urlencoding = "2"
```

**Update `src/lib.rs`:**
```rust
pub mod automation;
pub use automation::*;
```

---

### Phase 2.8: Update Swift Bridge

After all Rust changes, regenerate Swift bindings:

```bash
cd imbib-core
cargo build --release

# Generate Swift bindings
cargo run --bin uniffi-bindgen generate \
    --library target/release/libimbib_core.dylib \
    --language swift \
    --out-dir ../ImbibRustCore/Sources/ImbibRustCore/

# Rebuild XCFramework for macOS and iOS
./build-xcframework.sh
```

---

### Phase 2.9: Swift Integration - Update Source Plugins

**Update:** `PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/ADSSource.swift`

Keep the Swift actor for HTTP orchestration but delegate parsing to Rust:

```swift
// In parseResponse, use Rust parser:
private func parseResponse(_ data: Data) throws -> [SearchResult] {
    guard let json = String(data: data, encoding: .utf8) else {
        throw SourceError.parseError("Invalid encoding")
    }

    #if canImport(ImbibRustCore)
    import ImbibRustCore

    // Use Rust parser
    let rustResults = try ADSSource.parseSearchResponse(json: json)
    return rustResults.map { $0.toSwiftSearchResult() }
    #else
    // Fallback to Swift parsing
    return try parseResponseSwift(data)
    #endif
}
```

Create extension for converting Rust types to Swift:

```swift
// PublicationManagerCore/Sources/PublicationManagerCore/RustBridge/SearchResultBridge.swift

#if canImport(ImbibRustCore)
import ImbibRustCore

extension ImbibRustCore.SearchResult {
    func toSwiftSearchResult() -> PublicationManagerCore.SearchResult {
        // Map Rust SearchResult to Swift SearchResult
        // ...
    }
}
#endif
```

---

### Phase 2.10: Remove Duplicate Swift Code

After verifying Rust implementations work, remove duplicate Swift code:

1. **Remove:** `LaTeXDecoder.swift` (use Rust `latex_decoder`)
2. **Remove:** `JournalMacros.swift` (use Rust `journal_macros`)
3. **Update:** `SearchFormQueryBuilder.swift` to use Rust query builder
4. **Update:** `MathMLParser.swift` to use Rust implementation

---

## Final Verification

After completing all phases:

```bash
# 1. Build and test Rust
cd imbib-core
cargo build --release
cargo test

# 2. Rebuild XCFramework
./build-xcframework.sh

# 3. Build Swift package
cd ../PublicationManagerCore
swift build
swift test

# 4. Build apps
cd ..
xcodebuild -scheme imbib -configuration Debug build
xcodebuild -scheme imbib-iOS -configuration Debug build
```

---

## Summary of New Rust Modules

| Module | File | Purpose |
|--------|------|---------|
| `sources::ads` | `sources/ads.rs` | ADS JSON parsing, PDF link logic |
| `sources::arxiv` | `sources/arxiv.rs` | arXiv XML parsing, query building |
| `sources::crossref` | `sources/crossref.rs` | Crossref JSON parsing |
| `sources::pubmed` | `sources/pubmed.rs` | PubMed XML parsing |
| `query::parser` | `query/parser.rs` | Parse queries back to form fields |
| `text::mathml` | `text/mathml.rs` | MathML to Unicode conversion |
| `automation` | `automation/mod.rs` | URL command parsing |

---

## Code Sharing After Phase 2

| Component | Native | Web (WASM) | Server | Shared |
|-----------|--------|------------|--------|--------|
| All source plugin parsing | ✓ | ✓ | ✓ | **100%** |
| Query building/parsing | ✓ | ✓ | ✓ | **100%** |
| MathML parsing | ✓ | ✓ | ✓ | **100%** |
| URL command parsing | ✓ | ✓ | ✓ | **100%** |
| HTTP orchestration | Swift | JS fetch | Rust reqwest | 0% |
| UI | SwiftUI | React | N/A | 0% |

Swift layer after Phase 2 contains only:
- URLSession HTTP calls
- Credential management (Keychain)
- Core Data persistence
- CloudKit sync
- SwiftUI views
