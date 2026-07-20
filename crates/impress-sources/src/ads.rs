//! NASA ADS (Astrophysics Data System) source client.
//!
//! Port equivalent of `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/ADSSource.swift`,
//! which delegates to the `scix-client` Rust crate. Here we hit ADS's REST
//! API directly so we don't depend on `scix-client`.
//!
//! ## API
//! - Search: `GET https://api.adsabs.harvard.edu/v1/search/query?q=&fl=&rows=`
//! - Export BibTeX: `POST https://api.adsabs.harvard.edu/v1/export/bibtex` with `{ "bibcode": [...] }`
//!
//! Both require `Authorization: Bearer <token>` where the token is provided by
//! the caller (the Swift side looks it up via Keychain and passes it in).

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::SourceError;
use crate::types::{author_from_names, PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

const DEFAULT_BASE_URL: &str = "https://api.adsabs.harvard.edu/v1";

/// Fields we ask ADS to return; mirrors the fl= list used by `scix-client`.
const ADS_FIELDS: &str =
    "bibcode,title,author,year,pub,doi,abstract,citation_count,read_count,property,esources,identifier,arxiv_class";

pub struct AdsSource {
    base_url: String,
    client: reqwest::Client,
}

impl Default for AdsSource {
    fn default() -> Self {
        Self::new()
    }
}

impl AdsSource {
    pub fn new() -> Self {
        Self::with_base_url(DEFAULT_BASE_URL)
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::builder()
                .user_agent("impress-sources/0.1 (ads-client)")
                .build()
                .expect("reqwest client"),
        }
    }
}

#[derive(Debug, Deserialize)]
struct AdsSearchResponse {
    response: AdsResponseInner,
}

#[derive(Debug, Deserialize)]
struct AdsResponseInner {
    #[serde(default)]
    #[serde(rename = "numFound")]
    num_found: u64,
    #[serde(default)]
    docs: Vec<AdsDoc>,
}

#[derive(Debug, Deserialize, Serialize)]
struct AdsDoc {
    #[serde(default)]
    bibcode: Option<String>,
    #[serde(default)]
    title: Option<Vec<String>>,
    #[serde(default)]
    author: Option<Vec<String>>,
    #[serde(default)]
    year: Option<String>,
    #[serde(default)]
    pub_: Option<String>,
    #[serde(default, rename = "pub")]
    publication: Option<String>,
    #[serde(default)]
    doi: Option<Vec<String>>,
    #[serde(default, rename = "abstract")]
    abstract_text: Option<String>,
    #[serde(default)]
    identifier: Option<Vec<String>>,
    #[serde(default)]
    esources: Option<Vec<String>>,
    #[serde(default)]
    property: Option<Vec<String>>,
    #[serde(default)]
    citation_count: Option<u64>,
    #[serde(default)]
    read_count: Option<u64>,
    #[serde(default)]
    arxiv_class: Option<Vec<String>>,
}

