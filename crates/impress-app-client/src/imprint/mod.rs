//! HTTP client for the imprint macOS app's automation API (default port 23121).

use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::json;
use url::Url;

use crate::error::{AppClientError, Result};
use crate::transport::decode_envelope;

use imprint_service::handlers::{
    CitationUsage, CompileOptions, CompileResult, DocumentSummary, ExportFormat, Outline,
    ReplaceResult, TextMatch,
};
use imprint_service::manuscript_service::SearchHitDto;
use imprint_service::sections::{SectionMetadata, SectionRecord};

const DEFAULT_BASE_URL: &str = "http://localhost:23121";

#[derive(Debug, Clone, Deserialize)]
pub struct ImprintServerInfo {
    pub status: String,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default, rename = "serverPort")]
    pub server_port: Option<u16>,
}

/// Typed client for imprint's `localhost:23121` HTTP API.
pub struct ImprintClient {
    base_url: Url,
    http: Client,
}

impl ImprintClient {
    pub fn new() -> Self {
        Self::with_base_url(Url::parse(DEFAULT_BASE_URL).expect("default URL parses"))
    }

    pub fn with_base_url(base_url: Url) -> Self {
        let http = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("reqwest client builds");
        Self { base_url, http }
    }

    /// Hit `GET /api/status` with a short timeout. `Some` on reachable.
    pub async fn probe(&self) -> Option<ImprintServerInfo> {
        let url = self.base_url.join("/api/status").ok()?;
        let resp = self
            .http
            .get(url)
            .timeout(Duration::from_secs(1))
            .send()
            .await
            .ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.json::<ImprintServerInfo>().await.ok()
    }
}

impl Default for ImprintClient {
    fn default() -> Self {
        Self::new()
    }
}

// ===========================================================================
// Document + section operations
// ===========================================================================

#[derive(Deserialize)]
struct Ok {
    status: String,
}
fn ok(s: &Ok) -> Result<()> {
    if s.status == "ok" { Result::Ok(()) } else { Err(AppClientError::Api(s.status.clone())) }
}

impl ImprintClient {
    pub async fn list_documents(&self) -> Result<Vec<DocumentSummary>> {
        let url = self.base_url.join("/api/documents")?;
        let resp = self.http.get(url).send().await?;
        #[derive(Deserialize)]
        struct R { status: String, #[serde(default)] documents: Vec<DocumentSummary> }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(body.documents)
    }

    pub async fn get_document(&self, id: &str) -> Result<Option<DocumentSummary>> {
        let url = self.base_url.join(&format!("/api/documents/{}", id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(None);
        }
        #[derive(Deserialize)]
        struct R { status: String, document: DocumentSummary }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(Some(body.document))
    }

    pub async fn list_sections(&self, doc_id: &str) -> Result<Vec<SectionRecord>> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{}/sections", doc_id))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(vec![]);
        }
        // imprint returns the outline-v2 shape: {status, documentId, count,
        // sections: [{id, title, level, sectionType, orderIndex, start, end,
        // bodyStart, wordCount}, ...]} — NO body text included for performance.
        // Translate each entry to a SectionRecord with empty body; callers
        // fetch full body via get_section as needed.
        let v: serde_json::Value = resp.json().await?;
        if v.get("status").and_then(|s| s.as_str()) != Some("ok") {
            return Err(AppClientError::Api(
                v.get("error").and_then(|s| s.as_str()).unwrap_or("unknown").into(),
            ));
        }
        let sections = v
            .get("sections")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        Result::Ok(
            sections
                .iter()
                .map(|s| swift_section_value_to_record(s, doc_id, "", ""))
                .collect(),
        )
    }

