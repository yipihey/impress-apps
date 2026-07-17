//! OpenAlex source client.
//!
//! Port of `apps/imbib/PublicationManagerCore/Sources/PublicationManagerCore/Sources/BuiltIn/OpenAlex/OpenAlexSource.swift`.
//!
//! Uses the OpenAlex REST API at `https://api.openalex.org`. No mandatory
//! credentials; passing an email opts into the "polite pool".

use async_trait::async_trait;
use serde_json::Value;

use crate::error::SourceError;
use crate::types::{author_from_names, PaperMetadata, SearchQuery, SearchResult};
use crate::SourcePlugin;

const DEFAULT_BASE_URL: &str = "https://api.openalex.org";

pub struct OpenAlexSource {
    base_url: String,
    client: reqwest::Client,
}

impl Default for OpenAlexSource {
    fn default() -> Self {
        Self::new()
    }
}

impl OpenAlexSource {
    pub fn new() -> Self {
        Self::with_base_url(DEFAULT_BASE_URL)
    }

    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            client: reqwest::Client::builder()
                .user_agent("impress-sources/0.1 (openalex-client)")
                .build()
                .expect("reqwest client"),
        }
    }

    fn parse_work(item: &Value) -> Option<PaperMetadata> {
        let id_url = item.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let source_id = id_url
            .rsplit('/')
            .next()
            .unwrap_or(id_url)
            .to_string();

        let title = item
            .get("title")
            .or_else(|| item.get("display_name"))
            .and_then(|v| v.as_str())
            .unwrap_or("Untitled")
            .to_string();

        let doi = item
            .get("doi")
            .and_then(|v| v.as_str())
            .map(|s| s.trim_start_matches("https://doi.org/").to_string());

        // OpenAlex returns authors under authorships[].author
        let authors = item
            .get("authorships")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|a| {
                        let author = a.get("author")?;
                        let display = author.get("display_name").and_then(|v| v.as_str())?;
                        // Try split on whitespace -> last is family.
                        let parts: Vec<&str> = display.split_whitespace().collect();
                        if parts.len() == 1 {
                            Some(author_from_names(parts[0].to_string(), None))
                        } else {
                            let family = parts.last().unwrap().to_string();
                            let given = parts[..parts.len() - 1].join(" ");
                            let mut a = author_from_names(family, Some(given));
                            a.orcid = author
                                .get("orcid")
                                .and_then(|v| v.as_str())
                                .map(String::from);
                            Some(a)
                        }
                    })
                    .collect()
            })
            .unwrap_or_default();

        let year = item
            .get("publication_year")
            .and_then(|v| v.as_i64())
            .map(|y| y as i32);

        let venue = item
            .get("host_venue")
            .or_else(|| item.get("primary_location").and_then(|p| p.get("source")))
            .and_then(|h| h.get("display_name"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let abstract_text = item
            .get("abstract_inverted_index")
            .and_then(|v| v.as_object())
            .map(reconstruct_abstract);

        let pdf_url = item
            .get("primary_location")
            .and_then(|p| p.get("pdf_url"))
            .and_then(|v| v.as_str())
            .map(String::from)
            .or_else(|| {
                item.get("open_access")
                    .and_then(|oa| oa.get("oa_url"))
                    .and_then(|v| v.as_str())
                    .map(String::from)
            });

        // Try to extract an arXiv ID from the openalex ids dict.
        let arxiv_id = item
            .get("ids")
            .and_then(|v| v.as_object())
            .and_then(|m| {
                m.iter().find_map(|(k, v)| {
                    if k.eq_ignore_ascii_case("arxiv") {
                        v.as_str().map(|s| {
                            s.trim_start_matches("https://arxiv.org/abs/").to_string()
                        })
                    } else {
                        None
                    }
                })
            });

        Some(PaperMetadata {
            source_id,
            doi,
            arxiv_id,
            title,
            authors,
            abstract_text,
            year,
            venue,
            pdf_url,
            raw_json: item.clone(),
        })
    }
}

/// OpenAlex stores abstracts as an inverted index `{word: [positions...]}`.
/// Re-assemble into a plain string.
fn reconstruct_abstract(index: &serde_json::Map<String, Value>) -> String {
    let mut positions: Vec<(usize, &str)> = Vec::new();
    for (word, idxs) in index {
        if let Some(arr) = idxs.as_array() {
            for v in arr {
                if let Some(i) = v.as_u64() {
                    positions.push((i as usize, word.as_str()));
                }
            }
        }
    }
    positions.sort_by_key(|(i, _)| *i);
    positions
        .into_iter()
        .map(|(_, w)| w)
        .collect::<Vec<_>>()
        .join(" ")
}

