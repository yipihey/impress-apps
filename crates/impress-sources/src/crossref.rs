//! Crossref source client.
//!
//! Port of `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/CrossrefSource.swift`.
//!
//! Uses the Crossref REST API at `https://api.crossref.org`. No mandatory
//! credentials; passing an email opts into the "polite pool" with higher
//! rate limits.

use async_trait::async_trait;
use regex::Regex;
use serde_json::Value;

use crate::error::SourceError;
use crate::types::{author_from_names, PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

const DEFAULT_BASE_URL: &str = "https://api.crossref.org";

/// Crossref REST client.
///
/// Pass the user's email as `credentials` to use the polite pool.
pub struct CrossrefSource {
    base_url: String,
    client: reqwest::Client,
}

impl Default for CrossrefSource {
    fn default() -> Self {
        Self::new()
    }
}

impl CrossrefSource {
    pub fn new() -> Self {
        Self::with_base_url(DEFAULT_BASE_URL)
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::builder()
                .user_agent("impress-sources/0.1 (https://github.com/yipihey/impress-apps; mailto:contact@imbib.app)")
                .build()
                .expect("reqwest client"),
        }
    }

    fn looks_like_doi(s: &str) -> bool {
        // Same regex as the Swift fast-path: bare DOI of the form 10.xxxx/...
        lazy_static::lazy_static! {
            static ref DOI_RE: Regex = Regex::new(r"^10\.\d{4,9}/\S+$").unwrap();
        }
        DOI_RE.is_match(s.trim())
    }

    fn parse_work_item(item: &Value) -> Option<PaperMetadata> {
        let doi = item.get("DOI")?.as_str()?.to_string();

        let title = item
            .get("title")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .unwrap_or("Untitled")
            .to_string();

        let authors = item
            .get("author")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|a| {
                        let given = a.get("given").and_then(|v| v.as_str()).map(String::from);
                        let family = a.get("family").and_then(|v| v.as_str()).map(String::from)?;
                        if family.is_empty() {
                            return None;
                        }
                        let orcid = a.get("ORCID").and_then(|v| v.as_str()).map(String::from);
                        let mut author = author_from_names(family, given);
                        author.orcid = orcid;
                        Some(author)
                    })
                    .collect()
            })
            .unwrap_or_default();

        let year = ["published-print", "published-online", "issued"]
            .iter()
            .find_map(|k| {
                item.get(*k)
                    .and_then(|v| v.get("date-parts"))
                    .and_then(|v| v.as_array())
                    .and_then(|outer| outer.first())
                    .and_then(|inner| inner.as_array())
                    .and_then(|parts| parts.first())
                    .and_then(|v| v.as_i64())
                    .map(|y| y as i32)
            });

        let venue = item
            .get("container-title")
            .and_then(|v| v.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let abstract_text = item
            .get("abstract")
            .and_then(|v| v.as_str())
            .map(clean_html_tags);

        let pdf_url = item
            .get("link")
            .and_then(|v| v.as_array())
            .and_then(|links| {
                links.iter().find_map(|l| {
                    let ct = l.get("content-type").and_then(|v| v.as_str()).unwrap_or("");
                    if ct.contains("pdf") {
                        l.get("URL").and_then(|v| v.as_str()).map(|s| s.to_string())
                    } else {
                        None
                    }
                })
            });

        Some(PaperMetadata {
            source_id: doi.clone(),
            doi: Some(doi),
            arxiv_id: None,
            title: clean_html_tags(&title),
            authors,
            abstract_text,
            year,
            venue,
            pdf_url,
            raw_json: item.clone(),
        })
    }

    fn parse_search_response(body: &str) -> Result<SearchResult, SourceError> {
        let json: Value = serde_json::from_str(body)?;
        let message = json
            .get("message")
            .ok_or_else(|| SourceError::InvalidResponse("missing message".into()))?;
        let items = message
            .get("items")
            .and_then(|v| v.as_array())
            .ok_or_else(|| SourceError::InvalidResponse("missing message.items".into()))?;
        let parsed = items
            .iter()
            .filter_map(Self::parse_work_item)
            .collect::<Vec<_>>();
        let total = message
            .get("total-results")
            .and_then(|v| v.as_u64())
            .or(Some(parsed.len() as u64));
        Ok(SearchResult {
            source: "crossref".to_string(),
            items: parsed,
            total_estimated: total,
            next_cursor: None,
        })
    }

    async fn fetch_by_doi(
        &self,
        doi: &str,
        email: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        let encoded = urlencoding::encode(doi);
        let mut url = reqwest::Url::parse(&format!("{}/works/{}", self.base_url, encoded))?;
        if let Some(email) = email {
            url.query_pairs_mut().append_pair("mailto", email);
        }
        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Err(SourceError::NotFound(format!("doi {doi}")));
        }
        if status.as_u16() == 429 {
            return Err(SourceError::RateLimited {
                retry_after_secs: Some(60),
            });
        }
        if !status.is_success() {
            return Err(SourceError::Http {
                status: status.as_u16(),
                message: status.to_string(),
            });
        }
        let body = resp.text().await?;
        let json: Value = serde_json::from_str(&body)?;
        let message = json
            .get("message")
            .ok_or_else(|| SourceError::InvalidResponse("missing message".into()))?;
        Self::parse_work_item(message)
            .ok_or_else(|| SourceError::InvalidResponse("could not parse Crossref work".into()))
    }
}

