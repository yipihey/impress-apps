//! `ImprintAppService` method clients — the endpoints only the running imprint
//! app can answer (comments, content edits, the compiled PDF, logs).

use serde::Deserialize;
use serde_json::json;

use crate::error::{AppClientError, Result};
use crate::imprint::ImprintClient;
use crate::transport::decode_envelope;

use imprint_service::app_service::{AppStatus, CommentRecord, CompiledPdf, LogEntry};

impl ImprintClient {
    /// `GET /api/status`
    pub async fn app_status_raw(&self) -> Result<AppStatus> {
        let url = self.base_url.join("/api/status")?;
        let text = self.http.get(url).send().await?.text().await?;
        Ok(AppStatus {
            running: true,
            detail: text,
        })
    }

    /// `GET /api/logs` — nested `{status, data: {entries}}`, like imbib's.
    pub async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
    ) -> Result<Vec<LogEntry>> {
        let mut url = self.base_url.join("/api/logs")?;
        {
            let mut q = url.query_pairs_mut();
            if limit > 0 {
                q.append_pair("limit", &limit.to_string());
            }
            for (key, value) in [("level", level), ("category", category)] {
                if let Some(v) = value.as_deref().filter(|v| !v.is_empty()) {
                    q.append_pair(key, v);
                }
            }
        }
        #[derive(Deserialize)]
        struct Data {
            #[serde(default)]
            entries: Vec<LogEntry>,
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            data: Option<Data>,
            #[serde(default)]
            entries: Vec<LogEntry>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(match body.data {
            Some(d) if !d.entries.is_empty() => d.entries,
            _ => body.entries,
        })
    }

    /// `POST /api/documents`
    pub async fn create_document(
        &self,
        title: String,
        format: Option<String>,
    ) -> Result<Option<String>> {
        let url = self.base_url.join("/api/documents")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            id: Option<String>,
            #[serde(default, alias = "documentId", alias = "documentID")]
            document_id: Option<String>,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "title": title, "format": format }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.id.or(body.document_id))
    }

    /// `POST /api/documents/{id}/update`
    pub async fn update_document(&self, document_id: &str, title: Option<String>) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/update",
            urlencoding::encode(document_id)
        ))?;
        Ok(self
            .http
            .post(url)
            .json(&json!({ "title": title }))
            .send()
            .await?
            .status()
            .is_success())
    }

    /// `POST /api/documents/{id}/metadata`
    pub async fn update_metadata(&self, document_id: &str, metadata_json: String) -> Result<bool> {
        let body: serde_json::Value =
            serde_json::from_str(&metadata_json).unwrap_or(serde_json::json!({}));
        let url = self.base_url.join(&format!(
            "/api/documents/{}/metadata",
            urlencoding::encode(document_id)
        ))?;
        Ok(self
            .http
            .post(url)
            .json(&body)
            .send()
            .await?
            .status()
            .is_success())
    }

    /// `GET /api/documents/{id}/content`
    pub async fn get_content(&self, document_id: &str) -> Result<Option<String>> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/content",
            urlencoding::encode(document_id)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            content: Option<String>,
            #[serde(default)]
            source: Option<String>,
        }
        let body: R = decode_envelope(resp).await?;
        Ok(body.content.or(body.source))
    }

    /// `POST /api/documents/{id}/insert`
    pub async fn insert_text(&self, document_id: &str, offset: u32, text: String) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/insert",
            urlencoding::encode(document_id)
        ))?;
        let resp = self
            .http
            .post(url)
            .json(&json!({ "offset": offset, "text": text }))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    /// `POST /api/documents/{id}/delete`
    pub async fn delete_text(&self, document_id: &str, offset: u32, length: u32) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/delete",
            urlencoding::encode(document_id)
        ))?;
        let resp = self
            .http
            .post(url)
            .json(&json!({ "offset": offset, "length": length }))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    /// `POST /api/documents/{id}/replace`
    pub async fn replace_all(
        &self,
        document_id: &str,
        find: String,
        replace: String,
    ) -> Result<u32> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/replace",
            urlencoding::encode(document_id)
        ))?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default, alias = "replacements", alias = "count")]
            replaced: u32,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "find": find, "replace": replace }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.replaced)
    }

    /// `GET /api/documents/{id}/pdf`
    pub async fn get_pdf(&self, document_id: &str) -> Result<CompiledPdf> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/pdf",
            urlencoding::encode(document_id)
        ))?;
        let body: CompiledPdf = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(body)
    }

    /// `GET /api/documents/{id}/bibliography`
    pub async fn get_bibliography(&self, document_id: &str) -> Result<Option<String>> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/bibliography",
            urlencoding::encode(document_id)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            bibtex: Option<String>,
            #[serde(default)]
            bibliography: Option<String>,
        }
        let body: R = decode_envelope(resp).await?;
        Ok(body.bibtex.or(body.bibliography))
    }

    /// `GET /api/documents/{id}/comments`
    pub async fn list_comments(&self, document_id: &str) -> Result<Vec<CommentRecord>> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/comments",
            urlencoding::encode(document_id)
        ))?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            comments: Vec<CommentRecord>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(body.comments)
    }

    /// `POST /api/documents/{id}/comments`
    ///
    /// Three things were wrong here and each one produced the same silent
    /// `null`, which is why this looked like "comments do not work":
    ///
    /// * The field is `content`. This sent `body`, so imprint answered
    ///   `400 Missing 'content'`.
    /// * imprint anchors comments by character offsets, not by quoted text —
    ///   there is no `anchor` field. The quoted anchor is resolved to offsets
    ///   here by locating it in the document's own source.
    /// * The response struct had a single `#[serde(default)]` field, so an
    ///   error envelope parsed cleanly into `comment: None` and the failure
    ///   was indistinguishable from "no comment was created".
    ///
    /// A comment also requires the document to be OPEN in imprint; the app
    /// answers "No comment service registered … is it open?", which now
    /// reaches the caller instead of being swallowed.
    pub async fn create_comment(
        &self,
        document_id: &str,
        body_text: String,
        anchor: Option<String>,
    ) -> Result<Option<CommentRecord>> {
        // Resolve the quoted anchor to offsets against the live source.
        let (start, end) = match anchor.as_deref().filter(|a| !a.is_empty()) {
            Some(needle) => {
                let source = self.get_content(document_id).await?.unwrap_or_default();
                match source.find(needle) {
                    Some(at) => (at, at + needle.len()),
                    None => {
                        return Err(AppClientError::Api(format!(
                            "anchor text not found in document {document_id}: {needle:?}. \
                             The comment was not created. Anchor must be an exact substring \
                             of the document source (see imprint-app-service_get-content)."
                        )))
                    }
                }
            }
            None => (0, 0),
        };

        let url = self.base_url.join(&format!(
            "/api/documents/{}/comments",
            urlencoding::encode(document_id)
        ))?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            status: Option<String>,
            #[serde(default)]
            error: Option<String>,
            #[serde(default)]
            comment: Option<CommentRecord>,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({
                    "content": body_text,
                    "start": start,
                    "end": end,
                }))
                .send()
                .await?,
        )
        .await?;
        if let Some(message) = body.error {
            return Err(AppClientError::Api(message));
        }
        if body.status.as_deref() == Some("error") {
            return Err(AppClientError::Api(format!(
                "imprint refused the comment on {document_id}"
            )));
        }
        Ok(body.comment)
    }

    /// `PATCH /api/comments/{id}`
    pub async fn update_comment(
        &self,
        comment_id: &str,
        body_text: Option<String>,
        status: Option<String>,
    ) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/comments/{}",
            urlencoding::encode(comment_id)
        ))?;
        let resp = self
            .http
            .patch(url)
            .json(&json!({ "body": body_text, "status": status }))
            .send()
            .await?;
        Ok(resp.status().is_success())
    }

    /// `DELETE /api/comments/{id}`
    pub async fn delete_comment(&self, comment_id: &str) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/comments/{}",
            urlencoding::encode(comment_id)
        ))?;
        let resp = self.http.delete(url).send().await?;
        Ok(resp.status().is_success())
    }
}