    pub async fn get_section(
        &self,
        doc_id: &str,
        section_key: &str,
    ) -> Result<Option<SectionRecord>> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/sections/{}",
            doc_id,
            urlencoding::encode(section_key)
        ))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(None);
        }
        // Swift returns a flat object: {status, documentId, id, title, level,
        // sectionType, orderIndex, start, end, body, wordCount, ...}.
        let v: serde_json::Value = resp.json().await?;
        if v.get("status").and_then(|s| s.as_str()) != Some("ok") {
            return Err(AppClientError::Api(
                v.get("error").and_then(|s| s.as_str()).unwrap_or("unknown").into(),
            ));
        }
        let body_text = v.get("body").and_then(|s| s.as_str()).unwrap_or("").to_string();
        Result::Ok(Some(swift_section_value_to_record(&v, doc_id, section_key, &body_text)))
    }

    pub async fn put_section(
        &self,
        doc_id: &str,
        section_key: &str,
        body: &str,
        metadata: SectionMetadata,
    ) -> Result<Option<SectionRecord>> {
        // imprint exposes PATCH (not PUT) for in-place body/title updates:
        //   PATCH /api/documents/{docId}/sections/{sectionKey}
        // body: {"body": "...", "title": "..."} — either is sufficient.
        let url = self.base_url.join(&format!(
            "/api/documents/{}/sections/{}",
            doc_id,
            urlencoding::encode(section_key)
        ))?;
        let mut payload = json!({"body": body});
        if let Some(t) = metadata.title.as_ref() {
            payload["title"] = serde_json::Value::String(t.clone());
        }
        let resp = self.http.patch(url).json(&payload).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            // Section doesn't exist yet — fall back to POST create.
            return self.create_section(doc_id, section_key, body, &metadata).await;
        }
        // Swift returns camelCase + extra fields ({status, documentId, id,
        // title, level, sectionType, orderIndex, start, end, body, ...}).
        // Translate via a flat Value -> SectionRecord builder so we don't
        // require Swift to change its response shape.
        let v: serde_json::Value = resp.json().await?;
        if v.get("status").and_then(|s| s.as_str()) != Some("ok") {
            return Err(AppClientError::Api(
                v.get("error").and_then(|s| s.as_str()).unwrap_or("unknown").into(),
            ));
        }
        Result::Ok(Some(swift_section_value_to_record(&v, doc_id, section_key, body)))
    }

    /// Internal: POST a new section. Used as fallback when PATCH 404s.
    async fn create_section(
        &self,
        doc_id: &str,
        _section_key: &str,
        body: &str,
        metadata: &SectionMetadata,
    ) -> Result<Option<SectionRecord>> {
        let url = self.base_url.join(&format!("/api/documents/{}/sections", doc_id))?;
        let payload = json!({
            "title": metadata.title.clone().unwrap_or_default(),
            "body": body,
            "level": 1,
            "position": "end",
        });
        let resp = self.http.post(url).json(&payload).send().await?;
        if !resp.status().is_success() {
            return Result::Ok(None);
        }
        let v: serde_json::Value = resp.json().await?;
        Result::Ok(Some(swift_section_value_to_record(
            &v,
            doc_id,
            metadata.title.as_deref().unwrap_or(""),
            body,
        )))
    }

    pub async fn delete_section(&self, doc_id: &str, section_key: &str) -> Result<bool> {
        let url = self.base_url.join(&format!(
            "/api/documents/{}/sections/{}",
            doc_id,
            urlencoding::encode(section_key)
        ))?;
        let resp = self.http.delete(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(false);
        }
        let s: Ok = decode_envelope(resp).await?;
        ok(&s)?;
        Result::Ok(true)
    }

    pub async fn document_outline(&self, source: &str) -> Result<Outline> {
        // imprint has a few outline endpoints — try the dedicated text route first.
        let url = self.base_url.join("/api/outline")?;
        let resp = self.http.post(url).json(&json!({"source": source})).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            // Fall back to in-process extraction (deterministic, no network).
            return Result::Ok(Outline {
                entries: imprint_service::handlers::extract_outline(source),
            });
        }
        #[derive(Deserialize)]
        struct R { status: String, outline: Outline }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(body.outline)
    }

    pub async fn document_citations(&self, source: &str) -> Result<Vec<CitationUsage>> {
        // imprint exposes citation-usages but for already-stored docs;
        // for arbitrary source, use the in-process extractor.
        Result::Ok(imprint_service::handlers::extract_citation_usages(source))
    }

    pub async fn search_in_text(
        &self,
        source: &str,
        query: &str,
        case_sensitive: bool,
    ) -> Result<Vec<TextMatch>> {
        // In-process. Reuses imprint-service's plain-text search.
        Result::Ok(imprint_service::handlers::search_text_plain(source, query, case_sensitive))
    }

    pub async fn compile_typst(
        &self,
        source: &str,
        options: CompileOptions,
    ) -> Result<CompileResult> {
        let url = self.base_url.join("/api/compile/typst")?;
        let payload = json!({"source": source, "options": options});
        let resp = self.http.post(url).json(&payload).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(imprint_service::handlers::compile_typst_dispatch(source, options));
        }
        // On success the endpoint returns the PDF *bytes* (Content-Type
        // application/pdf) with metadata in `X-Imprint-*` headers, not a JSON
        // envelope. On a compile error it returns JSON (422/500). Branch on the
        // content type so both shapes decode correctly.
        let is_pdf = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(|ct| ct.contains("application/pdf"))
            .unwrap_or(false);
        if is_pdf {
            let page_count = resp
                .headers()
                .get("X-Imprint-Page-Count")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(0);
            let warnings = resp
                .headers()
                .get("X-Imprint-Warnings")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.split("; ").map(|w| w.to_string()).collect::<Vec<_>>())
                .unwrap_or_default();
            let bytes = resp.bytes().await?;
            return Result::Ok(CompileResult {
                pdf_data: Some(bytes.to_vec()),
                error: None,
                warnings,
                page_count,
            });
        }
        #[derive(Deserialize)]
        struct R { status: String, #[serde(flatten)] result: CompileResult }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(body.result)
    }

    pub async fn search(&self, query: &str, limit: u32) -> Result<Vec<SearchHitDto>> {
        let mut url = self.base_url.join("/api/search")?;
        let lim = if limit == 0 { 50 } else { limit };
        url.query_pairs_mut()
            .append_pair("q", query)
            .append_pair("limit", &lim.to_string());
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(vec![]);
        }
        #[derive(Deserialize)]
        struct R { status: String, #[serde(default)] hits: Vec<SearchHitDto> }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(body.hits)
    }

    pub async fn replace_in_section(
        &self,
        doc_id: &str,
        section_key: &str,
        find: &str,
        replace: &str,
    ) -> Result<ReplaceResult> {
        let url = self.base_url.join(&format!("/api/documents/{}/replace", doc_id))?;
        let payload = json!({
            "section_key": section_key,
            "find": find,
            "replace": replace,
            "replace_all": true,
        });
        let resp = self.http.post(url).json(&payload).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(AppClientError::NotFound(format!("POST /api/documents/{}/replace", doc_id)));
        }
        #[derive(Deserialize)]
        struct R { status: String, #[serde(flatten)] result: ReplaceResult }
        let body: R = decode_envelope(resp).await?;
        ok(&Ok { status: body.status })?;
        Result::Ok(body.result)
    }

    pub async fn export_document(&self, id: &str, format: ExportFormat) -> Result<Vec<u8>> {
        let fmt = match format {
            ExportFormat::Typst => "typst",
            ExportFormat::Latex => "latex",
            ExportFormat::Text => "text",
        };
        let url = self.base_url.join(&format!("/api/documents/{}/export/{}", id, fmt))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(vec![]);
        }
        if !resp.status().is_success() {
            return Err(AppClientError::ServerError(resp.status().to_string()));
        }
        Result::Ok(resp.bytes().await?.to_vec())
    }
}

