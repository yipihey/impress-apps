//! `ImbibTagsService` method clients.

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::library_service::{MutationResult, PublicationSummary};
use imbib_service::tags_service::{TagRecord, TagWithCount};

#[derive(Deserialize)]
struct Ok {
    status: String,
}
fn ok(s: &Ok) -> Result<()> {
    if s.status == "ok" {
        Ok(())
    } else {
        Err(AppClientError::Api(s.status.clone()))
    }
}

impl ImbibClient {
    pub async fn list_tags(&self) -> Result<Vec<TagRecord>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            tags: Vec<TagRecord>,
        }
        let url = self.base_url.join("/api/tags")?;
        let resp = self.http.get(url).send().await?;
        let body: R = decode_envelope(resp).await?;
        ok(&Ok {
            status: body.status,
        })?;
        Ok(body.tags)
    }

    pub async fn list_tags_with_counts(&self) -> Result<Vec<TagWithCount>> {
        #[derive(Deserialize)]
        struct R {
            status: String,
            tags: Vec<TagWithCount>,
        }
        let mut url = self.base_url.join("/api/tags")?;
        url.query_pairs_mut().append_pair("with_counts", "true");
        let resp = self.http.get(url).send().await?;
        let body: R = decode_envelope(resp).await?;
        ok(&Ok {
            status: body.status,
        })?;
        Ok(body.tags)
    }

    pub async fn create_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<MutationResult> {
        let url = self.base_url.join("/api/tags")?;
        let body = json!({"path": path, "color_light": color_light, "color_dark": color_dark});
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound("POST /api/tags (Phase D)".into()));
        }
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn delete_tag_undoable(&self, path: String) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/tags/{}", urlencoding::encode(&path)))?;
        let resp = self.http.delete(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(format!(
                "DELETE /api/tags/{} (Phase D)",
                path
            )));
        }
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn update_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<MutationResult> {
        let url = self
            .base_url
            .join(&format!("/api/tags/{}", urlencoding::encode(&path)))?;
        let body = json!({"color_light": color_light, "color_dark": color_dark});
        let resp = self.http.put(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(format!(
                "PUT /api/tags/{} (Phase D)",
                path
            )));
        }
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn rename_tag(&self, old_path: String, new_path: String) -> Result<MutationResult> {
        let url = self.base_url.join(&format!(
            "/api/tags/{}/rename",
            urlencoding::encode(&old_path)
        ))?;
        let resp = self
            .http
            .put(url)
            .json(&json!({"new_path": new_path}))
            .send()
            .await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(
                "PUT /api/tags/{path}/rename (Phase D)".into(),
            ));
        }
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }

    pub async fn add_tag(&self, ids: Vec<String>, tag_path: String) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers/tags")?;
        let body = json!({"identifiers": ids, "tag": tag_path, "action": "add"});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn remove_tag(&self, ids: Vec<String>, tag_path: String) -> Result<MutationResult> {
        let n = ids.len() as u32;
        let url = self.base_url.join("/api/papers/tags")?;
        let body = json!({"identifiers": ids, "tag": tag_path, "action": "remove"});
        let resp = self.http.put(url).json(&body).send().await?;
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Ok(MutationResult {
            affected_count: n,
            ok: true,
        })
    }

    pub async fn query_by_tag(
        &self,
        tag_path: String,
        parent_id: Option<String>,
        _sort_field: String,
        _ascending: bool,
        limit: u32,
    ) -> Result<Vec<PublicationSummary>> {
        self.search_with_params(
            None,
            Some(tag_path),
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

    pub async fn count_by_tag(&self, tag_path: String, parent_id: Option<String>) -> Result<u32> {
        let mut url = self.base_url.join("/api/papers/count/by-tag")?;
        url.query_pairs_mut().append_pair("tag", &tag_path);
        if let Some(pid) = parent_id {
            url.query_pairs_mut().append_pair("parent_id", &pid);
        }
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
        ok(&Ok {
            status: body.status,
        })?;
        Ok(body.count)
    }
}
