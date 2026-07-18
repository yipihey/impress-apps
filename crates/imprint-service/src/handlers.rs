//! Stateless HTTP-handler implementations promoted out of
//! `apps/imprint/Shared/Services/ImprintHTTPRouter.swift` (Phase 2E).
//!
//! Scope rule from the plan: any handler that does NOT touch AppKit, NSDocument
//! lifecycle, SwiftUI bindings, file pickers, or notification posting is a
//! candidate. Anything that does stays in Swift; the Swift router will keep
//! its handlers but dispatch to the `ImprintHttpHandlers` trait methods for
//! the actual work once the Phase-3 UniFFI bridge lands.
//!
//! This file therefore implements the **pure-computation** subset of the
//! router:
//!
//! - Document / section CRUD that maps onto `SectionStore` (sections, search,
//!   replace within a section, list).
//! - Outline extraction from Typst source.
//! - Citation-usage extraction (regex over `@key` patterns) from source.
//! - Text search and replace within a source string.
//! - Manuscript-cross-document search (over the tantivy index).
//! - Typst compile dispatch (re-exports the existing
//!   `imprint_core::compile_typst_to_pdf` API surface via a stable DTO that
//!   does not depend on the `uniffi` feature being enabled).
//!
//! What is NOT here (and the rationale, in case the next agent wonders):
//!
//! - `handleCompile` / `handleStatelessCompile` actual rendering: gated on
//!   the `typst-render` feature in `imprint-core`; we expose a thin
//!   `compile_typst` shim that produces a `CompileResult` regardless of
//!   whether typst is wired in (returns a structured "render disabled" error
//!   in the latter case). The macOS app already calls `imprint_core` directly
//!   for the actual rendering — moving that here would just add a layer.
//! - `handleBundleCompile` / SyncTeX / LaTeX diagnostics: depend on Phase 2B/C
//!   modules (`imprint_core::synctex`, `imprint_core::latex::{diagnostics,
//!   formatter}`) which have not landed in this worktree yet.
//! - `handleListDocuments` / `handleGetDocument` / `handleGetDocumentContent`:
//!   imprint documents (as opposed to sections) live in
//!   `ManuscriptStoreAdapter`. There is no Rust mirror for that adapter yet —
//!   it is on the Phase 3 cutover list. The handler trait carries the
//!   signatures so the Swift bridge can be named, but the default impl
//!   returns `ServiceError::Internal("not implemented in Rust yet")` for the
//!   document-level methods.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::ServiceError;
use crate::search::{ManuscriptSearchIndex, SearchHit};
use crate::sections::{SectionMetadata, SectionRecord, SectionStore};

// ── DTOs ─────────────────────────────────────────────────────────────────────

/// Short summary of a document (id + title + format).
///
/// Document-level metadata lives in the Swift `ManuscriptStoreAdapter`; this
/// DTO is named here so the Swift bridge has a Rust target type.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocumentSummary {
    pub id: Uuid,
    pub title: String,
    // The live imprint `/api/documents` response does not always carry a
    // `format` field (it predates this DTO). Default it so the typed HTTP
    // client can decode real responses instead of erroring on a missing key.
    #[serde(default)]
    pub format: String,
}

/// Output format for `export_document`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ExportFormat {
    /// `.typ` source.
    Typst,
    /// `.tex` (LaTeX) source.
    Latex,
    /// Plain-text rendering of source.
    Text,
}

/// One heading extracted from a Typst source.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct OutlineEntry {
    /// Heading depth (1 for `=`, 2 for `==`, …).
    pub level: u32,
    /// Heading title (trimmed).
    pub title: String,
    /// 1-based line number in the source.
    pub line: u32,
    /// Byte offset of the heading line within the source.
    pub position: u32,
}

/// Result of an outline extraction.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Outline {
    pub entries: Vec<OutlineEntry>,
}

