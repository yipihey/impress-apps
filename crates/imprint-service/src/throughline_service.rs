//! `ImprintThroughlineService` — macro-wired service trait for throughlines
//! (ADR-0016). One trait definition yields MCP tools, CLI subcommands, and
//! JSON dispatch via the `#[impress_service]` pipeline, mirroring
//! `manuscript_service.rs`.
//!
//! Opt-in contract (ADR-0016 D1): every getter returns `None`/empty for a
//! document without a throughline — a single keyed store get, no scan, no
//! writes, no logging.

use std::sync::Arc;

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use uuid::Uuid;

use crate::error::ServiceError;
use crate::throughline::{AnchorAssessment, ThroughlineRecord, ThroughlineStore};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// Summary of a document's throughline.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct ThroughlineInfoDto {
    pub item_id: String,
    pub document_id: String,
    pub title: String,
    /// Typst source of the narrative.
    pub source: String,
    /// Serialized anchor map (sync ledger) JSON.
    pub anchor_map_json: String,
    pub paragraph_count: i64,
    pub content_hash: String,
}

impl ThroughlineInfoDto {
    fn from_record(rec: &ThroughlineRecord) -> Self {
        Self {
            item_id: rec.item_id.clone(),
            document_id: rec.document_id.clone(),
            title: rec.title.clone(),
            source: rec.source.clone(),
            anchor_map_json: rec.anchor_map.serialize().unwrap_or_default(),
            paragraph_count: rec.paragraph_count,
            content_hash: rec.content_hash.clone(),
        }
    }
}

/// Derived state of one anchor (ADR-0016 D5).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct AnchorStateDto {
    pub label: String,
    /// `synced | manuscript-ahead | throughline-ahead |
    /// manuscript-ahead+throughline-ahead | broken`
    pub state: String,
    pub manuscript_ahead: Vec<String>,
    pub throughline_ahead: bool,
    pub broken: Vec<String>,
    pub missing_paragraph: bool,
}

impl AnchorStateDto {
    fn from_assessment(a: &AnchorAssessment) -> Self {
        Self {
            label: a.label.clone(),
            state: a.state(),
            manuscript_ahead: a.manuscript_ahead.clone(),
            throughline_ahead: a.throughline_ahead,
            broken: a.broken.clone(),
            missing_paragraph: a.missing_paragraph,
        }
    }
}

/// Coverage report: sections not narrated and not marked supporting
/// (ADR-0016 D7).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct CoverageDto {
    /// True when the document has a throughline at all. When false, the
    /// other fields are empty — coverage is only meaningful for opted-in
    /// documents.
    pub has_throughline: bool,
    pub uncovered_section_keys: Vec<String>,
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

#[impress_service]
pub trait ImprintThroughlineService: Send + Sync + 'static {
    /// Create a throughline for a document (explicit opt-in, ADR-0016 D1).
    /// Fails if one already exists.
    #[impress_method]
    async fn create_throughline(&self, doc_id: String, title: String)
        -> Option<ThroughlineInfoDto>;

    /// Fetch a document's throughline, or None if it has none.
    #[impress_method]
    async fn get_throughline(&self, doc_id: String) -> Option<ThroughlineInfoDto>;

    /// Replace the narrative source. The ledger is untouched — edited
    /// paragraphs derive `throughline-ahead` until a sync is accepted.
    #[impress_method]
    async fn update_throughline_source(
        &self,
        doc_id: String,
        source: String,
    ) -> Option<ThroughlineInfoDto>;

    /// Remove a document's throughline (deactivation). Returns whether one
    /// existed.
    #[impress_method]
    async fn delete_throughline(&self, doc_id: String) -> bool;

    /// Derived anchor states (empty when the document has no throughline).
    #[impress_method]
    async fn get_anchor_states(&self, doc_id: String) -> Vec<AnchorStateDto>;

    /// Coverage report (ADR-0016 D7).
    #[impress_method]
    async fn get_coverage(&self, doc_id: String) -> CoverageDto;

    /// Anchor a paragraph label to section keys, baselining ledger hashes.
    #[impress_method]
    async fn set_anchor(
        &self,
        doc_id: String,
        label: String,
        section_keys: Vec<String>,
    ) -> Option<ThroughlineInfoDto>;

    /// Remove an anchor from the ledger.
    #[impress_method]
    async fn remove_anchor(&self, doc_id: String, label: String) -> Option<ThroughlineInfoDto>;

    /// Mark or unmark a section as deliberate supporting detail.
    #[impress_method]
    async fn mark_supporting(
        &self,
        doc_id: String,
        section_key: String,
        supporting: bool,
    ) -> Option<ThroughlineInfoDto>;
}

// ---------------------------------------------------------------------------
// Default impl backed by ThroughlineStore (shared store)
// ---------------------------------------------------------------------------