// ===========================================================================
// Swift response → Rust SectionRecord translator
// ===========================================================================
//
// imprint's `ImprintHTTPRouter` returns sections in its own camelCase
// shape: `{id, documentId, title, level, sectionType, orderIndex, start,
// end, bodyStart, body, wordCount}`. We translate to the Rust SectionRecord
// without requiring Swift-side changes — the imprint app already ships and
// other consumers (the running editor itself) depend on the existing shape.

fn swift_section_value_to_record(
    v: &serde_json::Value,
    fallback_doc_id: &str,
    fallback_section_key: &str,
    fallback_body: &str,
) -> SectionRecord {
    use uuid::Uuid;
    let item_id = v
        .get("id")
        .and_then(|s| s.as_str())
        .and_then(|s| Uuid::parse_str(s).ok())
        .unwrap_or_else(|| Uuid::nil());
    let document_id = v
        .get("documentId")
        .and_then(|s| s.as_str())
        .or(Some(fallback_doc_id))
        .and_then(|s| Uuid::parse_str(s).ok())
        .unwrap_or_else(|| Uuid::nil());
    let section_key = v
        .get("sectionKey")
        .and_then(|s| s.as_str())
        .map(String::from)
        .unwrap_or_else(|| {
            // imprint identifies sections by UUID, not by application-defined
            // key. Fall back to the id (or the caller-supplied key).
            if !fallback_section_key.is_empty() {
                fallback_section_key.to_string()
            } else {
                v.get("id").and_then(|s| s.as_str()).unwrap_or_default().to_string()
            }
        });
    let title = v.get("title").and_then(|s| s.as_str()).unwrap_or("").to_string();
    let body = v
        .get("body")
        .and_then(|s| s.as_str())
        .map(String::from)
        .unwrap_or_else(|| fallback_body.to_string());
    let section_type = v.get("sectionType").and_then(|s| s.as_str()).and_then(|s| {
        if s.is_empty() { None } else { Some(s.to_string()) }
    });
    let order_index = v.get("orderIndex").and_then(|n| n.as_i64());
    let word_count = v
        .get("wordCount")
        .and_then(|n| n.as_i64())
        .unwrap_or_else(|| body.split_whitespace().count() as i64);

    SectionRecord {
        item_id,
        document_id,
        section_key,
        title,
        body,
        section_type,
        order_index,
        word_count,
        content_hash: None,
        created_ms: 0,
    }
}