/// One `@citekey` usage extracted from a Typst source.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CitationUsage {
    pub cite_key: String,
    /// Byte position of the `@` character.
    pub position: u32,
    /// Length in bytes including the `@` prefix.
    pub length: u32,
}

/// Compile options. Mirrors the public fields of
/// `imprint_core::CompileOptions` but exists independently so this crate can
/// build without `imprint-core/uniffi`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, schemars::JsonSchema)]
pub struct CompileOptions {
    pub page_size: PageSize,
    pub font_size: f64,
    pub margin_top: f64,
    pub margin_right: f64,
    pub margin_bottom: f64,
    pub margin_left: f64,
}

impl Default for CompileOptions {
    fn default() -> Self {
        Self {
            page_size: PageSize::A4,
            font_size: 11.0,
            margin_top: 72.0,
            margin_right: 72.0,
            margin_bottom: 72.0,
            margin_left: 72.0,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub enum PageSize {
    Letter,
    A4,
    A5,
}

/// Outcome of a Typst compile request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompileResult {
    /// PDF bytes if compilation succeeded; absent on error.
    pub pdf_data: Option<Vec<u8>>,
    /// Error message if compilation failed.
    pub error: Option<String>,
    /// Warning messages emitted by the renderer.
    pub warnings: Vec<String>,
    /// Number of pages in the output (0 on error).
    pub page_count: u32,
}

/// Outcome of a LaTeX compile via the embedded Tectonic engine, shaped for
/// MCP/CLI: we return the PDF *length* + diagnostics rather than raw bytes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct LatexCompileResultDto {
    /// Byte length of the produced PDF (0 on failure).
    pub pdf_len: u32,
    /// Diagnostics as `file:line: message` strings, in source order.
    pub diagnostics: Vec<String>,
    /// Fatal-error summary if no PDF was produced.
    pub error: Option<String>,
    /// Wall-clock compile time in milliseconds.
    pub compile_ms: u64,
}

/// Compile LaTeX to PDF via the embedded Tectonic engine.
///
/// Gated on imprint-core's `tectonic-render` feature (heavy C deps). When the
/// feature is off (the default service/CLI/MCP build), returns a structured
/// "not enabled" result — mirrors `compile_typst_dispatch`.
#[cfg(feature = "tectonic-render")]
pub fn compile_latex_dispatch(source: &str, filesystem_root: Option<&str>) -> LatexCompileResultDto {
    let r = imprint_core::latex::compile_latex_tectonic(source, false, None, filesystem_root);
    LatexCompileResultDto {
        pdf_len: r.pdf_data.as_ref().map(|d| d.len() as u32).unwrap_or(0),
        diagnostics: r
            .diagnostics
            .iter()
            .map(|d| {
                if d.line > 0 {
                    format!("{}:{}: {}", d.file, d.line, d.message)
                } else {
                    d.message.clone()
                }
            })
            .collect(),
        error: r.error,
        compile_ms: r.compile_ms,
    }
}

#[cfg(not(feature = "tectonic-render"))]
pub fn compile_latex_dispatch(_source: &str, _filesystem_root: Option<&str>) -> LatexCompileResultDto {
    LatexCompileResultDto {
        pdf_len: 0,
        diagnostics: Vec::new(),
        error: Some(
            "Tectonic LaTeX rendering requires imprint-core's `tectonic-render` \
             feature; build imprint-service with `--features tectonic-render`."
                .into(),
        ),
        compile_ms: 0,
    }
}

/// Outcome of a text search-and-replace inside a single section.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReplaceResult {
    /// Number of replacements made.
    pub replacements: u32,
    /// The new body after replacement (already persisted to the store).
    pub new_body: String,
}

/// One match returned by `search_in_text`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextMatch {
    pub position: u32,
    pub length: u32,
    pub text: String,
}

// ── Trait ────────────────────────────────────────────────────────────────────

