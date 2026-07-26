//! `ImprintManuscriptService` — macro-wired wrapper around `ImprintHttpHandlers`.
//!
//! The handler trait was hand-written to mirror the Swift router 1:1; this
//! file promotes the methods to a `#[impress_service]` trait so they show up
//! as MCP tools, CLI subcommands, and future Python bindings.
//!
//! Method signatures are simplified for the macro: each method returns its
//! "happy path" value directly and logs errors to stderr (matching the
//! pattern in `imbib-service`'s services). Methods that take complex DTOs
//! (`SectionMetadata`, `CompileOptions`) accept them directly — both DTOs
//! derive `JsonSchema` so the macro can synthesize the args struct.

use std::sync::Arc;

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use uuid::Uuid;

use crate::handlers::{
    compile_latex_dispatch, CitationUsage, CompileOptions, CompileResult,
    DefaultImprintHttpHandlers, DocumentSummary, ExportFormat, ImprintHttpHandlers,
    LatexCompileResultDto, Outline, ReplaceResult, TextMatch,
};
use crate::search::SearchHit;
use crate::sections::{SectionMetadata, SectionRecord};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

#[impress_service]
pub trait ImprintManuscriptService: Send + Sync + 'static {
    /// List every manuscript document.
    #[impress_method]
    async fn list_documents(&self) -> Vec<DocumentSummary>;

    /// Fetch a single document by UUID.
    #[impress_method]
    async fn get_document(&self, id: String) -> Option<DocumentSummary>;

    /// Export a document in the given format. Returns the raw bytes.
    /// `format` is `"typst" | "latex" | "text"`.
    #[impress_method]
    async fn export_document(&self, id: String, format: String) -> Vec<u8>;

    // ---- Section CRUD ----
    /// List every stored section of a manuscript, sorted by order_index.
    /// Returns section id, title, body (inline), sectionType, orderIndex,
    /// wordCount, and createdAt. Large content-addressed bodies are not
    /// rehydrated here — call `imprint-manuscript-service_get-section` for those.
    #[impress_method]
    async fn list_sections(&self, doc_id: String) -> Vec<SectionRecord>;
    /// Fetch a single manuscript section by its UUID. Body is rehydrated
    /// from content-addressed storage when needed. Use this after
    /// `imprint-manuscript-service_list-sections` to load the full body of a specific
    /// section.
    #[impress_method]
    async fn get_section(&self, doc_id: String, section_key: String) -> Option<SectionRecord>;
    #[impress_method]
    async fn put_section(
        &self,
        doc_id: String,
        section_key: String,
        body: String,
        metadata: SectionMetadata,
    ) -> Option<SectionRecord>;
    /// Remove a section (heading + body) from the document. Queues an
    /// operation; returns operationId.
    #[impress_method]
    async fn delete_section(&self, doc_id: String, section_key: String) -> bool;

    // ---- Pure-text helpers ----
    #[impress_method]
    async fn document_outline(&self, source: String) -> Outline;
    #[impress_method]
    async fn document_citations(&self, source: String) -> Vec<CitationUsage>;
    #[impress_method]
    async fn search_in_text(
        &self,
        source: String,
        query: String,
        case_sensitive: bool,
    ) -> Vec<TextMatch>;

    // ---- Typst compile ----
    /// Compile an imprint document to PDF. Triggers the Typst compiler and
    /// generates output.
    #[impress_method]
    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult;

    // ---- LaTeX compile via embedded Tectonic (gated on tectonic-render) ----
    /// Compile LaTeX to PDF with the self-contained Tectonic engine. Returns
    /// PDF length + diagnostics (not raw bytes). `filesystem_root` resolves
    /// on-disk `\includegraphics`/`\input`; pass "" for none.
    #[impress_method]
    async fn compile_latex(&self, source: String, filesystem_root: String)
        -> LatexCompileResultDto;

    // ---- Cross-document search ----
    /// Search for text in an imprint document. Returns positions of all
    /// matches.
    #[impress_method]
    async fn search(&self, query: String, limit: u32) -> Vec<SearchHitDto>;

    // ---- Replace within a section ----
    #[impress_method]
    async fn replace_in_section(
        &self,
        doc_id: String,
        section_key: String,
        find: String,
        replace: String,
    ) -> ReplaceResult;
}

