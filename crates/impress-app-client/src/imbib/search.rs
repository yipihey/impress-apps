//! `ImbibSearchService` method clients.

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::library_service::PublicationSummary;
use imbib_service::search_service::SmartSearchRecord;

#[derive(Deserialize)]
struct StatusEnvelope {
    status: String,
}
fn check(s: &StatusEnvelope) -> Result<()> {
    if s.status == "ok" {
        Ok(())
    } else {
        Err(AppClientError::Api(s.status.clone()))
    }
}

impl ImbibClient {
    pub async fn find_by_cite_key(
        &self,
        cite_key: String,
        _library_id: Option<String>,
    ) -> Result<Option<PublicationSummary>> {
        let url = self
            .base_url
            .join(&format!("/api/papers/{}", urlencoding::encode(&cite_key)))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            paper: PublicationSummary,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.paper))
    }

    pub async fn find_by_doi(&self, doi: String) -> Result<Vec<PublicationSummary>> {
        // Search by DOI string via /api/search.
        self.search_with_params(Some(doi), None, None, None, None, None, 10, 0, None, None)
            .await
    }

    pub async fn find_by_arxiv(&self, arxiv_id: String) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            Some(arxiv_id),
            None,
            None,
            None,
            None,
            None,
            10,
            0,
            None,
            None,
        )
        .await
    }

    pub async fn find_by_bibcode(&self, bibcode: String) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            Some(bibcode),
            None,
            None,
            None,
            None,
            None,
            10,
            0,
            None,
            None,
        )
        .await
    }

    pub async fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Result<Vec<PublicationSummary>> {
        let url = self.base_url.join("/api/papers/find-by-identifiers")?;
        let body = json!({"dois": dois, "arxiv_ids": arxiv_ids, "bibcodes": bibcodes});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            papers: Vec<PublicationSummary>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.papers)
    }

    pub async fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: u32,
    ) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            Some(query),
            None,
            None,
            None,
            None,
            parent_id,
            limit,
            0,
            None,
            None,
        )
        .await
    }

    pub async fn list_smart_searches(
        &self,
        library_id: Option<String>,
    ) -> Result<Vec<SmartSearchRecord>> {
        let mut url = self.base_url.join("/api/smart-searches")?;
        if let Some(lib) = library_id {
            url.query_pairs_mut().append_pair("library_id", &lib);
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            searches: Vec<SmartSearchRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.searches)
    }

    pub async fn get_smart_search(&self, id: String) -> Result<Option<SmartSearchRecord>> {
        let url = self.base_url.join(&format!("/api/smart-searches/{}", id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            search: SmartSearchRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.search))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_smart_search(
        &self,
        name: String,
        query: String,
        library_id: String,
        source_ids_json: Option<String>,
        max_results: i64,
        feeds_to_inbox: bool,
        auto_refresh_enabled: bool,
        refresh_interval_seconds: i64,
    ) -> Result<Option<SmartSearchRecord>> {
        let url = self.base_url.join("/api/smart-searches")?;
        let body = json!({
            "name": name,
            "query": query,
            "library_id": library_id,
            "source_ids_json": source_ids_json,
            "max_results": max_results,
            "feeds_to_inbox": feeds_to_inbox,
            "auto_refresh_enabled": auto_refresh_enabled,
            "refresh_interval_seconds": refresh_interval_seconds,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "POST /api/smart-searches (Phase D)".into(),
            ));
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            search: SmartSearchRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.search))
    }
}
