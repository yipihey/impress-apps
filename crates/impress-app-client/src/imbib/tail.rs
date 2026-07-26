//! The last of the imbib surface: notes, the missing deletes, artifact
//! tagging, identifier resolution and cross-library moves.
//!
//! These are the tools the earlier services left behind — each one a route
//! that had no trait method rather than a coherent area of its own, which is
//! why they arrive together at the end rather than as a service each.

use serde::Deserialize;
use serde_json::json;

use crate::error::Result;
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::library_service::{MutationResult, PublicationSummary};

fn ok(affected: u32) -> MutationResult {
    MutationResult {
        affected_count: affected,
        ok: true,
    }
}

impl ImbibClient {
    /// `GET /api/papers/{citeKey}/notes`
    pub async fn get_notes(&self, cite_key: &str) -> Result<Option<String>> {
        let url = self.base_url.join(&format!(
            "/api/papers/{}/notes",
            urlencoding::encode(cite_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            notes: Option<String>,
        }
        let body: R = decode_envelope(resp).await?;
        Ok(body.notes)
    }

    /// `PUT /api/papers/{citeKey}/notes`
    pub async fn update_notes(&self, cite_key: &str, notes: String) -> Result<MutationResult> {
        let url = self.base_url.join(&format!(
            "/api/papers/{}/notes",
            urlencoding::encode(cite_key)
        ))?;
        let resp = self
            .http
            .put(url)
            .json(&json!({ "notes": notes }))
            .send()
            .await?;
        Ok(if resp.status().is_success() {
            ok(1)
        } else {
            MutationResult {
                affected_count: 0,
                ok: false,
            }
        })
    }

    /// `DELETE /api/annotations/{id}`
    pub async fn delete_annotation(&self, annotation_id: &str) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/annotations/{}",
            urlencoding::encode(annotation_id)
        ))?;
        Ok(self.http.delete(url).send().await?.status().is_success())
    }

    /// `DELETE /api/comments/{id}`
    pub async fn delete_comment(&self, comment_id: &str) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/comments/{}",
            urlencoding::encode(comment_id)
        ))?;
        Ok(self.http.delete(url).send().await?.status().is_success())
    }

    /// `DELETE /api/collections/{id}`
    pub async fn delete_collection(&self, collection_id: &str) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/collections/{}",
            urlencoding::encode(collection_id)
        ))?;
        Ok(self.http.delete(url).send().await?.status().is_success())
    }

    /// `DELETE /api/smart-searches/{ids}` — comma-separated.
    pub async fn delete_smart_searches(&self, ids: Vec<String>) -> Result<u32> {
        if ids.is_empty() {
            return Ok(0);
        }
        let joined = ids.join(",");
        let url = self.base_url.join(&format!(
            "/api/smart-searches/{}",
            urlencoding::encode(&joined)
        ))?;
        let resp = self.http.delete(url).send().await?;
        Ok(if resp.status().is_success() {
            ids.len() as u32
        } else {
            0
        })
    }

    /// `PUT /api/artifacts/{id}/tags`
    pub async fn tag_artifact(&self, artifact_id: &str, tags: Vec<String>) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/artifacts/{}/tags",
            urlencoding::encode(artifact_id)
        ))?;
        Ok(self
            .http
            .put(url)
            .json(&json!({ "tags": tags }))
            .send()
            .await?
            .status()
            .is_success())
    }

    /// `POST /api/papers/resolve`
    pub async fn resolve_identifier(
        &self,
        identifier: String,
        download_pdfs: bool,
    ) -> Result<Option<PublicationSummary>> {
        let url = self.base_url.join("/api/papers/resolve")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            paper: Option<PublicationSummary>,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "query": identifier, "download_pdfs": download_pdfs }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.paper)
    }

    /// `POST /api/libraries/add-papers`
    pub async fn add_to_library(
        &self,
        publication_ids: Vec<String>,
        library_id: String,
    ) -> Result<MutationResult> {
        let url = self.base_url.join("/api/libraries/add-papers")?;
        let count = publication_ids.len() as u32;
        let resp = self
            .http
            .post(url)
            .json(&json!({ "ids": publication_ids, "libraryId": library_id }))
            .send()
            .await?;
        Ok(if resp.status().is_success() {
            ok(count)
        } else {
            MutationResult {
                affected_count: 0,
                ok: false,
            }
        })
    }
}