/// `SearchHit` from `imprint-service::search` doesn't derive `Serialize` or
/// `JsonSchema` yet, so wrap it in a JSON-able DTO for the macro pipeline.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SearchHitDto {
    pub item_id: String,
    pub document_id: String,
    pub section_key: String,
    pub title: String,
    pub excerpt: String,
    pub score: f32,
}

impl From<&SearchHit> for SearchHitDto {
    fn from(s: &SearchHit) -> Self {
        Self {
            item_id: s.item_id.to_string(),
            document_id: s.document_id.to_string(),
            section_key: s.section_key.clone(),
            title: s.title.clone(),
            excerpt: s.excerpt.clone().unwrap_or_default(),
            score: s.score,
        }
    }
}

// ---------------------------------------------------------------------------
// Default impl backed by ImprintHttpHandlers (which is backed by the shared store)
// ---------------------------------------------------------------------------

/// Wraps a `DefaultImprintHttpHandlers` and adapts its `Result`-returning
/// methods to the macro-friendly "return T, log errors" shape.
#[derive(Clone)]
pub struct DefaultImprintManuscriptService {
    handlers: Arc<DefaultImprintHttpHandlers>,
}

impl DefaultImprintManuscriptService {
    pub fn new(handlers: Arc<DefaultImprintHttpHandlers>) -> Self {
        Self { handlers }
    }
}

fn log_err(method: &str, e: impl std::fmt::Display) {
    eprintln!("[imprint-manuscript-service] {method}: {e}");
}

fn parse_export_format(s: &str) -> ExportFormat {
    match s.to_ascii_lowercase().as_str() {
        "latex" | "tex" => ExportFormat::Latex,
        "text" | "txt" => ExportFormat::Text,
        _ => ExportFormat::Typst,
    }
}

#[async_trait::async_trait]
impl ImprintManuscriptService for DefaultImprintManuscriptService {
    async fn list_documents(&self) -> Vec<DocumentSummary> {
        self.handlers.list_documents().await.unwrap_or_else(|e| {
            log_err("list_documents", e);
            vec![]
        })
    }

    async fn get_document(&self, id: String) -> Option<DocumentSummary> {
        let uuid = match Uuid::parse_str(&id) {
            Ok(u) => u,
            Err(e) => {
                log_err("get_document", format!("bad uuid: {e}"));
                return None;
            }
        };
        self.handlers
            .get_document(uuid)
            .await
            .map_err(|e| log_err("get_document", e))
            .ok()
    }

    async fn export_document(&self, id: String, format: String) -> Vec<u8> {
        let uuid = match Uuid::parse_str(&id) {
            Ok(u) => u,
            Err(e) => {
                log_err("export_document", format!("bad uuid: {e}"));
                return vec![];
            }
        };
        self.handlers
            .export_document(uuid, parse_export_format(&format))
            .await
            .unwrap_or_else(|e| {
                log_err("export_document", e);
                vec![]
            })
    }

    async fn list_sections(&self, doc_id: String) -> Vec<SectionRecord> {
        let uuid = match Uuid::parse_str(&doc_id) {
            Ok(u) => u,
            Err(e) => {
                log_err("list_sections", format!("bad uuid: {e}"));
                return vec![];
            }
        };
        self.handlers.list_sections(uuid).await.unwrap_or_else(|e| {
            log_err("list_sections", e);
            vec![]
        })
    }

    async fn get_section(&self, doc_id: String, section_key: String) -> Option<SectionRecord> {
        let uuid = match Uuid::parse_str(&doc_id) {
            Ok(u) => u,
            Err(e) => {
                log_err("get_section", format!("bad uuid: {e}"));
                return None;
            }
        };
        self.handlers
            .get_section(uuid, &section_key)
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
        let uuid = match Uuid::parse_str(&doc_id) {
            Ok(u) => u,
            Err(e) => {
                log_err("put_section", format!("bad uuid: {e}"));
                return None;
            }
        };
        self.handlers
            .put_section(uuid, &section_key, &body, metadata)
            .await
            .map_err(|e| log_err("put_section", e))
            .ok()
    }

