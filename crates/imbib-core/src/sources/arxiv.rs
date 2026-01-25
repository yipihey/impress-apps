//! arXiv source plugin with XML Atom feed parsing
//!
//! API docs: https://arxiv.org/help/api/user-manual
//! Rate limit: 1 request per 3 seconds

use super::traits::{SourceError, SourceMetadata};
use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use lazy_static::lazy_static;
use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;

#[cfg(feature = "native")]
use crate::http::HttpClient;

lazy_static! {
    static ref ARXIV_NEW_ID: Regex = Regex::new(r"(\d{4}\.\d{4,5})(v\d+)?").unwrap();
    static ref ARXIV_OLD_ID: Regex = Regex::new(r"([a-z-]+/\d{7})").unwrap();
}

pub struct ArxivSource {
    #[cfg(feature = "native")]
    client: HttpClient,
    base_url: String,
}

impl ArxivSource {
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "native")]
            client: HttpClient::new("imbib/1.0 (https://imbib.app)"),
            base_url: "http://export.arxiv.org/api/query".to_string(),
        }
    }

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

    #[cfg(feature = "native")]
    pub async fn search(
        &self,
        query: &str,
        max_results: u32,
    ) -> Result<Vec<SearchResult>, SourceError> {
        let api_query = build_api_query(query);
        let params = [
            ("search_query", api_query),
            ("max_results", max_results.to_string()),
            ("sortBy", "relevance".to_string()),
            ("sortOrder", "descending".to_string()),
        ];

        let url = format!(
            "{}?{}",
            self.base_url,
            params
                .iter()
                .map(|(k, v)| format!("{}={}", k, urlencoding::encode(v)))
                .collect::<Vec<_>>()
                .join("&")
        );

        let response = self.client.get(&url).await?;

        if response.status != 200 {
            return Err(SourceError::Http(crate::http::HttpError::RequestFailed {
                message: format!("Status {}", response.status),
            }));
        }

        parse_atom_feed_internal(&response.body)
    }

    #[cfg(feature = "native")]
    pub async fn fetch_by_id(&self, arxiv_id: &str) -> Result<SearchResult, SourceError> {
        let clean_id = arxiv_id
            .trim_start_matches("arXiv:")
            .trim_start_matches("arxiv:");

        let url = format!("{}?id_list={}", self.base_url, clean_id);
        let response = self.client.get(&url).await?;

        let results = parse_atom_feed_internal(&response.body)?;
        results.into_iter().next().ok_or(SourceError::NotFound)
    }
}

impl Default for ArxivSource {
    fn default() -> Self {
        Self::new()
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
    let api_prefixes = [
        "all:", "ti:", "au:", "abs:", "co:", "jr:", "cat:", "rn:", "id:",
    ];
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
        let transformed: Vec<String> = parts.iter().map(|p| build_api_query(p.trim())).collect();
        return transformed.join(" AND ");
    }

    if query.contains(" OR ") {
        let parts: Vec<&str> = query.split(" OR ").collect();
        let transformed: Vec<String> = parts.iter().map(|p| build_api_query(p.trim())).collect();
        return transformed.join(" OR ");
    }

    // Default: search all fields
    format!("all:{}", query)
}

fn format_field_value(prefix: &str, value: &str) -> String {
    let clean = value.trim_matches('"');
    if clean.contains(' ') && !clean.contains(" AND ") && !clean.contains(" OR ") {
        format!("{}\"{}\"", prefix, clean)
    } else {
        format!("{}{}", prefix, clean)
    }
}

/// Parse arXiv Atom XML feed to SearchResults (internal)
fn parse_atom_feed_internal(xml: &str) -> Result<Vec<SearchResult>, SourceError> {
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
                            b"href" => {
                                href = Some(String::from_utf8_lossy(&attr.value).to_string())
                            }
                            b"rel" => rel = Some(String::from_utf8_lossy(&attr.value).to_string()),
                            b"type" => {
                                link_type = Some(String::from_utf8_lossy(&attr.value).to_string())
                            }
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

/// Parse arXiv Atom XML feed to SearchResults (exported for FFI)
#[uniffi::export]
pub fn parse_atom_feed(xml: String) -> Result<Vec<SearchResult>, crate::error::FfiError> {
    parse_atom_feed_internal(&xml).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

fn clean_title(title: &str) -> String {
    title
        .replace('\n', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[allow(clippy::too_many_arguments)]
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
    let parsed_authors: Vec<Author> = authors
        .iter()
        .map(|name| {
            let parts: Vec<&str> = name.split_whitespace().collect();
            if parts.len() >= 2 {
                Author {
                    id: uuid::Uuid::new_v4().to_string(),
                    given_name: Some(parts[..parts.len() - 1].join(" ")),
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
        abstract_text: if summary.is_empty() {
            None
        } else {
            Some(summary.to_string())
        },
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
        assert_eq!(build_api_query("machine learning"), "all:machine learning");
        assert_eq!(build_api_query("cat:cs.LG"), "cat:cs.LG");
        assert_eq!(build_api_query("author:Einstein"), "au:Einstein");
        assert_eq!(build_api_query("ti:quantum"), "ti:quantum");
    }

    #[test]
    fn test_extract_arxiv_id() {
        assert_eq!(
            extract_arxiv_id("http://arxiv.org/abs/2301.12345v1"),
            Some("2301.12345".to_string())
        );
        assert_eq!(
            extract_arxiv_id("hep-th/9901001"),
            Some("hep-th/9901001".to_string())
        );
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
        let results = parse_atom_feed(SAMPLE_ATOM.to_string()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Test Paper About Machine Learning");
        assert_eq!(results[0].authors.len(), 2);
        assert_eq!(
            results[0].identifiers.arxiv_id,
            Some("2301.12345".to_string())
        );
    }
}
