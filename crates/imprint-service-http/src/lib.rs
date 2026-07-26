//! HTTP-backed implementations of the imprint service traits.
//!
//! Mirrors `imbib-service-http`. Install at startup via
//! `maybe_install_http_backend()` — probes `localhost:23121` and registers
//! the HTTP backend with imprint-service. Otherwise imprint-service falls
//! back to its default SQLite-backed handlers.

use std::sync::Arc;

use impress_app_client::ImprintClient;

use imprint_service::app_service::{
    AppStatus, CommentRecord, CompiledPdf, ImprintAppService, LogEntry,
};
use imprint_service::handlers::LatexCompileResultDto;
use imprint_service::handlers::{
    CitationUsage, CompileOptions, CompileResult, DocumentSummary, Outline, ReplaceResult,
    TextMatch,
};
use imprint_service::manuscript_service::{ImprintManuscriptService, SearchHitDto};
use imprint_service::sections::{SectionMetadata, SectionRecord};
use imprint_service::text_service::{CiteKeyUsageType as CiteKeyUsage, ImprintTextService};
use imprint_service::ImprintBackend;

fn log_err(method: &str, e: impl std::fmt::Display) {
    eprintln!("[imprint-service-http] {method}: {e}");
}

// =====================================================================
// HttpImprintManuscriptService
// =====================================================================
pub struct HttpImprintManuscriptService {
    client: Arc<ImprintClient>,
}
impl HttpImprintManuscriptService {
    pub fn new(client: Arc<ImprintClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImprintManuscriptService for HttpImprintManuscriptService {
    async fn list_documents(&self) -> Vec<DocumentSummary> {
        self.client.list_documents().await.unwrap_or_else(|e| {
            log_err("list_documents", e);
            vec![]
        })
    }
    async fn get_document(&self, id: String) -> Option<DocumentSummary> {
        self.client.get_document(&id).await.unwrap_or_else(|e| {
            log_err("get_document", e);
            None
        })
    }
    async fn export_document(&self, id: String, format: String) -> Vec<u8> {
        let fmt = match format.to_ascii_lowercase().as_str() {
            "latex" | "tex" => imprint_service::handlers::ExportFormat::Latex,
            "text" | "txt" => imprint_service::handlers::ExportFormat::Text,
            _ => imprint_service::handlers::ExportFormat::Typst,
        };
        self.client
            .export_document(&id, fmt)
            .await
            .unwrap_or_else(|e| {
                log_err("export_document", e);
                vec![]
            })
    }
    async fn list_sections(&self, doc_id: String) -> Vec<SectionRecord> {
        self.client
            .list_sections(&doc_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_sections", e);
                vec![]
            })
    }
    async fn get_section(&self, doc_id: String, section_key: String) -> Option<SectionRecord> {
        self.client
            .get_section(&doc_id, &section_key)
            .await
            .unwrap_or_else(|e| {
                log_err("get_section", e);
                None
            })
    }
    async fn put_section(
        &self,
        doc_id: String,
        section_key: String,
        body: String,
        metadata: SectionMetadata,
    ) -> Option<SectionRecord> {
        self.client
            .put_section(&doc_id, &section_key, &body, metadata)
            .await
            .unwrap_or_else(|e| {
                log_err("put_section", e);
                None
            })
    }
    async fn delete_section(&self, doc_id: String, section_key: String) -> bool {
        self.client
            .delete_section(&doc_id, &section_key)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_section", e);
                false
            })
    }
    async fn document_outline(&self, source: String) -> Outline {
        self.client
            .document_outline(&source)
            .await
            .unwrap_or_else(|e| {
                log_err("document_outline", e);
                Outline { entries: vec![] }
            })
    }
    async fn document_citations(&self, source: String) -> Vec<CitationUsage> {
        self.client
            .document_citations(&source)
            .await
            .unwrap_or_else(|e| {
                log_err("document_citations", e);
                vec![]
            })
    }
    async fn search_in_text(
        &self,
        source: String,
        query: String,
        case_sensitive: bool,
    ) -> Vec<TextMatch> {
        self.client
            .search_in_text(&source, &query, case_sensitive)
            .await
            .unwrap_or_else(|e| {
                log_err("search_in_text", e);
                vec![]
            })
    }
    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult {
        match self.client.compile_typst(&source, options).await {
            Ok(r) => r,
            Err(e) => {
                let msg = format!("{e}");
                log_err("compile_typst", &msg);
                CompileResult {
                    pdf_data: None,
                    error: Some(msg),
                    warnings: vec![],
                    page_count: 0,
                }
            }
        }
    }
    async fn compile_latex(
        &self,
        source: String,
        filesystem_root: String,
    ) -> LatexCompileResultDto {
        // Tectonic is self-contained → compile in-process (no HTTP route needed).
        // Run on a blocking thread: Tectonic's bundle fetch uses its own runtime.
        tokio::task::spawn_blocking(move || {
            let root = if filesystem_root.is_empty() {
                None
            } else {
                Some(filesystem_root.as_str())
            };
            imprint_service::handlers::compile_latex_dispatch(&source, root)
        })
        .await
        .unwrap_or_else(|e| LatexCompileResultDto {
            pdf_len: 0,
            diagnostics: vec![],
            error: Some(format!("compile task failed: {e}")),
            compile_ms: 0,
        })
    }
    async fn search(&self, query: String, limit: u32) -> Vec<SearchHitDto> {
        self.client.search(&query, limit).await.unwrap_or_else(|e| {
            log_err("search", e);
            vec![]
        })
    }
    async fn replace_in_section(
        &self,
        doc_id: String,
        section_key: String,
        find: String,
        replace: String,
    ) -> ReplaceResult {
        self.client
            .replace_in_section(&doc_id, &section_key, &find, &replace)
            .await
            .unwrap_or_else(|e| {
                log_err("replace_in_section", e);
                ReplaceResult {
                    replacements: 0,
                    new_body: String::new(),
                }
            })
    }
}

