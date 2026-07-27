//! `ImbibAnnotationsService` method clients.

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::annotations_service::{AnnotationRecord, CommentRecord};
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
    pub async fn list_annotations(
        &self,
        linked_file_id: String,
        page_number: Option<i32>,
    ) -> Result<Vec<AnnotationRecord>> {
        // imbib uses /api/papers/{citeKey}/annotations (paper-scoped), not file-scoped.
        // Translate: get cite-key from publication id (if linked_file_id is actually a pub id).
        // For an actual linked_file_id (which is a UUID for the file, not paper), the route
        // we'd add in Phase D is /api/files/{id}/annotations.
        let mut url = self
            .base_url
            .join(&format!("/api/files/{}/annotations", linked_file_id))?;
        if let Some(p) = page_number {
            url.query_pairs_mut().append_pair("page", &p.to_string());
        }
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            annotations: Vec<AnnotationRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.annotations)
    }

    pub async fn count_annotations(&self, linked_file_id: String) -> Result<u32> {
        let url = self
            .base_url
            .join(&format!("/api/files/{}/annotations/count", linked_file_id))?;
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

    // Arity mirrors imbib's annotation payload, which mirrors the tool schema.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_annotation(
        &self,
        linked_file_id: String,
        annotation_type: String,
        page_number: i64,
        bounds_json: Option<String>,
        color: Option<String>,
        contents: Option<String>,
        selected_text: Option<String>,
    ) -> Result<Option<AnnotationRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/files/{}/annotations", linked_file_id))?;
        let body = json!({
            "type": annotation_type,
            "page": page_number,
            "bounds": bounds_json,
            "color": color,
            "contents": contents,
            "selected_text": selected_text,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            #[serde(default)]
            annotation: Option<AnnotationRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.annotation)
    }

    pub async fn list_comments_for_item(&self, item_id: String) -> Result<Vec<CommentRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/items/{}/comments", item_id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            comments: Vec<CommentRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.comments)
    }

    pub async fn list_comments(&self, publication_id: String) -> Result<Vec<CommentRecord>> {
        let cite_key = self.resolve_cite_key(&publication_id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}/comments",
            urlencoding::encode(&cite_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            comments: Vec<CommentRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.comments)
    }

    pub async fn list_comments_since(
        &self,
        item_id: String,
        since_clock: u64,
    ) -> Result<Vec<CommentRecord>> {
        let mut url = self
            .base_url
            .join(&format!("/api/items/{}/comments", item_id))?;
        url.query_pairs_mut()
            .append_pair("since_clock", &since_clock.to_string());
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            comments: Vec<CommentRecord>,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(body.comments)
    }

    pub async fn create_comment(
        &self,
        publication_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<Option<CommentRecord>> {
        let cite_key = self.resolve_cite_key(&publication_id).await?;
        let url = self.base_url.join(&format!(
            "/api/papers/{}/comments",
            urlencoding::encode(&cite_key)
        ))?;
        let body = json!({
            "text": text,
            "author_identifier": author_identifier,
            "author_display_name": author_display_name,
            "parent_comment_id": parent_comment_id,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            comment: CommentRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.comment))
    }

    pub async fn create_comment_on_item(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<Option<CommentRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/items/{}/comments", item_id))?;
        let body = json!({
            "text": text,
            "author_identifier": author_identifier,
            "author_display_name": author_display_name,
            "parent_comment_id": parent_comment_id,
        });
        let resp = self.http.post(url).json(&body).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            status: String,
            comment: CommentRecord,
        }
        let body: R = decode_envelope(resp).await?;
        check(&StatusEnvelope {
            status: body.status,
        })?;
        Ok(Some(body.comment))
    }

    pub async fn update_comment(&self, id: String, text: String) -> Result<MutationResult> {
        let url = self.base_url.join(&format!("/api/comments/{}", id))?;
        let resp = self
            .http
            .put(url)
            .json(&json!({"text": text}))
            .send()
            .await?;
        let s: StatusEnvelope = decode_envelope(resp).await?;
        check(&s)?;
        Ok(MutationResult {
            affected_count: 1,
            ok: true,
        })
    }
}