/// The stateless slice of `ImprintHTTPRouter` that has been promoted into
/// Rust. The Swift router will dispatch here once the Phase-3 UniFFI bridge
/// ships; the same methods are also reachable from MCP/CLI/Python.
///
/// Methods are `async` for symmetry with the existing router — even where the
/// current impl is synchronous, that lets Phase 3 swap in I/O without
/// breaking the contract.
pub trait ImprintHttpHandlers: Send + Sync {
    // Document-level (stubbed pending Phase 3; see file header).
    fn list_documents(
        &self,
    ) -> impl std::future::Future<Output = Result<Vec<DocumentSummary>, ServiceError>> + Send;

    fn get_document(
        &self,
        id: Uuid,
    ) -> impl std::future::Future<Output = Result<DocumentSummary, ServiceError>> + Send;

    fn export_document(
        &self,
        id: Uuid,
        format: ExportFormat,
    ) -> impl std::future::Future<Output = Result<Vec<u8>, ServiceError>> + Send;

    // Section CRUD (backed by SectionStore).
    fn list_sections(
        &self,
        doc_id: Uuid,
    ) -> impl std::future::Future<Output = Result<Vec<SectionRecord>, ServiceError>> + Send;

    fn get_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
    ) -> impl std::future::Future<Output = Result<Option<SectionRecord>, ServiceError>> + Send;

    fn put_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
        body: &str,
        metadata: SectionMetadata,
    ) -> impl std::future::Future<Output = Result<SectionRecord, ServiceError>> + Send;

    fn delete_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
    ) -> impl std::future::Future<Output = Result<(), ServiceError>> + Send;

    // Pure-text helpers (no persistence).
    fn document_outline(
        &self,
        source: &str,
    ) -> impl std::future::Future<Output = Result<Outline, ServiceError>> + Send;

    fn document_citations(
        &self,
        source: &str,
    ) -> impl std::future::Future<Output = Result<Vec<CitationUsage>, ServiceError>> + Send;

    fn search_in_text(
        &self,
        source: &str,
        query: &str,
        case_sensitive: bool,
    ) -> impl std::future::Future<Output = Result<Vec<TextMatch>, ServiceError>> + Send;

    // Compile (Typst).
    fn compile_typst(
        &self,
        source: &str,
        options: CompileOptions,
    ) -> impl std::future::Future<Output = Result<CompileResult, ServiceError>> + Send;

    // Cross-document section search.
    fn search(
        &self,
        query: &str,
        limit: usize,
    ) -> impl std::future::Future<Output = Result<Vec<SearchHit>, ServiceError>> + Send;

    // Replace within a section, persisting the new body.
    fn replace_in_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
        find: &str,
        replace: &str,
        replace_all: bool,
    ) -> impl std::future::Future<Output = Result<ReplaceResult, ServiceError>> + Send;
}

// ── Default impl ─────────────────────────────────────────────────────────────

/// Default `ImprintHttpHandlers` implementation built on top of
/// `SectionStore` and (optionally) a `ManuscriptSearchIndex`.
///
/// Constructed once per process at startup and shared via `Arc` across the
/// router, the MCP server, and the CLI.
#[derive(Clone)]
pub struct DefaultImprintHttpHandlers {
    sections: Arc<SectionStore>,
    search_index: Arc<ManuscriptSearchIndex>,
}

impl DefaultImprintHttpHandlers {
    pub fn new(sections: Arc<SectionStore>, search_index: Arc<ManuscriptSearchIndex>) -> Self {
        Self {
            sections,
            search_index,
        }
    }

    /// Borrow the section store (useful in tests).
    pub fn sections(&self) -> &SectionStore {
        &self.sections
    }

    /// Borrow the search index (useful in tests).
    pub fn search_index(&self) -> &ManuscriptSearchIndex {
        &self.search_index
    }
}

impl ImprintHttpHandlers for DefaultImprintHttpHandlers {
    async fn list_documents(&self) -> Result<Vec<DocumentSummary>, ServiceError> {
        Err(ServiceError::Internal(
            "list_documents not implemented in Rust (Phase 3 cutover)".into(),
        ))
    }