#[async_trait]
impl SourcePlugin for CrossrefSource {
    fn id(&self) -> &str {
        "crossref"
    }
    fn display_name(&self) -> &str {
        "Crossref"
    }
    fn requires_credentials(&self) -> bool {
        false
    }

    async fn search(
        &self,
        query: &SearchQuery,
        credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        // Fast-path: bare DOI → exact lookup, avoid fuzzy /works?query=
        // misbehavior documented in the Swift source.
        if Self::looks_like_doi(&query.raw) {
            let item = self.fetch_by_doi(query.raw.trim(), credentials).await?;
            return Ok(SearchResult {
                source: "crossref".to_string(),
                items: vec![item],
                total_estimated: Some(1),
                next_cursor: None,
            });
        }

        let rows = query.limit.clamp(1, 1000);
        let offset = query.offset;

        let mut url = reqwest::Url::parse(&format!("{}/works", self.base_url))?;
        {
            let mut qp = url.query_pairs_mut();
            qp.append_pair("query", &query.raw);
            qp.append_pair("rows", &rows.to_string());
            qp.append_pair("offset", &offset.to_string());
            qp.append_pair("sort", "relevance");
            qp.append_pair("order", "desc");
            if let Some(email) = credentials {
                qp.append_pair("mailto", email);
            }
            // Year-range filter — Crossref supports `filter=from-pub-date:YYYY,until-pub-date:YYYY`
            if let Some((from, until)) = query.year_range {
                let mut filter_parts: Vec<String> = Vec::new();
                if let Some(y) = from {
                    filter_parts.push(format!("from-pub-date:{y}"));
                }
                if let Some(y) = until {
                    filter_parts.push(format!("until-pub-date:{y}"));
                }
                if !filter_parts.is_empty() {
                    qp.append_pair("filter", &filter_parts.join(","));
                }
            }
            // Fielded filters → Crossref's `query.title`, `query.author`, …
            for (field, value) in &query.fielded {
                let key = match field.as_str() {
                    "title" => "query.title",
                    "author" => "query.author",
                    "container" | "venue" => "query.container-title",
                    other => {
                        // Pass through; Crossref will ignore unknown ones.
                        let _ = other;
                        continue;
                    }
                };
                qp.append_pair(key, value);
            }
        }

        let resp = self
            .client
            .get(url)
            .header(reqwest::header::ACCEPT, "application/json")
            .send()
            .await?;
        let status = resp.status();
        if status.as_u16() == 429 {
            return Err(SourceError::RateLimited {
                retry_after_secs: Some(60),
            });
        }
        if !status.is_success() {
            return Err(SourceError::Http {
                status: status.as_u16(),
                message: status.to_string(),
            });
        }
        let body = resp.text().await?;
        Self::parse_search_response(&body)
    }

    async fn fetch_by_id(
        &self,
        id: &str,
        credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        self.fetch_by_doi(id, credentials).await
    }
}

/// Strip JATS/HTML tags commonly present in Crossref abstracts and decode
/// the small entity set we know about.
fn clean_html_tags(text: &str) -> String {
    lazy_static::lazy_static! {
        static ref TAG_RE: Regex = Regex::new(r"<[^>]+>").unwrap();
    }
    let mut result = text.replace("<jats:", "<").replace("</jats:", "</");
    result = TAG_RE.replace_all(&result, "").to_string();
    result = result
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'");
    result.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doi_fast_path() {
        assert!(CrossrefSource::looks_like_doi("10.1234/abc.def"));
        assert!(!CrossrefSource::looks_like_doi("some title"));
    }

    #[test]
    fn cleans_jats_tags() {
        let s = "<jats:p>Hello <jats:i>world</jats:i></jats:p>";
        assert_eq!(clean_html_tags(s), "Hello world");
    }
}