/// Store-backed implementation. Adapts `Result`-returning store methods to
/// the macro-friendly "return T, log errors to stderr" shape (matching
/// `DefaultImprintManuscriptService`).
#[derive(Clone)]
pub struct DefaultImprintThroughlineService {
    store: Arc<ThroughlineStore>,
}

impl DefaultImprintThroughlineService {
    pub fn new(store: Arc<ThroughlineStore>) -> Self {
        Self { store }
    }

    fn parse_doc_id(doc_id: &str) -> Option<Uuid> {
        match Uuid::parse_str(doc_id) {
            Ok(u) => Some(u),
            Err(e) => {
                eprintln!("[imprint-service::throughline] invalid doc id '{doc_id}': {e}");
                None
            }
        }
    }

    fn log_err<T>(context: &str, result: Result<T, ServiceError>) -> Option<T> {
        match result {
            Ok(v) => Some(v),
            Err(e) => {
                eprintln!("[imprint-service::throughline] {context}: {e}");
                None
            }
        }
    }
}

#[async_trait::async_trait]
impl ImprintThroughlineService for DefaultImprintThroughlineService {
    async fn create_throughline(
        &self,
        doc_id: String,
        title: String,
    ) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err("create", self.store.create_throughline(doc, &title))
            .map(|r| ThroughlineInfoDto::from_record(&r))
    }

    async fn get_throughline(&self, doc_id: String) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err("get", self.store.get_throughline(doc))
            .flatten()
            .map(|r| ThroughlineInfoDto::from_record(&r))
    }

    async fn update_throughline_source(
        &self,
        doc_id: String,
        source: String,
    ) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err("update_source", self.store.update_source(doc, &source))
            .map(|r| ThroughlineInfoDto::from_record(&r))
    }

    async fn delete_throughline(&self, doc_id: String) -> bool {
        let Some(doc) = Self::parse_doc_id(&doc_id) else {
            return false;
        };
        Self::log_err("delete", self.store.delete_throughline(doc)).unwrap_or(false)
    }

    async fn get_anchor_states(&self, doc_id: String) -> Vec<AnchorStateDto> {
        let Some(doc) = Self::parse_doc_id(&doc_id) else {
            return vec![];
        };
        Self::log_err("anchor_states", self.store.anchor_states(doc))
            .flatten()
            .map(|states| states.iter().map(AnchorStateDto::from_assessment).collect())
            .unwrap_or_default()
    }

    async fn get_coverage(&self, doc_id: String) -> CoverageDto {
        let empty = CoverageDto {
            has_throughline: false,
            uncovered_section_keys: vec![],
        };
        let Some(doc) = Self::parse_doc_id(&doc_id) else {
            return empty;
        };
        match Self::log_err("coverage", self.store.coverage(doc)).flatten() {
            Some(keys) => CoverageDto {
                has_throughline: true,
                uncovered_section_keys: keys,
            },
            None => empty,
        }
    }

    async fn set_anchor(
        &self,
        doc_id: String,
        label: String,
        section_keys: Vec<String>,
    ) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err(
            "set_anchor",
            self.store.set_anchor(doc, &label, &section_keys),
        )
        .map(|r| ThroughlineInfoDto::from_record(&r))
    }

    async fn remove_anchor(&self, doc_id: String, label: String) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err("remove_anchor", self.store.remove_anchor(doc, &label))
            .map(|r| ThroughlineInfoDto::from_record(&r))
    }

    async fn mark_supporting(
        &self,
        doc_id: String,
        section_key: String,
        supporting: bool,
    ) -> Option<ThroughlineInfoDto> {
        let doc = Self::parse_doc_id(&doc_id)?;
        Self::log_err(
            "mark_supporting",
            self.store.mark_supporting(doc, &section_key, supporting),
        )
        .map(|r| ThroughlineInfoDto::from_record(&r))
    }
}

// ---------------------------------------------------------------------------
// Macro registration
// ---------------------------------------------------------------------------

impress_service_impl! {
    service = ImprintThroughlineService,
    impl = DefaultImprintThroughlineService,
    instance = || crate::backend::throughline_service_instance(),
    methods = [
        create_throughline(doc_id: String, title: String) -> Option<ThroughlineInfoDto>,
        get_throughline(doc_id: String) -> Option<ThroughlineInfoDto>,
        update_throughline_source(doc_id: String, source: String) -> Option<ThroughlineInfoDto>,
        delete_throughline(doc_id: String) -> bool,
        get_anchor_states(doc_id: String) -> Vec<AnchorStateDto>,
        get_coverage(doc_id: String) -> CoverageDto,
        set_anchor(doc_id: String, label: String, section_keys: Vec<String>) -> Option<ThroughlineInfoDto>,
        remove_anchor(doc_id: String, label: String) -> Option<ThroughlineInfoDto>,
        mark_supporting(doc_id: String, section_key: String, supporting: bool) -> Option<ThroughlineInfoDto>,
    ],
}