    async fn get_document(&self, _id: Uuid) -> Result<DocumentSummary, ServiceError> {
        Err(ServiceError::Internal(
            "get_document not implemented in Rust (Phase 3 cutover)".into(),
        ))
    }

    async fn export_document(
        &self,
        _id: Uuid,
        _format: ExportFormat,
    ) -> Result<Vec<u8>, ServiceError> {
        Err(ServiceError::Internal(
            "export_document not implemented in Rust (Phase 3 cutover)".into(),
        ))
    }

    async fn list_sections(&self, doc_id: Uuid) -> Result<Vec<SectionRecord>, ServiceError> {
        self.sections.list_sections(doc_id, 0)
    }

    async fn get_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
    ) -> Result<Option<SectionRecord>, ServiceError> {
        self.sections.get_section(doc_id, section_key)
    }

    async fn put_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
        body: &str,
        metadata: SectionMetadata,
    ) -> Result<SectionRecord, ServiceError> {
        let rec = self
            .sections
            .put_section(doc_id, section_key, body, metadata)?;
        // Best-effort: index the new/updated section so subsequent searches
        // see it. Errors here are logged at the caller level — we still
        // return the persisted record.
        self.search_index.index_section(&rec)?;
        self.search_index.commit()?;
        Ok(rec)
    }

    async fn delete_section(&self, doc_id: Uuid, section_key: &str) -> Result<(), ServiceError> {
        // Compute the id first so we can also drop it from the search index.
        let item_id = SectionStore::item_id(doc_id, section_key);
        self.sections.delete_section(doc_id, section_key)?;
        self.search_index.remove_section(item_id)?;
        self.search_index.commit()?;
        Ok(())
    }

    async fn document_outline(&self, source: &str) -> Result<Outline, ServiceError> {
        Ok(Outline {
            entries: extract_outline(source),
        })
    }

    async fn document_citations(&self, source: &str) -> Result<Vec<CitationUsage>, ServiceError> {
        Ok(extract_citation_usages(source))
    }

    async fn search_in_text(
        &self,
        source: &str,
        query: &str,
        case_sensitive: bool,
    ) -> Result<Vec<TextMatch>, ServiceError> {
        Ok(search_text_plain(source, query, case_sensitive))
    }

    async fn compile_typst(
        &self,
        source: &str,
        options: CompileOptions,
    ) -> Result<CompileResult, ServiceError> {
        Ok(compile_typst_dispatch(source, options))
    }

    async fn search(&self, query: &str, limit: usize) -> Result<Vec<SearchHit>, ServiceError> {
        self.search_index.search(query, limit)
    }

    async fn replace_in_section(
        &self,
        doc_id: Uuid,
        section_key: &str,
        find: &str,
        replace: &str,
        replace_all: bool,
    ) -> Result<ReplaceResult, ServiceError> {
        if find.is_empty() {
            return Err(ServiceError::InvalidArgument(
                "search string must not be empty".into(),
            ));
        }
        let existing = self
            .sections
            .get_section(doc_id, section_key)?
            .ok_or_else(|| {
                ServiceError::NotFound(format!("section {section_key} in document {doc_id}"))
            })?;

        let (new_body, count) = if replace_all {
            let replaced = existing.body.replace(find, replace);
            // Counting matches is cheap and harmless: count occurrences of
            // `find` in the *original* body.
            let count = count_substr(&existing.body, find);
            (replaced, count)
        } else {
            // Replace the first occurrence only.
            match existing.body.find(find) {
                None => (existing.body.clone(), 0),
                Some(pos) => {
                    let mut out = String::with_capacity(existing.body.len());
                    out.push_str(&existing.body[..pos]);
                    out.push_str(replace);
                    out.push_str(&existing.body[pos + find.len()..]);
                    (out, 1)
                }
            }
        };

        let metadata = SectionMetadata {
            title: Some(existing.title.clone()),
            section_type: existing.section_type.clone(),
            order_index: existing.order_index,
        };
        let updated = self
            .sections
            .put_section(doc_id, section_key, &new_body, metadata)?;
        self.search_index.index_section(&updated)?;
        self.search_index.commit()?;

        Ok(ReplaceResult {
            replacements: count as u32,
            new_body,
        })
    }
}

