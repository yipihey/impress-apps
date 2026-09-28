//! `ImprintManuscriptService` — macro-wired wrapper around `ImprintHttpHandlers`.
//!
//! The handler trait was hand-written to mirror the Swift router 1:1; this
//! file promotes the methods to a `#[impress_service]` trait so they show up
//! as MCP tools, CLI subcommands, and future Python bindings.
//!
//! Method signatures are simplified for the macro: each method returns its
//! "happy path" value directly; failures are recorded in the pipeline's
//! refusal channel as well as stderr. Methods that take complex DTOs
//! (`SectionMetadata`, `CompileOptions`) accept them directly — both DTOs
//! derive `JsonSchema` so the macro can synthesize the args struct.

use std::sync::Arc;

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use uuid::Uuid;

use crate::error::ServiceError;
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
    #[impress_method(effects(reads = ["manuscript"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "g3-list-documents", args = r#"{}"#)]
    async fn list_documents(&self) -> Vec<DocumentSummary>;

    /// Fetch a single document by UUID.
    #[impress_method(effects(reads = ["manuscript", "manuscript-section"]))]
    #[impress_example(
        name = "g3-get-document",
        args = r#"{"id":"62000000-0000-4000-8000-000000000002"}"#,
        expect = r#"{"title":"G3 get document"}"#
    )]
    async fn get_document(&self, id: String) -> Option<DocumentSummary>;

    /// Export a document in the given format. Returns the raw bytes.
    /// `format` is `"typst" | "latex" | "text"`.
    #[impress_method(effects(reads = ["manuscript", "manuscript-section"]))]
    #[impress_example(
        name = "g3-export-headless-refusal",
        args = r#"{"id":"62000000-0000-4000-8000-000000000003","format":"typst"}"#,
        expect = r#"{"ok":false,"code":"invalid-argument"}"#
    )]
    async fn export_document(&self, id: String, format: String) -> Vec<u8>;

    // ---- Section CRUD ----
    /// List every stored section of a manuscript, sorted by order_index.
    /// Returns section id, title, body (inline), sectionType, orderIndex,
    /// wordCount, and createdAt. Large content-addressed bodies are not
    /// rehydrated here — call `imprint-manuscript-service_get-section` for those.
    #[impress_method(effects(reads = ["manuscript", "manuscript-section"]))]
    #[impress_example(
        name = "g3-list-sections",
        args = r#"{"doc_id":"62000000-0000-4000-8000-000000000004"}"#
    )]
    async fn list_sections(&self, doc_id: String) -> Vec<SectionRecord>;
    /// Fetch a single manuscript section by its UUID. Body is rehydrated
    /// from content-addressed storage when needed. Use this after
    /// `imprint-manuscript-service_list-sections` to load the full body of a specific
    /// section.
    #[impress_method(effects(reads = ["manuscript", "manuscript-section"]))]
    #[impress_example(
        name = "g3-get-section",
        args = r#"{"doc_id":"62000000-0000-4000-8000-000000000005","section_key":"intro"}"#,
        expect = r#"{"section_key":"intro","body":"G3 section body"}"#
    )]
    async fn get_section(&self, doc_id: String, section_key: String) -> Option<SectionRecord>;
    /// Create or replace one section's body and metadata in a manuscript;
    /// returns the section as stored.
    #[impress_method(safety = mutating, effects(reads = ["manuscript", "manuscript-section"], writes = ["manuscript-section", "manuscript"]))]
    #[impress_example(
        name = "g3-put-section",
        args = r#"{"doc_id":"62000000-0000-4000-8000-000000000006","section_key":"methods","body":"G3 measured methods","metadata":{"title":"Methods","section_type":"methods","order_index":1}}"#,
        expect = r#"{"section_key":"methods","title":"Methods"}"#
    )]
    async fn put_section(
        &self,
        doc_id: String,
        section_key: String,
        body: String,
        metadata: SectionMetadata,
    ) -> Option<SectionRecord>;
    /// Remove a section (heading + body) from the document. Queues an
    /// operation; returns operationId.
    #[impress_method(safety = destructive, effects(reads = ["manuscript", "manuscript-section"], writes = ["manuscript-section", "manuscript"]))]
    #[impress_example(
        name = "g3-delete-section",
        args = r#"{"doc_id":"62000000-0000-4000-8000-000000000007","section_key":"intro"}"#,
        expect = "true"
    )]
    async fn delete_section(&self, doc_id: String, section_key: String) -> bool;

    // ---- Pure-text helpers ----
    /// Parse Typst source you pass in into its heading outline. Pure text:
    /// nothing is read from the store.
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"source": "= Title\n== Section"}"#)]
    #[impress_example(
        name = "g3-document-outline",
        args = r#"{"source":"= G3 Title\n== Evidence"}"#
    )]
    async fn document_outline(&self, source: String) -> Outline;
    /// List the citation keys used in Typst source you pass in, with where
    /// each occurs. Pure text: nothing is read from the store.
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"source": "As shown by @abel2026."}"#)]
    #[impress_example(
        name = "g3-document-citations",
        args = r#"{"source":"Evidence cites @g3source and compares results."}"#
    )]
    async fn document_citations(&self, source: String) -> Vec<CitationUsage>;
    /// Find every match of `query` in Typst source you pass in, with
    /// positions. Pure text: nothing is read from the store.
    #[impress_method]
    #[impress_example(
        name = "default",
        args = r#"{"source": "alpha beta", "query": "beta", "case_sensitive": false}"#
    )]
    #[impress_example(
        name = "g3-search-in-text",
        args = r#"{"source":"Alpha beta gamma","query":"beta","case_sensitive":false}"#
    )]
    async fn search_in_text(
        &self,
        source: String,
        query: String,
        case_sensitive: bool,
    ) -> Vec<TextMatch>;

    // ---- Presentation structure ----
    /// Parse stable `#slide(id:, beat:)[…]` blocks for graphical or agentic
    /// deck manipulation. The Typst source remains the only order authority.
    #[impress_method]
    #[impress_example(
        name = "g3-presentation-outline",
        args = r##"{"source":"#slide(id: \"one\", title: \"First\")[A]\n#slide(id: \"two\")[B]"}"##
    )]
    async fn presentation_outline(&self, source: String) -> PresentationOutlineDto;

    /// Move a slide before another slide. Pass an empty `before_slide_id` to
    /// move it to the end. Returns the complete updated Typst source.
    #[impress_method]
    #[impress_example(
        name = "g3-reorder-slide",
        args = r##"{"source":"#slide(id: \"one\")[A]\n#slide(id: \"two\")[B]","slide_id":"two","before_slide_id":"one"}"##
    )]
    async fn reorder_presentation_slide(
        &self,
        source: String,
        slide_id: String,
        before_slide_id: String,
    ) -> PresentationMutationDto;

    /// Associate a slide with a stable throughline paragraph label. Pass an
    /// empty `beat` to clear the association.
    #[impress_method]
    #[impress_example(
        name = "g3-set-slide-beat",
        args = r##"{"source":"#slide(id: \"one\")[A]","slide_id":"one","beat":"tl-method"}"##
    )]
    async fn set_presentation_slide_beat(
        &self,
        source: String,
        slide_id: String,
        beat: String,
    ) -> PresentationMutationDto;

    // ---- Typst compile ----
    /// Compile Typst source to a PDF and return `pdf_path` (plus page count
    /// and any warnings) — NOT the bytes, which no tool result can carry. Feed
    /// `pdf_path` to `render_pdf_page` to actually look at a page. Works with
    /// imprint closed: the compiler is embedded. With imprint running the
    /// compile happens in its live engine instead; either way you get a path.
    /// A broken document comes back as `error`, not as a failed call.
    #[impress_method(safety = mutating, effects(reads = ["manuscript", "manuscript-file@1.0.0"], reach = [fs]))]
    #[impress_example(
        tier = "b",
        name = "g3-compile-typst",
        args = r#"{"source":"= G3 manuscript\nA valid proof.","options":{"page_size":"A4","font_size":11.0,"margin_top":72.0,"margin_right":72.0,"margin_bottom":72.0,"margin_left":72.0}}"#
    )]
    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult;

    // ---- LaTeX compile via embedded Tectonic (gated on tectonic-render) ----
    /// Compile LaTeX to PDF with the self-contained Tectonic engine. Returns
    /// PDF length + diagnostics (not raw bytes). `filesystem_root` resolves
    /// on-disk `\includegraphics`/`\input`; pass "" for none.
    #[impress_method(effects(reach = [subprocess]))]
    #[impress_example(
        tier = "b",
        name = "g3-compile-latex",
        args = r#"{"source":"\\documentclass{article}\\begin{document}G3 proof\\end{document}","filesystem_root":"{{fixture.root}}/manuscripts"}"#
    )]
    async fn compile_latex(&self, source: String, filesystem_root: String)
        -> LatexCompileResultDto;

    // ---- Cross-document search ----
    /// Search for text in an imprint document. Returns positions of all
    /// matches.
    #[impress_method(effects(reads = ["manuscript", "manuscript-section"]))]
    #[impress_example(
        name = "g3-search",
        args = r#"{"query":"g3uniquesearchneedle","limit":5}"#
    )]
    async fn search(&self, query: String, limit: u32) -> Vec<SearchHitDto>;

    // ---- Replace within a section ----
    /// Replace every occurrence of `find` with `replace` in one stored
    /// section's body; returns the replacement count and the new body.
    #[impress_method(safety = destructive, effects(reads = ["manuscript", "manuscript-section"], writes = ["manuscript-section"]))]
    #[impress_example(
        name = "g3-replace-section",
        args = r#"{"doc_id":"62000000-0000-4000-8000-000000000011","section_key":"intro","find":"before","replace":"after"}"#,
        expect = r#"{"replacements":1,"new_body":"G3 after result"}"#
    )]
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

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct PresentationSlideDto {
    pub id: String,
    pub beat: Option<String>,
    pub title: Option<String>,
    pub order_index: u32,
    pub start: u64,
    pub end: u64,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct PresentationOutlineDto {
    pub slides: Vec<PresentationSlideDto>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct PresentationMutationDto {
    pub source: String,
    pub error: Option<String>,
}

fn presentation_outline(source: &str) -> PresentationOutlineDto {
    match imprint_core::presentation::extract_slides(source) {
        Ok(slides) => PresentationOutlineDto {
            slides: slides
                .into_iter()
                .map(|slide| PresentationSlideDto {
                    id: slide.id,
                    beat: slide.beat,
                    title: slide.title,
                    order_index: slide.order_index as u32,
                    start: slide.start as u64,
                    end: slide.end as u64,
                })
                .collect(),
            error: None,
        },
        Err(error) => PresentationOutlineDto {
            slides: vec![],
            error: Some(error.to_string()),
        },
    }
}

fn reorder_presentation(
    source: String,
    slide_id: &str,
    before_slide_id: &str,
) -> PresentationMutationDto {
    let before = (!before_slide_id.is_empty()).then_some(before_slide_id);
    match imprint_core::presentation::reorder_slide(&source, slide_id, before) {
        Ok(source) => PresentationMutationDto {
            source,
            error: None,
        },
        Err(error) => PresentationMutationDto {
            source,
            error: Some(error.to_string()),
        },
    }
}

fn set_presentation_beat(source: String, slide_id: &str, beat: &str) -> PresentationMutationDto {
    match imprint_core::presentation::set_slide_beat(&source, slide_id, beat) {
        Ok(source) => PresentationMutationDto {
            source,
            error: None,
        },
        Err(error) => PresentationMutationDto {
            source,
            error: Some(error.to_string()),
        },
    }
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
/// methods to the macro-friendly return type, retaining failures through
/// the pipeline refusal channel.
#[derive(Clone)]
pub struct DefaultImprintManuscriptService {
    handlers: Arc<DefaultImprintHttpHandlers>,
}

impl DefaultImprintManuscriptService {
    pub fn new(handlers: Arc<DefaultImprintHttpHandlers>) -> Self {
        Self { handlers }
    }
}

fn log_err(method: &str, e: ServiceError) {
    use impress_service_core::refusal::codes;
    let code = match &e {
        ServiceError::InvalidArgument(_) => codes::INVALID_ARGUMENT,
        ServiceError::NotFound(_) => codes::NOT_FOUND,
        _ => codes::VERB_FAILED,
    };
    impress_service_core::pipeline::context::report_refusal(code, format!("{method}: {e}"));
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
                log_err("get_document", ServiceError::from(e));
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
                log_err("export_document", ServiceError::from(e));
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
                log_err("list_sections", ServiceError::from(e));
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
                log_err("get_section", ServiceError::from(e));
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
                log_err("put_section", ServiceError::from(e));
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
                log_err("delete_section", ServiceError::from(e));
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

    async fn presentation_outline(&self, source: String) -> PresentationOutlineDto {
        presentation_outline(&source)
    }

    async fn reorder_presentation_slide(
        &self,
        source: String,
        slide_id: String,
        before_slide_id: String,
    ) -> PresentationMutationDto {
        reorder_presentation(source, &slide_id, &before_slide_id)
    }

    async fn set_presentation_slide_beat(
        &self,
        source: String,
        slide_id: String,
        beat: String,
    ) -> PresentationMutationDto {
        set_presentation_beat(source, &slide_id, &beat)
    }

    async fn compile_typst(&self, source: String, options: CompileOptions) -> CompileResult {
        match self.handlers.compile_typst(&source, options).await {
            Ok(r) => r,
            Err(e) => {
                let msg = format!("{e}");
                log_err("compile_typst", e);
                CompileResult {
                    pdf_data: None,
                    pdf_path: None,
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
            log_err("compile_latex", ServiceError::Internal(e.to_string()));
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
                log_err("replace_in_section", ServiceError::from(e));
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
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [],
    },
    impl = DefaultImprintManuscriptService,
    instance = || crate::backend::manuscript_service_instance(),
    methods = [
        list_documents(
        ) -> Vec<DocumentSummary>,
        get_document(
            /// UUID of the manuscript document.
            id: String,
        ) -> Option<DocumentSummary>,
        export_document(
            /// UUID of the manuscript document.
            id: String,
            /// Export format: `typst`, `latex`, or `text`.
            format: String,
        ) -> Vec<u8>,
        list_sections(
            /// UUID of the owning manuscript document.
            doc_id: String,
        ) -> Vec<SectionRecord>,
        get_section(
            /// UUID of the owning manuscript document.
            doc_id: String,
            /// Stable key of a section in this manuscript.
            section_key: String,
        ) -> Option<SectionRecord>,
        put_section(
            /// UUID of the owning manuscript document.
            doc_id: String,
            /// Stable key of a section in this manuscript.
            section_key: String,
            /// Typst source body to store for the section.
            body: String,
            /// Optional heading, section type, and zero-based order for the section.
            metadata: SectionMetadata,
        ) -> Option<SectionRecord>,
        delete_section(
            /// UUID of the owning manuscript document.
            doc_id: String,
            /// Stable key of a section in this manuscript.
            section_key: String,
        ) -> bool,
        document_outline(
            /// Typst or LaTeX source supplied directly by the caller.
            source: String,
        ) -> Outline,
        document_citations(
            /// Typst or LaTeX source supplied directly by the caller.
            source: String,
        ) -> Vec<CitationUsage>,
        search_in_text(
            /// Typst or LaTeX source supplied directly by the caller.
            source: String,
            /// Text to find in the source or manuscript search index.
            query: String,
            /// Whether text search distinguishes upper- and lowercase characters.
            case_sensitive: bool,
        ) -> Vec<TextMatch>,
        presentation_outline(
            /// Typst presentation source containing stable `#slide(id:)` blocks.
            source: String,
        ) -> PresentationOutlineDto,
        reorder_presentation_slide(
            /// Typst presentation source containing stable `#slide(id:)` blocks.
            source: String,
            /// Stable `id` of the slide to edit or move.
            slide_id: String,
            /// Slide id to move before; empty string moves to the end.
            before_slide_id: String,
        ) -> PresentationMutationDto,
        set_presentation_slide_beat(
            /// Typst presentation source containing stable `#slide(id:)` blocks.
            source: String,
            /// Stable `id` of the slide to edit or move.
            slide_id: String,
            /// Throughline paragraph label; empty string clears the slide association.
            beat: String,
        ) -> PresentationMutationDto,
        compile_typst(
            /// Typst or LaTeX source supplied directly by the caller.
            source: String,
            /// Page size, font size, and margins for the Typst compilation.
            options: CompileOptions,
        ) -> CompileResult,
        compile_latex(
            /// Typst or LaTeX source supplied directly by the caller.
            source: String,
            /// Local directory for LaTeX input and image files; empty means none.
            filesystem_root: String,
        ) -> LatexCompileResultDto,
        search(
            /// Text to find in the source or manuscript search index.
            query: String,
            /// Maximum number of cross-document search hits; zero uses the service default.
            limit: u32,
        ) -> Vec<SearchHitDto>,
        replace_in_section(
            /// UUID of the owning manuscript document.
            doc_id: String,
            /// Stable key of a section in this manuscript.
            section_key: String,
            /// Literal text to replace in the selected section.
            find: String,
            /// Replacement text for each occurrence of `find`.
            replace: String,
        ) -> ReplaceResult,
    ],
}