// ===========================================================================
// Throughline operations (ADR-0016)
// ===========================================================================

impl ImprintClient {
    /// GET /api/documents/{id}/throughline — `None` when the document has
    /// no throughline (the opt-in "off" state, HTTP 404).
    pub async fn get_throughline(&self, doc_id: &str) -> Result<Option<serde_json::Value>> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline"))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(None);
        }
        Result::Ok(Some(resp.json().await?))
    }

    /// POST /api/documents/{id}/throughline — explicit opt-in creation.
    /// `Err(Api("conflict"))` on HTTP 409 (already exists).
    pub async fn create_throughline(
        &self,
        doc_id: &str,
        title: &str,
    ) -> Result<serde_json::Value> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline"))?;
        let resp = self
            .http
            .post(url)
            .json(&serde_json::json!({ "title": title }))
            .send()
            .await?;
        if resp.status() == reqwest::StatusCode::CONFLICT {
            return Err(AppClientError::Api("conflict".into()));
        }
        Result::Ok(resp.json().await?)
    }

    /// GET /api/documents/{id}/throughline/anchors — derived states.
    pub async fn get_throughline_anchors(
        &self,
        doc_id: &str,
    ) -> Result<Option<serde_json::Value>> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline/anchors"))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(None);
        }
        Result::Ok(Some(resp.json().await?))
    }

    /// GET /api/documents/{id}/throughline/coverage.
    pub async fn get_throughline_coverage(
        &self,
        doc_id: &str,
    ) -> Result<Option<serde_json::Value>> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline/coverage"))?;
        let resp = self.http.get(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(None);
        }
        Result::Ok(Some(resp.json().await?))
    }

    /// PATCH /api/documents/{id}/throughline/anchors with a ledger action
    /// (`set` | `remove` | `mark-supporting`, see the route docs).
    pub async fn patch_throughline_anchors(
        &self,
        doc_id: &str,
        body: serde_json::Value,
    ) -> Result<serde_json::Value> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline/anchors"))?;
        let resp = self.http.patch(url).json(&body).send().await?;
        Result::Ok(resp.json().await?)
    }

    /// DELETE /api/documents/{id}/throughline — deactivation. Returns
    /// whether a throughline existed.
    pub async fn delete_throughline(&self, doc_id: &str) -> Result<bool> {
        let url = self
            .base_url
            .join(&format!("/api/documents/{doc_id}/throughline"))?;
        let resp = self.http.delete(url).send().await?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Result::Ok(false);
        }
        #[derive(Deserialize)]
        struct R {
            #[serde(default)]
            deleted: bool,
        }
        let body: R = resp.json().await?;
        Result::Ok(body.deleted)
    }
}