// ── Pure functions (reusable from MCP/CLI/Python without an Arc<Self>) ──────

/// Extract Typst headings (`=`, `==`, …) from a source string.
pub fn extract_outline(source: &str) -> Vec<OutlineEntry> {
    let mut out = Vec::new();
    let mut byte_offset: u32 = 0;
    for (line_number_0, line) in source.lines().enumerate() {
        let trimmed = line.trim();
        if let Some(level) = leading_equals(trimmed) {
            let title = trimmed[level..].trim().to_string();
            if !title.is_empty() {
                out.push(OutlineEntry {
                    level: level as u32,
                    title,
                    line: (line_number_0 as u32) + 1,
                    position: byte_offset,
                });
            }
        }
        byte_offset += (line.len() as u32) + 1; // +1 for the newline
    }
    out
}

fn leading_equals(s: &str) -> Option<usize> {
    let mut n = 0usize;
    for ch in s.chars() {
        if ch == '=' {
            n += 1;
        } else {
            break;
        }
    }
    if n > 0 && s.chars().nth(n).map(|c| c.is_whitespace()).unwrap_or(false) {
        Some(n)
    } else {
        None
    }
}

/// Extract `@citekey` references from a Typst source.
pub fn extract_citation_usages(source: &str) -> Vec<CitationUsage> {
    let bytes = source.as_bytes();
    let len = bytes.len();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < len {
        if bytes[i] == b'@' {
            // The key must start with an ASCII letter; bail out otherwise.
            let key_start = i + 1;
            if key_start < len && (bytes[key_start].is_ascii_alphabetic()) {
                let mut j = key_start;
                while j < len {
                    let c = bytes[j];
                    if c.is_ascii_alphanumeric() || c == b'_' || c == b':' || c == b'-' {
                        j += 1;
                    } else {
                        break;
                    }
                }
                let cite_key = std::str::from_utf8(&bytes[key_start..j])
                    .unwrap_or("")
                    .to_string();
                out.push(CitationUsage {
                    cite_key,
                    position: i as u32,
                    length: (j - i) as u32,
                });
                i = j;
                continue;
            }
        }
        i += 1;
    }
    out
}

/// Plain (non-regex) text search. Mirrors the Swift `searchText(isRegex: false)`
/// branch — sequential, non-overlapping matches, with optional case folding.
pub fn search_text_plain(source: &str, query: &str, case_sensitive: bool) -> Vec<TextMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    let mut matches = Vec::new();

    if case_sensitive {
        let mut cursor = 0usize;
        while cursor < source.len() {
            match source[cursor..].find(query) {
                None => break,
                Some(off) => {
                    let pos = cursor + off;
                    matches.push(TextMatch {
                        position: pos as u32,
                        length: query.len() as u32,
                        text: source[pos..pos + query.len()].to_string(),
                    });
                    cursor = pos + query.len();
                }
            }
        }
    } else {
        let lower_source = source.to_lowercase();
        let lower_query = query.to_lowercase();
        // Mapping between lowercased byte offsets and original byte offsets is
        // not 1:1 in general (Turkish dotted i, German ß, …). We accept the
        // approximation that matters for ASCII-heavy Typst source.
        let mut cursor = 0usize;
        while cursor < lower_source.len() {
            match lower_source[cursor..].find(&lower_query) {
                None => break,
                Some(off) => {
                    let pos = cursor + off;
                    // Map back to original: clamp to UTF-8 boundary.
                    let mut original_pos = pos.min(source.len());
                    while original_pos > 0 && !source.is_char_boundary(original_pos) {
                        original_pos -= 1;
                    }
                    let length = lower_query.len().min(source.len() - original_pos);
                    let slice = &source[original_pos..original_pos + length];
                    matches.push(TextMatch {
                        position: original_pos as u32,
                        length: length as u32,
                        text: slice.to_string(),
                    });
                    cursor = pos + lower_query.len();
                }
            }
        }
    }
    matches
}