#[async_trait]
impl SourcePlugin for OpenAlexSource {
    fn id(&self) -> &str {
        "openalex"
    }
    fn display_name(&self) -> &str {
        "OpenAlex"
    }
    fn requires_credentials(&self) -> bool {
        false
    }

    async fn search(
        &self,
        query: &SearchQuery,
        credentials: Option<&str>,
    ) -> Result<SearchResult, SourceError> {
        let per_page = query.limit.clamp(1, 200);
        let mut url = reqwest::Url::parse(&format!("{}/works", self.base_url))?;
        {
            let mut qp = url.query_pairs_mut();
            let has_search = !query.raw.trim().is_empty();
            if has_search {
                qp.append_pair("search", &query.raw);
            }

            // Combine fielded filters + year range into the OpenAlex
            // `filter=` syntax (comma-separated key:value pairs).
            let mut filters: Vec<String> = query
                .fielded
                .iter()
                .map(|(k, v)| {
                    // Map a few common field names to OpenAlex equivalents.
                    let key = match k.as_str() {
                        "title" => "title.search",
                        "author" => "author.id",
                        "doi" => "doi",
                        other => other,
                    };
                    format!("{key}:{v}")
                })
                .collect();
            if let Some((from, until)) = query.year_range {
                if let Some(y) = from {
                    filters.push(format!("from_publication_date:{y}-01-01"));
                }
                if let Some(y) = until {
                    filters.push(format!("to_publication_date:{y}-12-31"));
                }
            }
            if !filters.is_empty() {
                qp.append_pair("filter", &filters.join(","));
            }

            qp.append_pair("per-page", &per_page.to_string());
            qp.append_pair(
                "sort",
                if has_search {
                    "relevance_score:desc"
                } else {
                    "cited_by_count:desc"
                },
            );
            if let Some(email) = credentials {
                qp.append_pair("mailto", email);
            }
        }

        let resp = self.client.get(url).send().await?;
        let status = resp.status();
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
        let json: Value = serde_json::from_str(&body)?;
        let total = json
            .get("meta")
            .and_then(|m| m.get("count"))
            .and_then(|v| v.as_u64());
        let next_cursor = json
            .get("meta")
            .and_then(|m| m.get("next_cursor"))
            .and_then(|v| v.as_str())
            .map(String::from);
        let items = json
            .get("results")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(Self::parse_work).collect())
            .unwrap_or_default();
        Ok(SearchResult {
            source: "openalex".to_string(),
            items,
            total_estimated: total,
            next_cursor,
        })
    }

    async fn fetch_by_id(
        &self,
        id: &str,
        credentials: Option<&str>,
    ) -> Result<PaperMetadata, SourceError> {
        // Accept either a bare W… id, a full openalex URL, or a DOI.
        let path = if id.starts_with("https://") {
            id.trim_start_matches("https://openalex.org/").to_string()
        } else if id.starts_with("10.") {
            format!("doi:{id}")
        } else if id.starts_with('W') {
            id.to_string()
        } else {
            format!("W{id}")
        };

        let mut url = reqwest::Url::parse(&format!("{}/works/{}", self.base_url, path))?;
        if let Some(email) = credentials {
            url.query_pairs_mut().append_pair("mailto", email);
        }
        let resp = self.client.get(url).send().await?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Err(SourceError::NotFound(format!("openalex id {id}")));
        }
        if !status.is_success() {
            return Err(SourceError::Http {
                status: status.as_u16(),
                message: status.to_string(),
            });
        }
        let body = resp.text().await?;
        let json: Value = serde_json::from_str(&body)?;
        Self::parse_work(&json)
            .ok_or_else(|| SourceError::InvalidResponse("could not parse openalex work".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconstructs_abstract() {
        let mut idx = serde_json::Map::new();
        idx.insert("Hello".into(), serde_json::json!([0]));
        idx.insert("world".into(), serde_json::json!([1, 3]));
        idx.insert("from".into(), serde_json::json!([2]));
        let s = reconstruct_abstract(&idx);
        assert_eq!(s, "Hello world from world");
    }
}
