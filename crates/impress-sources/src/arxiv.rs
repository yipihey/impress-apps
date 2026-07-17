//! arXiv source client.
//!
//! Port of `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/ArXivSource.swift`.
//!
//! Uses the public Atom-feed search API at `https://export.arxiv.org/api/query`.
//! No credentials required.

use async_trait::async_trait;
use quick_xml::events::Event;
use quick_xml::Reader;

use crate::error::SourceError;
use crate::types::{author_from_names, PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

const DEFAULT_BASE_URL: &str = "https://export.arxiv.org/api/query";
const ABS_BASE_URL: &str = "http://arxiv.org/abs/";

/// arXiv Atom-feed API client.
pub struct ArxivSource {
    base_url: String,
    client: reqwest::Client,
}

impl Default for ArxivSource {
    fn default() -> Self {
        Self::new()
    }
}

impl ArxivSource {
    pub fn new() -> Self {
        Self::with_base_url(DEFAULT_BASE_URL)
    }

    /// Override the base URL — used by tests against a `mockito::Server`.
    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::builder()
                .user_agent("impress-sources/0.1 (https://github.com/yipihey/impress-apps)")
                .build()
                .expect("reqwest client"),
        }
    }

    /// Build an arXiv API query string from a free-text query plus any
    /// fielded filters. Mirrors `buildAPIQuery` in the Swift client.
    fn build_api_query(query: &SearchQuery) -> String {
        let mut parts: Vec<String> = Vec::new();

        // Field prefixes: map common names → arXiv API short codes.
        for (field, value) in &query.fielded {
            let api_field = match field.as_str() {
                "title" | "ti" => "ti",
                "author" | "au" => "au",
                "abstract" | "abs" => "abs",
                "id" | "arxiv" => "id",
                "category" | "cat" => "cat",
                "journal" | "jr" => "jr",
                "comment" | "co" => "co",
                "report" | "rn" => "rn",
                _ => "all",
            };
            let cleaned = value.replace('"', "");
            let term = if cleaned.contains(' ')
                && !cleaned.contains(" AND ")
                && !cleaned.contains(" OR ")
            {
                format!("{api_field}:\"{cleaned}\"")
            } else {
                format!("{api_field}:{cleaned}")
            };
            parts.push(term);
        }

        if !query.raw.trim().is_empty() {
            if Self::is_raw_api_query(&query.raw) {
                parts.push(query.raw.clone());
            } else {
                parts.push(format!("all:{}", query.raw));
            }
        }

        if parts.is_empty() {
            String::new()
        } else {
            parts.join(" AND ")
        }
    }

    fn is_raw_api_query(query: &str) -> bool {
        const PREFIXES: &[&str] = &[
            "all:",
            "ti:",
            "au:",
            "abs:",
            "co:",
            "jr:",
            "cat:",
            "rn:",
            "id:",
            "submittedDate:",
            "lastUpdatedDate:",
        ];
        PREFIXES.iter().any(|p| query.starts_with(p))
    }

    fn parse_atom_feed(xml: &str) -> Result<Vec<PaperMetadata>, SourceError> {
        let mut reader = Reader::from_str(xml);
        reader.trim_text(true);

        let mut buf = Vec::new();
        let mut items: Vec<PaperMetadata> = Vec::new();
        let mut current: Option<EntryAccum> = None;
        let mut path: Vec<String> = Vec::new();

        // Helper: process a start-tag (or self-closing tag) to update entry
        // state. `is_empty` controls whether we also pop the path right away.
        fn handle_start(
            name: &str,
            attrs_iter: quick_xml::events::attributes::Attributes,
            current: &mut Option<EntryAccum>,
            path: &mut Vec<String>,
            is_empty: bool,
        ) {
            path.push(name.to_string());
            if name == "entry" {
                *current = Some(EntryAccum::default());
            }
            if let Some(entry) = current.as_mut() {
                match name {
                    "link" => {
                        let mut href: Option<String> = None;
                        let mut rel = "alternate".to_string();
                        let mut typ = String::new();
                        for attr in attrs_iter.flatten() {
                            let key = String::from_utf8_lossy(attr.key.as_ref()).to_string();
                            let val = attr
                                .unescape_value()
                                .map(|c| c.into_owned())
                                .unwrap_or_default();
                            match key.as_str() {
                                "href" => href = Some(val),
                                "rel" => rel = val,
                                "type" => typ = val,
                                _ => {}
                            }
                        }
                        if let Some(h) = href {
                            if rel == "alternate" {
                                entry.web_url = Some(h.clone());
                            } else if typ == "application/pdf" {
                                entry.pdf_url = Some(h);
                            }
                        }
                    }
                    "arxiv:primary_category" | "category" => {
                        for attr in attrs_iter.flatten() {
                            if attr.key.as_ref() == b"term" {
                                let v = attr
                                    .unescape_value()
                                    .map(|c| c.into_owned())
                                    .unwrap_or_default();
                                if name == "arxiv:primary_category"
                                    && entry.primary_category.is_none()
                                {
                                    entry.primary_category = Some(v.clone());
                                }
                                if !entry.categories.contains(&v) {
                                    entry.categories.push(v);
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
            if is_empty {
                path.pop();
            }
        }

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    handle_start(&name, e.attributes(), &mut current, &mut path, false);
                }
                Ok(Event::Empty(e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    handle_start(&name, e.attributes(), &mut current, &mut path, true);
                }
                Ok(Event::Text(t)) => {
                    let text = t.unescape().map(|c| c.into_owned()).unwrap_or_default();
                    if let (Some(entry), Some(tag)) = (current.as_mut(), path.last()) {
                        match tag.as_str() {
                            "id" => {
                                if path.iter().any(|p| p == "entry") {
                                    entry.id.push_str(&text);
                                }
                            }
                            "title" => {
                                if path.iter().any(|p| p == "entry") {
                                    entry.title.push_str(&text);
                                }
                            }
                            "summary" => entry.summary.push_str(&text),
                            "published" => entry.published.push_str(&text),
                            "name" => entry.current_author_name.push_str(&text),
                            "arxiv:doi" => entry.doi.push_str(&text),
                            _ => {}
                        }
                    }
                }
                Ok(Event::End(e)) => {
                    let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                    match name.as_str() {
                        "entry" => {
                            if let Some(entry) = current.take() {
                                items.push(entry.into_paper_metadata());
                            }
                        }
                        "author" => {
                            if let Some(entry) = current.as_mut() {
                                let name = std::mem::take(&mut entry.current_author_name)
                                    .trim()
                                    .to_string();
                                if !name.is_empty() {
                                    entry.authors.push(parse_arxiv_author(&name));
                                }
                            }
                        }
                        _ => {}
                    }
                    path.pop();
                }
                Ok(Event::Eof) => break,
                Err(e) => {
                    return Err(SourceError::Parse(format!("arxiv atom: {e}")));
                }
                _ => {}
            }
            buf.clear();
        }

        Ok(items)
    }
}

fn parse_arxiv_author(name: &str) -> impress_domain::Author {
    let trimmed = name.trim();
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() <= 1 {
        return author_from_names(trimmed.to_string(), None);
    }
    let family = parts.last().unwrap().to_string();
    let given = parts[..parts.len() - 1].join(" ");
    author_from_names(family, Some(given))
}

#[derive(Default)]
struct EntryAccum {
    id: String,
    title: String,
    summary: String,
    published: String,
    doi: String,
    authors: Vec<impress_domain::Author>,
    current_author_name: String,
    categories: Vec<String>,
    primary_category: Option<String>,
    web_url: Option<String>,
    pdf_url: Option<String>,
}

impl EntryAccum {
    fn into_paper_metadata(mut self) -> PaperMetadata {
        let arxiv_id = extract_arxiv_id(&self.id);
        let year = self
            .published
            .get(0..4)
            .and_then(|s| s.parse::<i32>().ok());

        let title = clean_whitespace(&self.title);
        let summary = if self.summary.is_empty() {
            None
        } else {
            Some(clean_whitespace(&self.summary))
        };
        let doi = if self.doi.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.doi))
        };

        let raw = serde_json::json!({
            "id": self.id,
            "title": title,
            "summary": summary,
            "published": self.published,
            "doi": doi,
            "categories": self.categories,
            "primary_category": self.primary_category,
            "web_url": self.web_url,
            "pdf_url": self.pdf_url,
            "authors": self.authors.iter().map(|a| {
                serde_json::json!({
                    "family": a.family_name,
                    "given": a.given_name,
                })
            }).collect::<Vec<_>>(),
        });

        PaperMetadata {
            source_id: arxiv_id.clone().unwrap_or_else(|| self.id.clone()),
            doi,
            arxiv_id,
            title,
            authors: self.authors,
            abstract_text: summary,
            year,
            venue: Some("arXiv".to_string()),
            pdf_url: self.pdf_url,
            raw_json: raw,
        }
    }
}