    async fn delete_section(&self, doc_id: String, section_key: String) -> bool {
        let uuid = match Uuid::parse_str(&doc_id) {
            Ok(u) => u,
            Err(e) => {
                log_err("delete_section", format!("bad uuid: {e}"));
                return false;
            }
        };
        match self.handlers.delete_section(uuid, &section_key).await {
            Ok(()) => true,
            Err(e) => {
                log_err("delete_section", e);
                false
            }
        }
    }

    async fn document_outline(&self, source: String) -> Outline {
        self.handlers
            .document_outline(&source)
            .await
            .unwrap_or_else(|e| {
                log_err("document_outline", e);
                Outline { entries: vec![] }
            })
    }

    async fn document_citations(&self, source: String) -> Vec<CitationUsage> {
        self.handlers
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
        self.handlers
            .search_in_text(&source, &query, case_sensitive)
            .await
            .unwrap_or_else(|e| {
                log_err("search_in_text", e);
                vec![]
            })
    }

    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult {
        match self.handlers.compile_typst(&source, options).await {
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
        // Tectonic does blocking network I/O via its own runtime for the on-demand
        // bundle fetch; run it on a blocking thread so it doesn't nest inside this
        // async (tokio) context (which panics at runtime shutdown).
        tokio::task::spawn_blocking(move || {
            let root = if filesystem_root.is_empty() {
                None
            } else {
                Some(filesystem_root.as_str())
            };
            compile_latex_dispatch(&source, root)
        })
        .await
        .unwrap_or_else(|e| {
            log_err("compile_latex", &e);
            LatexCompileResultDto {
                pdf_len: 0,
                diagnostics: vec![],
                error: Some(format!("compile task failed: {e}")),
                compile_ms: 0,
            }
        })
    }

    async fn search(&self, query: String, limit: u32) -> Vec<SearchHitDto> {
        let n = if limit == 0 { 50 } else { limit as usize };
        self.handlers
            .search(&query, n)
            .await
            .unwrap_or_else(|e| {
                log_err("search", e);
                vec![]
            })
            .iter()
            .map(SearchHitDto::from)
            .collect()
    }

    async fn replace_in_section(
        &self,
        doc_id: String,
        section_key: String,
        find: String,
        replace: String,
    ) -> ReplaceResult {
        let uuid = match Uuid::parse_str(&doc_id) {
            Ok(u) => u,
            Err(e) => {
                log_err("replace_in_section", format!("bad uuid: {e}"));
                return ReplaceResult {
                    replacements: 0,
                    new_body: String::new(),
                };
            }
        };
        // replace_all=true by default; expose finer control later if needed.
        self.handlers
            .replace_in_section(uuid, &section_key, &find, &replace, true)
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

// ---------------------------------------------------------------------------
// Macro registration
// ---------------------------------------------------------------------------

impress_service_impl! {
    service = ImprintManuscriptService,
    impl = DefaultImprintManuscriptService,
    instance = || crate::backend::manuscript_service_instance(),
    methods = [
        list_documents() -> Vec<DocumentSummary>,
        get_document(id: String) -> Option<DocumentSummary>,
        export_document(id: String, format: String) -> Vec<u8>,
        list_sections(doc_id: String) -> Vec<SectionRecord>,
        get_section(doc_id: String, section_key: String) -> Option<SectionRecord>,
        put_section(doc_id: String, section_key: String, body: String, metadata: SectionMetadata) -> Option<SectionRecord>,
        delete_section(doc_id: String, section_key: String) -> bool,
        document_outline(source: String) -> Outline,
        document_citations(source: String) -> Vec<CitationUsage>,
        search_in_text(source: String, query: String, case_sensitive: bool) -> Vec<TextMatch>,
        compile_typst(source: String, options: CompileOptions) -> CompileResult,
        compile_latex(source: String, filesystem_root: String) -> LatexCompileResultDto,
        search(query: String, limit: u32) -> Vec<SearchHitDto>,
        replace_in_section(doc_id: String, section_key: String, find: String, replace: String) -> ReplaceResult,
    ],
}
