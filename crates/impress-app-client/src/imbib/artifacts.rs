//! `ImbibArtifactsService` method clients.

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::artifacts_service::{ArtifactRecord, ArtifactRelationRecord};
use imbib_service::library_service::MutationResult;

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
    pub async fn list_artifacts(
        &self,
        schema_filter: Option<String>,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<ArtifactRecord>> {
        let lim = if limit == 0 { 50 } else { limit };
        let mut url = self.base_url.join("/api/artifacts")?;
        url.query_pairs_mut()
            .append_pair("limit", &lim.to_string())
            .append_pair("offset", &offset.to_string());
        if let Some(s) = schema_filter {
            url.query_pairs_mut().append_pair("type", &s);
        }
        let resp = self.http.get(url).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            artifacts: Vec<ArtifactRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.artifacts)
    }

    pub async fn search_artifacts(
        &self,
        query: String,
        schema_filter: Option<String>,
    ) -> Result<Vec<ArtifactRecord>> {
        let mut url = self.base_url.join("/api/artifacts")?;
        url.query_pairs_mut().append_pair("query", &query);
        if let Some(s) = schema_filter {
            url.query_pairs_mut().append_pair("type", &s);
        }
        let resp = self.http.get(url).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            artifacts: Vec<ArtifactRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.artifacts)
    }

    pub async fn get_artifact(&self, id: String) -> Result<Option<ArtifactRecord>> {
        let url = self.base_url.join(&format!("/api/artifacts/{}", id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            artifact: ArtifactRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.artifact))
    }

    pub async fn count_artifacts(&self, schema_filter: Option<String>) -> Result<u32> {
        // Use list with limit=1 and read the count field.
        let mut url = self.base_url.join("/api/artifacts")?;
        url.query_pairs_mut().append_pair("limit", "1");
        if let Some(s) = schema_filter {
            url.query_pairs_mut().append_pair("type", &s);
        }
        let resp = self.http.get(url).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            count: Option<u32>,
            #[serde(default)]
            total: Option<u32>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.total.or(body.count).unwrap_or(0))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn create_artifact(
        &self,
        schema: String,
        title: String,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        file_name: Option<String>,
        file_hash: Option<String>,
        file_size: Option<i64>,
        file_mime_type: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
        tags: Vec<String>,
    ) -> Result<Option<ArtifactRecord>> {
        let url = self.base_url.join("/api/artifacts")?;
        let body = json!({
            "schema": schema,
            "title": title,
            "source_url": source_url,
            "notes": notes,
            "artifact_subtype": artifact_subtype,
            "file_name": file_name,
            "file_hash": file_hash,
            "file_size": file_size,
            "file_mime_type": file_mime_type,
            "capture_context": capture_context,
            "original_author": original_author,
            "event_name": event_name,
            "event_date": event_date,
            "tags": tags,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        #[derive(Deserialize)]
        struct R {
            status: String,
            artifact: ArtifactRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.artifact))
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn update_artifact(
        &self,
        id: String,
        title: Option<String>,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
    ) -> Result<MutationResult> {
        let url = self.base_url.join(&format!("/api/artifacts/{}", id))?;
        let body = json!({
            "title": title,
            "source_url": source_url,
            "notes": notes,
            "artifact_subtype": artifact_subtype,
            "capture_context": capture_context,
            "original_author": original_author,
            "event_name": event_name,
            "event_date": event_date,
        });
        let resp = self.http.put(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "PUT /api/artifacts/{id} (Phase D)".into(),
            ));
        }
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn delete_artifact(&self, id: String) -> Result<MutationResult> {
        let url = self.base_url.join(&format!("/api/artifacts/{}", id))?;
        let resp = self.http.delete(url).send().await?;
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn link_artifact_to_publication(
        &self,
        artifact_id: String,
        publication_id: String,
    ) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/artifacts/{}/link", artifact_id))?;
        let resp = self
            .http
            .post(url)
            .json(&json!({"publication_id": publication_id}))
            .send()
            .await?;
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn get_artifact_relations(&self, id: String) -> Result<Vec<ArtifactRelationRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/artifacts/{}/relations", id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            relations: Vec<ArtifactRelationRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.relations)
    }
}