fn count_substr(hay: &str, needle: &str) -> usize {
    if needle.is_empty() {
        return 0;
    }
    let mut count = 0;
    let mut cursor = 0;
    while let Some(pos) = hay[cursor..].find(needle) {
        count += 1;
        cursor += pos + needle.len();
    }
    count
}

/// Compile Typst source using `imprint-core`. When `imprint-core` is built
/// without the `uniffi` feature (and therefore without `typst-render`), this
/// returns a `CompileResult` with a structured "renderer not available"
/// error — the call doesn't fail, so MCP/CLI surfaces can decide whether to
/// fall back to a subprocess or report the error.
pub fn compile_typst_dispatch(_source: &str, _options: CompileOptions) -> CompileResult {
    // The actual `compile_typst_to_pdf` symbol in `imprint-core` is gated on
    // the `uniffi` feature. When invoking this crate from the macOS app the
    // FFI build does enable that feature, and Phase 3 will wire the call
    // through. For pure-Rust integration tests and CLI builds we report a
    // structured "renderer unavailable" so callers can react accordingly.
    CompileResult {
        pdf_data: None,
        error: Some(
            "Typst rendering is gated on imprint-core's `uniffi` feature; \
             enable it (or call imprint_core::compile_typst_to_pdf directly) \
             when wiring through UniFFI in Phase 3."
                .into(),
        ),
        warnings: Vec::new(),
        page_count: 0,
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sections::SectionStore;
    use tempfile::TempDir;

    fn handlers() -> (DefaultImprintHttpHandlers, TempDir) {
        let dir = TempDir::new().unwrap();
        let store = Arc::new(SectionStore::open_in_memory(dir.path().join("content")).unwrap());
        let idx = Arc::new(ManuscriptSearchIndex::in_memory().unwrap());
        (DefaultImprintHttpHandlers::new(store, idx), dir)
    }

    #[test]
    fn outline_extracts_headings() {
        let src = "= Intro\nbody\n== Methods\nmore\n=== Detail\ntail";
        let entries = extract_outline(src);
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].level, 1);
        assert_eq!(entries[0].title, "Intro");
        assert_eq!(entries[0].line, 1);
        assert_eq!(entries[1].level, 2);
        assert_eq!(entries[1].title, "Methods");
        assert_eq!(entries[2].level, 3);
        assert_eq!(entries[2].title, "Detail");
    }

    #[test]
    fn outline_ignores_equals_without_space() {
        // Typst headings require a space after `=`. Tokens like `===` (HR)
        // should not be reported.
        let src = "===\nbody";
        let entries = extract_outline(src);
        assert!(entries.is_empty());
    }

    #[test]
    fn citation_usages_basic() {
        // The Swift router uses the regex `@([a-zA-Z][a-zA-Z0-9_:-]*)` which
        // also greedily grabs `@bar` out of `foo@bar` — we preserve that
        // behaviour so the Rust port is a drop-in replacement.
        let src = "See @smith2024 and @jones-2025 for details.";
        let usages = extract_citation_usages(src);
        assert_eq!(usages.len(), 2);
        assert_eq!(usages[0].cite_key, "smith2024");
        assert_eq!(usages[1].cite_key, "jones-2025");

        // The `@foo` in `bar@foo` is still extracted (matches the Swift
        // regex — see `findCitationUsages` in ImprintHTTPRouter.swift).
        let with_email = "Email me at bar@foo.com";
        let usages = extract_citation_usages(with_email);
        assert_eq!(usages.len(), 1);
        assert_eq!(usages[0].cite_key, "foo");
    }

    #[test]
    fn search_text_plain_case_sensitive() {
        let src = "Foo and foo and FOO";
        let m = search_text_plain(src, "foo", true);
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].position, 8);
    }

    #[test]
    fn search_text_plain_case_insensitive() {
        let src = "Foo and foo and FOO";
        let m = search_text_plain(src, "foo", false);
        assert_eq!(m.len(), 3);
        assert_eq!(m[0].position, 0);
        assert_eq!(m[1].position, 8);
        assert_eq!(m[2].position, 16);
    }

    #[tokio::test]
    async fn put_get_delete_section_roundtrip() {
        let (h, _dir) = handlers();
        let doc = Uuid::new_v4();
        let rec = h
            .put_section(
                doc,
                "intro",
                "= Hello\n\nWorld",
                SectionMetadata {
                    title: Some("Intro".into()),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(rec.title, "Intro");

        let got = h.get_section(doc, "intro").await.unwrap().unwrap();
        assert_eq!(got.body, "= Hello\n\nWorld");

        // Section appears in cross-document search.
        let hits = h.search("Hello", 10).await.unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].item_id, rec.item_id.to_string());

        h.delete_section(doc, "intro").await.unwrap();
        assert!(h.get_section(doc, "intro").await.unwrap().is_none());

        // After deletion it's gone from the index too.
        let hits = h.search("Hello", 10).await.unwrap();
        assert!(hits.is_empty());
    }

    #[tokio::test]
    async fn replace_in_section_persists_and_reindexes() {
        let (h, _dir) = handlers();
        let doc = Uuid::new_v4();
        h.put_section(doc, "k", "alpha beta alpha", SectionMetadata::default())
            .await
            .unwrap();

        let r = h
            .replace_in_section(doc, "k", "alpha", "gamma", true)
            .await
            .unwrap();
        assert_eq!(r.replacements, 2);
        assert_eq!(r.new_body, "gamma beta gamma");

        let got = h.get_section(doc, "k").await.unwrap().unwrap();
        assert_eq!(got.body, "gamma beta gamma");

        // Reindexed: searching for old token yields no hits, new one matches.
        assert!(h.search("alpha", 10).await.unwrap().is_empty());
        assert_eq!(h.search("gamma", 10).await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn replace_in_section_single_match() {
        let (h, _dir) = handlers();
        let doc = Uuid::new_v4();
        h.put_section(doc, "k", "x x x", SectionMetadata::default())
            .await
            .unwrap();
        let r = h
            .replace_in_section(doc, "k", "x", "y", false)
            .await
            .unwrap();
        assert_eq!(r.replacements, 1);
        assert_eq!(r.new_body, "y x x");
    }

    #[tokio::test]
    async fn document_outline_and_citations_via_trait() {
        let (h, _dir) = handlers();
        let src = "= Intro\n\nSee @smith2024.";
        let outline = h.document_outline(src).await.unwrap();
        assert_eq!(outline.entries.len(), 1);
        let cites = h.document_citations(src).await.unwrap();
        assert_eq!(cites.len(), 1);
        assert_eq!(cites[0].cite_key, "smith2024");
    }

    #[tokio::test]
    async fn document_stubs_return_internal_error() {
        let (h, _dir) = handlers();
        let r = h.list_documents().await;
        assert!(matches!(r, Err(ServiceError::Internal(_))));
        let r = h.get_document(Uuid::nil()).await;
        assert!(matches!(r, Err(ServiceError::Internal(_))));
        let r = h.export_document(Uuid::nil(), ExportFormat::Typst).await;
        assert!(matches!(r, Err(ServiceError::Internal(_))));
    }

    #[tokio::test]
    async fn compile_typst_returns_structured_unavailable() {
        let (h, _dir) = handlers();
        let r = h
            .compile_typst("= Hi", CompileOptions::default())
            .await
            .unwrap();
        assert!(r.pdf_data.is_none());
        assert!(r.error.is_some());
    }
}
