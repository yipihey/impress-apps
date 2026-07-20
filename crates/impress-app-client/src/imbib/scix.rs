//! `ImbibScixService` method clients.

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::library_service::{MutationResult, PublicationSummary};
use imbib_service::scix_service::SciXLibraryRecord;

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
    pub async fn list_scix_libraries(&self) -> Result<Vec<SciXLibraryRecord>> {
        let url = self.base_url.join("/api/scix-libraries")?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            libraries: Vec<SciXLibraryRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.libraries)
    }

    pub async fn get_scix_library(&self, id: String) -> Result<Option<SciXLibraryRecord>> {
        let url = self.base_url.join(&format!("/api/scix-libraries/{}", id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            library: SciXLibraryRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.library))
    }

    pub async fn create_scix_library(
        &self,
        remote_id: String,
        name: String,
        description: Option<String>,
        is_public: bool,
        permission_level: String,
        owner_email: Option<String>,
    ) -> Result<Option<SciXLibraryRecord>> {
        let url = self.base_url.join("/api/scix-libraries")?;
        let body = json!({
            "remote_id": remote_id,
            "name": name,
            "description": description,
            "is_public": is_public,
            "permission_level": permission_level,
            "owner_email": owner_email,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "POST /api/scix-libraries (Phase D)".into(),
            ));
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            library: SciXLibraryRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.library))
    }

    pub async fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> Result<MutationResult> {
        let n = publication_ids.len() as u32;
        let url = self
            .base_url
            .join(&format!("/api/scix-libraries/{}/papers", scix_library_id))?;
        let resp = self
            .http
            .post(url)
            .json(&json!({"publication_ids": publication_ids}))
            .send()
            .await?;
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn remove_from_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> Result<MutationResult> {
        let n = publication_ids.len() as u32;
        let url = self
            .base_url
            .join(&format!("/api/scix-libraries/{}/papers", scix_library_id))?;
        let resp = self
            .http
            .delete(url)
            .json(&json!({"publication_ids": publication_ids}))
            .send()
            .await?;
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<PublicationSummary>> {
        let lim = if limit == 0 { 50 } else { limit };
        let mut url = self
            .base_url
            .join(&format!("/api/scix-libraries/{}/papers", scix_library_id))?;
        url.query_pairs_mut()
            .append_pair("limit", &lim.to_string())
            .append_pair("offset", &offset.to_string());
        let resp = self.http.get(url).send().await?;
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

    pub async fn count_scix_library_publications(&self, scix_library_id: String) -> Result<u32> {
        let url = self.base_url.join(&format!(
            "/api/scix-libraries/{}/papers/count",
            scix_library_id
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(0);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            count: u32,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.count)
    }
}