// =====================================================================
// HttpImprintTextService
// =====================================================================

/// Imprint's text service is stateless (LaTeX format, cite-key extract).
/// We could run it in-process — but for symmetry with imbib, route through
/// the HTTP backend when one is installed. Falls back to in-process
/// computation via the default impl. (Until an imprint HTTP route exists,
/// this just delegates to the default impl.)
pub struct HttpImprintTextService {
    _client: Arc<ImprintClient>,
}

impl HttpImprintTextService {
    pub fn new(client: Arc<ImprintClient>) -> Self {
        Self { _client: client }
    }
}

#[async_trait::async_trait]
impl ImprintTextService for HttpImprintTextService {
    async fn format_latex(&self, source: String) -> String {
        // No imprint HTTP route for LaTeX formatting; compute in-process.
        let default = imprint_service::text_service::DefaultImprintTextService;
        default.format_latex(source).await
    }
    async fn extract_cite_keys(&self, source: String, syntax: String) -> Vec<String> {
        let default = imprint_service::text_service::DefaultImprintTextService;
        default.extract_cite_keys(source, syntax).await
    }
    async fn extract_cite_key_usages(&self, source: String, syntax: String) -> Vec<CiteKeyUsage> {
        let default = imprint_service::text_service::DefaultImprintTextService;
        default.extract_cite_key_usages(source, syntax).await
    }
    async fn compose_citation(
        &self,
        cite_key: String,
        format: String,
        append_space: bool,
    ) -> String {
        // Pure/stateless — compute in-process (no HTTP route needed).
        let default = imprint_service::text_service::DefaultImprintTextService;
        default
            .compose_citation(cite_key, format, append_space)
            .await
    }
    async fn compose_heading(&self, title: String, level: i64, format: String) -> String {
        let default = imprint_service::text_service::DefaultImprintTextService;
        default.compose_heading(title, level, format).await
    }
}

// =====================================================================
// Backend bundle + installer
// =====================================================================

// ---------------------------------------------------------------------------
// ImprintAppService — capabilities that only exist while imprint is running
// ---------------------------------------------------------------------------

pub struct HttpImprintAppService {
    client: Arc<ImprintClient>,
}