fn extract_arxiv_id(url: &str) -> Option<String> {
    // New-style: 2301.12345 or 2301.12345v3
    let re_new = regex::Regex::new(r"\d{4}\.\d{4,5}(v\d+)?").ok()?;
    if let Some(m) = re_new.find(url) {
        return Some(m.as_str().to_string());
    }
    // Old-style: hep-th/9901001
    let re_old = regex::Regex::new(r"[a-z-]+/\d{7}").ok()?;
    re_old.find(url).map(|m| m.as_str().to_string())
}

fn clean_whitespace(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut last_was_ws = false;
    for c in s.trim().chars() {
        if c.is_whitespace() {
            if !last_was_ws {
                out.push(' ');
                last_was_ws = true;
            }
        } else {
            out.push(c);
            last_was_ws = false;
        }
    }
    out
}

#[async_trait]
impl SourcePlugin for ArxivSource {
    fn id(&self) -> &str {
        "arxiv"
    }
    fn display_name(&self) -> &str {
        "arXiv"
    }
    fn requires_credentials(&self) -> bool {
        false
    }

    async fn search(
        &self,
        query: &SearchQuery,
        _credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        let api_query = ArxivSource::build_api_query(query);
        if api_query.is_empty() {
            return Err(SourceError::InvalidRequest("empty query".into()));
        }
        let limit = query.limit.clamp(1, 3000);
        let start = query.offset;

        let url = reqwest::Url::parse_with_params(
            &self.base_url,
            &[
                ("search_query", api_query.as_str()),
                ("start", &start.to_string()),
                ("max_results", &limit.to_string()),
                ("sortBy", "relevance"),
                ("sortOrder", "descending"),
            ],
        )?;

        let resp = self.client.get(url).send().await?;
        let status = resp.status();
        if status.as_u16() == 429 {
            let retry_after = resp
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok());
            return Err(SourceError::RateLimited {
                retry_after_secs: retry_after,
            });
        }
        if !status.is_success() {
            return Err(SourceError::Http {
                status: status.as_u16(),
                message: status.to_string(),
            });
        }
        let body = resp.text().await?;
        let items = ArxivSource::parse_atom_feed(&body)?;
        let total = Some(items.len() as u64);
        Ok(SearchResult {
            source: "arxiv".to_string(),
            items,
            total_estimated: total,
            next_cursor: None,
        })
    }

    async fn fetch_by_id(
        &self,
        id: &str,
        _credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        // arXiv supports `id_list=<id>` directly on the search endpoint.
        let url = reqwest::Url::parse_with_params(
            &self.base_url,
            &[("id_list", id), ("max_results", "1")],
        )?;
        let resp = self.client.get(url).send().await?;
        if !resp.status().is_success() {
            return Err(SourceError::Http {
                status: resp.status().as_u16(),
                message: resp.status().to_string(),
            });
        }
        let body = resp.text().await?;
        let mut items = ArxivSource::parse_atom_feed(&body)?;
        items
            .pop()
            .ok_or_else(|| SourceError::NotFound(format!("arxiv id {id}")))
    }
}

#[allow(dead_code)]
fn arxiv_abs_url(id: &str) -> String {
    format!("{ABS_BASE_URL}{id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_new_style_id() {
        assert_eq!(
            extract_arxiv_id("http://arxiv.org/abs/2301.12345v2"),
            Some("2301.12345v2".to_string())
        );
    }

    #[test]
    fn extracts_old_style_id() {
        assert_eq!(
            extract_arxiv_id("http://arxiv.org/abs/hep-th/9901001"),
            Some("hep-th/9901001".to_string())
        );
    }

    #[test]
    fn builds_query_with_field() {
        let q = SearchQuery::new("supernova").with_field("author", "Phillips");
        let s = ArxivSource::build_api_query(&q);
        assert!(s.contains("au:Phillips"));
        assert!(s.contains("all:supernova"));
    }
}
