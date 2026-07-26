//! `ImbibManuscriptsService` method clients — imbib serves manuscripts because
//! they are shared-store rows (ADR-0018), even though imprint authors them.

use serde::Deserialize;
use serde_json::json;

use crate::error::Result;
use crate::imbib::ImbibClient;
use crate::transport::decode_envelope;

use imbib_service::manuscripts_service::{
    CompileResult, ManuscriptRecord, TemplateRecord, WriteResult,
};

impl ImbibClient {
    /// `GET /api/manuscripts`
    pub async fn list_manuscripts(&self) -> Result<Vec<ManuscriptRecord>> {
        let url = self.base_url.join("/api/manuscripts")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            manuscripts: Vec<ManuscriptRecord>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(body.manuscripts)
    }

    /// `GET /api/manuscripts/{id}`
    pub async fn get_manuscript(&self, id: &str) -> Result<Option<ManuscriptRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/manuscripts/{}", urlencoding::encode(id)))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        // GET returns the manuscript FLAT — {id, title, format, contentHash,
        // manuscriptStatus, body, ...} — while the list route wraps in
        // {manuscripts: [...]}. Parse the top level; a `manuscript` key is
        // accepted too so a future wrap does not silently return None.
        #[derive(Deserialize)]
        struct Wrapped {
            manuscript: ManuscriptRecord,
        }
        let mut value: serde_json::Value = decode_envelope(resp).await?;
        if let Ok(w) = serde_json::from_value::<Wrapped>(value.clone()) {
            return Ok(Some(w.manuscript));
        }
        // On the flat detail route `status` is the ENVELOPE marker ("ok") while
        // the manuscript's own state is `manuscriptStatus`. ManuscriptRecord
        // aliases one onto the other, so leaving both in place makes serde see
        // a duplicate field and fail — silently, since we fall back to None.
        // Drop the envelope key before parsing.
        if let Some(obj) = value.as_object_mut() {
            if obj.contains_key("manuscriptStatus") {
                obj.remove("status");
            }
        }
        Ok(serde_json::from_value::<ManuscriptRecord>(value).ok())
    }

    /// `POST /api/manuscripts`
    pub async fn create_manuscript(
        &self,
        title: String,
        format: Option<String>,
    ) -> Result<Option<ManuscriptRecord>> {
        let url = self.base_url.join("/api/manuscripts")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            manuscript: Option<ManuscriptRecord>,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "title": title, "format": format }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.manuscript)
    }

    /// `PUT /api/manuscripts/{id}/body` — compare-and-set.
    pub async fn write_manuscript_body(
        &self,
        id: &str,
        body_text: String,
        expected_hash: String,
    ) -> Result<WriteResult> {
        let url = self.base_url.join(&format!(
            "/api/manuscripts/{}/body",
            urlencoding::encode(id)
        ))?;
        let resp = self
            .http
            .put(url)
            .json(&json!({ "body": body_text, "expectedHash": expected_hash }))
            .send()
            .await?;
        // 409 is the CAS failure and is the whole reason expected_hash exists:
        // report it as a refusal, not a transport error.
        if resp.status() == reqwest::StatusCode::CONFLICT {
            return Ok(WriteResult {
                ok: false,
                content_hash: None,
                message: "Someone else wrote to this manuscript since you read it. \
                          Re-read it with get_manuscript and re-apply your change."
                    .into(),
            });
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default, alias = "contentHash")]
            content_hash: Option<String>,
        }
        let parsed: R = decode_envelope(resp).await?;
        Ok(WriteResult {
            ok: true,
            content_hash: parsed.content_hash,
            message: "Manuscript body replaced.".into(),
        })
    }

    /// `POST /api/manuscripts/{id}/compile`
    pub async fn compile_manuscript(&self, id: &str) -> Result<CompileResult> {
        let url = self.base_url.join(&format!(
            "/api/manuscripts/{}/compile",
            urlencoding::encode(id)
        ))?;
        let body: CompileResult = decode_envelope(self.http.post(url).send().await?).await?;
        Ok(body)
    }

    /// `GET /api/templates`
    pub async fn list_templates(&self) -> Result<Vec<TemplateRecord>> {
        let url = self.base_url.join("/api/templates")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            templates: Vec<TemplateRecord>,
        }
        let body: R = decode_envelope(self.http.get(url).send().await?).await?;
        Ok(body.templates)
    }

    /// `POST /api/manuscripts/from-template`
    pub async fn create_manuscript_from_template(
        &self,
        template_id: String,
        title: String,
    ) -> Result<Option<ManuscriptRecord>> {
        let url = self.base_url.join("/api/manuscripts/from-template")?;
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            manuscript: Option<ManuscriptRecord>,
        }
        let body: R = decode_envelope(
            self.http
                .post(url)
                .json(&json!({ "templateId": template_id, "title": title }))
                .send()
                .await?,
        )
        .await?;
        Ok(body.manuscript)
    }
}