impl AdsDoc {
    fn into_paper_metadata(self, raw: Value) -> PaperMetadata {
        let bibcode = self.bibcode.clone().unwrap_or_default();
        let title = self
            .title
            .as_ref()
            .and_then(|v| v.first())
            .cloned()
            .unwrap_or_else(|| "Untitled".to_string());
        let doi = self.doi.as_ref().and_then(|v| v.first()).cloned();

        // arXiv id may live in identifier list; ADS uses entries like "arXiv:2301.12345"
        let arxiv_id = self.identifier.as_ref().and_then(|ids| {
            ids.iter().find_map(|i| {
                if let Some(rest) = i.strip_prefix("arXiv:") {
                    Some(rest.to_string())
                } else {
                    None
                }
            })
        });

        let authors = self
            .author
            .as_ref()
            .map(|list| {
                list.iter()
                    .map(|a| {
                        // ADS author strings are "Family, Given" generally.
                        if let Some((fam, giv)) = a.split_once(',') {
                            author_from_names(fam.trim().to_string(), Some(giv.trim().to_string()))
                        } else {
                            // Fallback: treat as family-only.
                            author_from_names(a.trim().to_string(), None)
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();

        let year = self.year.as_ref().and_then(|s| s.parse::<i32>().ok());
        let venue = self.publication.clone().or(self.pub_.clone());

        PaperMetadata {
            source_id: bibcode,
            doi,
            arxiv_id,
            title,
            authors,
            abstract_text: self.abstract_text.clone(),
            year,
            venue,
            pdf_url: None,
            raw_json: raw,
        }
    }
}

#[async_trait]
impl SourcePlugin for AdsSource {
    fn id(&self) -> &str {
        "ads"
    }
    fn display_name(&self) -> &str {
        "NASA ADS"
    }
    fn requires_credentials(&self) -> bool {
        true
    }

    async fn search(
        &self,
        query: &SearchQuery,
        credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        let token =
            credentials.ok_or_else(|| SourceError::AuthenticationRequired("ads".to_string()))?;

        let rows = query.limit.clamp(1, 2000);
        let start = query.offset;

        // Compose query string: free-text + fielded terms + optional year filter.
        let mut q = query.raw.trim().to_string();
        for (field, value) in &query.fielded {
            if !q.is_empty() {
                q.push(' ');
            }
            // ADS uses field:value with quotes for phrases.
            let value = if value.contains(' ') {
                format!("\"{value}\"")
            } else {
                value.clone()
            };
            q.push_str(&format!("{field}:{value}"));
        }
        if let Some((from, until)) = query.year_range {
            let lo = from.map(|y| y.to_string()).unwrap_or_else(|| "*".into());
            let hi = until.map(|y| y.to_string()).unwrap_or_else(|| "*".into());
            if !q.is_empty() {
                q.push(' ');
            }
            q.push_str(&format!("year:[{lo} TO {hi}]"));
        }
        if q.is_empty() {
            return Err(SourceError::InvalidRequest("empty query".into()));
        }

        let url = reqwest::Url::parse_with_params(
            &format!("{}/search/query", self.base_url),
            &[
                ("q", q.as_str()),
                ("fl", ADS_FIELDS),
                ("rows", &rows.to_string()),
                ("start", &start.to_string()),
                ("sort", "date desc"),
            ],
        )?;

        let resp = self
            .client
            .get(url)
            .header("Authorization", format!("Bearer {token}"))
            .send()
            .await?;
        let status = resp.status();
        if status.as_u16() == 401 || status.as_u16() == 403 {
            return Err(SourceError::AuthenticationRequired("ads".to_string()));
        }
        if status.as_u16() == 429 {
            return Err(SourceError::RateLimited {
                retry_after_secs: None,
            });
        }
        if !status.is_success() {
            return Err(SourceError::Http {
                status: status.as_u16(),
                message: status.to_string(),
            });
        }
        let body = resp.text().await?;
        let parsed: AdsSearchResponse = serde_json::from_str(&body)?;
        // Preserve the original docs as raw_json on a per-item basis.
        let raw_value: Value = serde_json::from_str(&body)?;
        let raw_docs = raw_value
            .get("response")
            .and_then(|v| v.get("docs"))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut items = Vec::with_capacity(parsed.response.docs.len());
        for (i, doc) in parsed.response.docs.into_iter().enumerate() {
            let raw = raw_docs.get(i).cloned().unwrap_or(Value::Null);
            items.push(doc.into_paper_metadata(raw));
        }
        Ok(SearchResult {
            source: "ads".to_string(),
            items,
            total_estimated: Some(parsed.response.num_found),
            next_cursor: None,
        })
    }

    async fn fetch_by_id(
        &self,
        id: &str,
        credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        // ADS identifiers are bibcodes; use a targeted bibcode query.
        let token =
            credentials.ok_or_else(|| SourceError::AuthenticationRequired("ads".to_string()))?;

        let url = reqwest::Url::parse_with_params(
            &format!("{}/search/query", self.base_url),
            &[
                ("q", format!("bibcode:{id}").as_str()),
                ("fl", ADS_FIELDS),
                ("rows", "1"),
            ],
        )?;
        let resp = self
            .client
            .get(url)
            .header("Authorization", format!("Bearer {token}"))
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(SourceError::Http {
                status: resp.status().as_u16(),
                message: resp.status().to_string(),
            });
        }
        let body = resp.text().await?;
        let parsed: AdsSearchResponse = serde_json::from_str(&body)?;
        let raw_value: Value = serde_json::from_str(&body)?;
        let raw_docs = raw_value
            .get("response")
            .and_then(|v| v.get("docs"))
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let mut docs = parsed.response.docs.into_iter();
        let first_doc = docs
            .next()
            .ok_or_else(|| SourceError::NotFound(format!("bibcode {id}")))?;
        let raw = raw_docs.into_iter().next().unwrap_or(Value::Null);
        Ok(first_doc.into_paper_metadata(raw))
    }
}

/// Fetch a BibTeX string from the ADS `/export/bibtex` endpoint.
///
/// Kept as a free function (not part of `SourcePlugin`) because the trait
/// only describes search + fetch. Swift currently calls `scix_export_bibtex`;
/// we provide an equivalent here so a follow-up phase can collapse both.
pub async fn export_bibtex(
    client: &reqwest::Client,
    base_url: &str,
    token: &str,
    bibcodes: &[String],
) -> Result<String, SourceError> {
    let body = serde_json::json!({ "bibcode": bibcodes });
    let resp = client
        .post(format!("{}/export/bibtex", base_url))
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/json")
        .body(body.to_string())
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(SourceError::Http {
            status: resp.status().as_u16(),
            message: resp.status().to_string(),
        });
    }
    let json: Value = resp.json().await?;
    json.get("export")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .ok_or_else(|| SourceError::InvalidResponse("missing export field".into()))
}