impl HttpImprintAppService {
    pub fn new(client: Arc<ImprintClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImprintAppService for HttpImprintAppService {
    async fn status(&self) -> AppStatus {
        self.client.app_status_raw().await.unwrap_or_else(|e| {
            let detail = format!("imprint did not answer: {e}");
            log_err("status", e);
            AppStatus {
                running: false,
                detail,
            }
        })
    }

    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
    ) -> Vec<LogEntry> {
        self.client
            .get_logs(limit, level, category)
            .await
            .unwrap_or_else(|e| {
                log_err("get_logs", e);
                vec![]
            })
    }

    async fn get_content(&self, document_id: String) -> Option<String> {
        self.client
            .get_content(&document_id)
            .await
            .unwrap_or_else(|e| {
                log_err("get_content", e);
                None
            })
    }

    async fn insert_text(&self, document_id: String, offset: u32, text: String) -> bool {
        self.client
            .insert_text(&document_id, offset, text)
            .await
            .unwrap_or_else(|e| {
                log_err("insert_text", e);
                false
            })
    }

    async fn delete_text(&self, document_id: String, offset: u32, length: u32) -> bool {
        self.client
            .delete_text(&document_id, offset, length)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_text", e);
                false
            })
    }

    async fn replace(&self, document_id: String, find: String, replace: String) -> u32 {
        self.client
            .replace_all(&document_id, find, replace)
            .await
            .unwrap_or_else(|e| {
                log_err("replace", e);
                0
            })
    }

    async fn get_pdf(&self, document_id: String) -> CompiledPdf {
        self.client.get_pdf(&document_id).await.unwrap_or_else(|e| {
            let msg = format!("could not compile or locate the PDF: {e}");
            log_err("get_pdf", e);
            CompiledPdf {
                ok: false,
                path: None,
                page_count: None,
                byte_size: None,
                messages: vec![msg],
            }
        })
    }

    async fn get_bibliography(&self, document_id: String) -> Option<String> {
        self.client
            .get_bibliography(&document_id)
            .await
            .unwrap_or_else(|e| {
                log_err("get_bibliography", e);
                None
            })
    }

    async fn list_comments(&self, document_id: String) -> Vec<CommentRecord> {
        self.client
            .list_comments(&document_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_comments", e);
                vec![]
            })
    }

    async fn create_comment(
        &self,
        document_id: String,
        body: String,
        anchor: Option<String>,
    ) -> Option<CommentRecord> {
        self.client
            .create_comment(&document_id, body, anchor)
            .await
            .unwrap_or_else(|e| {
                log_err("create_comment", e);
                None
            })
    }

    async fn update_comment(
        &self,
        comment_id: String,
        body: Option<String>,
        status: Option<String>,
    ) -> bool {
        self.client
            .update_comment(&comment_id, body, status)
            .await
            .unwrap_or_else(|e| {
                log_err("update_comment", e);
                false
            })
    }

    async fn delete_comment(&self, comment_id: String) -> bool {
        self.client
            .delete_comment(&comment_id)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_comment", e);
                false
            })
    }
}

pub struct HttpBackend {
    client: Arc<ImprintClient>,
}
impl HttpBackend {
    pub fn new(client: Arc<ImprintClient>) -> Self {
        Self { client }
    }
}

impl ImprintBackend for HttpBackend {
    fn app(&self) -> Arc<dyn ImprintAppService> {
        Arc::new(HttpImprintAppService::new(self.client.clone()))
    }

    fn manuscript(&self) -> Arc<dyn ImprintManuscriptService> {
        Arc::new(HttpImprintManuscriptService::new(self.client.clone()))
    }
    fn text(&self) -> Arc<dyn ImprintTextService> {
        Arc::new(HttpImprintTextService::new(self.client.clone()))
    }
}

/// Probe the imprint HTTP server at the default port. If reachable, install
/// the HTTP backend so subsequent imprint-service trait calls route via
/// HTTP. Returns `true` on install.
///
/// Honors env vars:
/// * `IMPRINT_BACKEND` = `http` | `sqlite` | `auto` (default)
/// * `IMPRINT_HTTP_URL` overrides the default `http://localhost:23121`.
pub fn maybe_install_http_backend() -> bool {
    let mode = std::env::var("IMPRINT_BACKEND").unwrap_or_else(|_| "auto".into());
    if mode == "sqlite" {
        eprintln!("[imprint-service-http] IMPRINT_BACKEND=sqlite — skipping HTTP probe");
        return false;
    }

    let base_url = std::env::var("IMPRINT_HTTP_URL")
        .ok()
        .and_then(|s| url::Url::parse(&s).ok());
    let client = match base_url {
        Some(u) => Arc::new(ImprintClient::with_base_url(u)),
        None => Arc::new(ImprintClient::new()),
    };

    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio current_thread runtime");

    let info = rt.block_on(client.probe());
    match info {
        Some(info) => {
            eprintln!(
                "[imprint-service-http] imprint HTTP reachable (status={}, port {:?}); using HTTP backend",
                info.status, info.server_port,
            );
            imprint_service::register_backend(Box::new(HttpBackend::new(client)));
            true
        }
        None => {
            if mode == "http" {
                eprintln!(
                    "[imprint-service-http] IMPRINT_BACKEND=http but imprint HTTP unreachable; service calls will fail."
                );
            } else {
                eprintln!(
                    "[imprint-service-http] imprint HTTP unreachable; falling back to in-process imprint-service backend."
                );
            }
            false
        }
    }
}
