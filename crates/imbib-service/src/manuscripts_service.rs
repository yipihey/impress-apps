//! `ImbibManuscriptsService` — manuscripts as shared-store rows.
//!
//! # Why this lives in imbib-service and not imprint-service
//!
//! Manuscripts are first-class rows in the shared store (ADR-0018), and imbib
//! serves them at `/api/manuscripts` even though the authoring GUI is imprint's.
//! Putting them here follows the routes rather than the app name.
//!
//! That leaves two ways to reach a manuscript, which is deliberate and not the
//! duplication this migration exists to remove:
//!
//! * **Here** — store-level CRUD and a headless compile. Works with imprint
//!   closed, which is the point: an agent can draft and compile without the
//!   editor running.
//! * **`imprint-manuscript-service`** — sections, outline, citations, and
//!   compiles through imprint's persistent Typst engine. Needs imprint, and
//!   gives you compare-and-set section writes that cannot clobber a concurrent
//!   edit.
//!
//! The descriptions say which to reach for. Prefer imprint's section tools when
//! it is running; use these when it is not, or when you want the whole body in
//! one write.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// A manuscript row: metadata only, never the body.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ManuscriptRecord {
    pub id: String,
    #[serde(default)]
    pub title: String,
    /// `typst`, `latex`, or unset.
    #[serde(default)]
    pub format: Option<String>,
    /// imbib returns this as `manuscriptStatus` on the detail route and
    /// `status` on the list route; accept either.
    #[serde(default, alias = "manuscriptStatus")]
    pub status: Option<String>,
    /// Compare-and-set token for `write_manuscript_body`. Changes on every
    /// write, which is what makes a lost update detectable.
    #[serde(default, alias = "contentHash")]
    pub content_hash: Option<String>,
    #[serde(default, alias = "updatedAt")]
    pub updated_at: Option<String>,
}

/// A manuscript template.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TemplateRecord {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default, alias = "isBuiltin")]
    pub is_builtin: Option<bool>,
}

/// The result of a headless compile.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CompileResult {
    pub ok: bool,
    #[serde(default)]
    pub pdf_path: Option<String>,
    #[serde(default)]
    pub page_count: Option<u32>,
    /// Errors and warnings from the compiler, in source order.
    #[serde(default)]
    pub messages: Vec<String>,
}

/// The outcome of a compare-and-set body write.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct WriteResult {
    pub ok: bool,
    /// The new content hash, to pass to the next write.
    #[serde(default)]
    pub content_hash: Option<String>,
    pub message: String,
}

#[impress_service]
pub trait ImbibManuscriptsService: Send + Sync + 'static {
    /// Manuscripts in the shared store: id, title, format and status. Metadata
    /// only, no body. START HERE for any manuscript request — every other
    /// manuscript tool takes an id from this list.
    #[impress_method]
    async fn list_manuscripts(&self) -> Vec<ManuscriptRecord>;

    /// One manuscript's metadata, including the `content_hash` that
    /// `write_manuscript_body` requires.
    #[impress_method]
    async fn get_manuscript(&self, manuscript_id: String) -> Option<ManuscriptRecord>;

    /// Create a new manuscript row and return it. For changing an existing one
    /// use `write_manuscript_body`. Note there is no delete route: a manuscript
    /// created by mistake stays until someone removes it in the UI.
    #[impress_method]
    async fn create_manuscript(
        &self,
        title: String,
        format: Option<String>,
    ) -> Option<ManuscriptRecord>;

    /// Replace a manuscript's ENTIRE body, compare-and-set. There is no
    /// patch/append route here — send the whole document. `expected_hash` is
    /// the `content_hash` from `get_manuscript`; a mismatch means someone else
    /// wrote in between and the call is refused rather than clobbering them.
    /// When imprint is running, its section tools are the finer-grained option.
    #[impress_method]
    async fn write_manuscript_body(
        &self,
        manuscript_id: String,
        body: String,
        expected_hash: String,
    ) -> WriteResult;

    /// Compile a manuscript headlessly, with the store-backed virtual
    /// bibliography — `@citeKey` references resolve against the imbib library,
    /// so there is no .bib file to maintain. Works with imprint closed.
    #[impress_method]
    async fn compile_manuscript(&self, manuscript_id: String) -> CompileResult;

    /// Manuscript templates available to `create_manuscript_from_template` —
    /// journal and conference styles (ApJ, A&A, ARA&A, ICML, NeurIPS, …) plus
    /// any the user has added.
    #[impress_method]
    async fn list_templates(&self) -> Vec<TemplateRecord>;

    /// Create a manuscript scaffolded from a template: front matter, section
    /// skeleton and the journal's Typst styling, ready to write into.
    #[impress_method]
    async fn create_manuscript_from_template(
        &self,
        template_id: String,
        title: String,
    ) -> Option<ManuscriptRecord>;
}

#[derive(Clone)]
pub struct DefaultImbibManuscriptsService {
    #[allow(dead_code)]
    store: Arc<ImbibStore>,
}

impl DefaultImbibManuscriptsService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }
}

const NOT_RUNNING: &str = "imbib is not running. Manuscripts are shared-store rows, but creating, \
     writing and compiling them go through imbib's API so the running app sees \
     the change. Open imbib and try again.";

fn refuse(method: &str) {
    eprintln!("[imbib-manuscripts-service] {method}: imbib not running; refused");
}

#[async_trait::async_trait]
impl ImbibManuscriptsService for DefaultImbibManuscriptsService {
    async fn list_manuscripts(&self) -> Vec<ManuscriptRecord> {
        refuse("list_manuscripts");
        vec![]
    }
    async fn get_manuscript(&self, _manuscript_id: String) -> Option<ManuscriptRecord> {
        refuse("get_manuscript");
        None
    }
    async fn create_manuscript(
        &self,
        _title: String,
        _format: Option<String>,
    ) -> Option<ManuscriptRecord> {
        refuse("create_manuscript");
        None
    }
    async fn write_manuscript_body(
        &self,
        _manuscript_id: String,
        _body: String,
        _expected_hash: String,
    ) -> WriteResult {
        refuse("write_manuscript_body");
        WriteResult {
            ok: false,
            content_hash: None,
            message: NOT_RUNNING.into(),
        }
    }
    async fn compile_manuscript(&self, _manuscript_id: String) -> CompileResult {
        refuse("compile_manuscript");
        CompileResult {
            ok: false,
            pdf_path: None,
            page_count: None,
            messages: vec![NOT_RUNNING.into()],
        }
    }
    async fn list_templates(&self) -> Vec<TemplateRecord> {
        refuse("list_templates");
        vec![]
    }
    async fn create_manuscript_from_template(
        &self,
        _template_id: String,
        _title: String,
    ) -> Option<ManuscriptRecord> {
        refuse("create_manuscript_from_template");
        None
    }
}

impress_service_impl! {
    service = ImbibManuscriptsService,
    impl = DefaultImbibManuscriptsService,
    instance = crate::backend::manuscripts_service_instance,
    methods = [
        list_manuscripts() -> Vec<ManuscriptRecord>,
        get_manuscript(manuscript_id: String) -> Option<ManuscriptRecord>,
        create_manuscript(title: String, format: Option<String>) -> Option<ManuscriptRecord>,
        write_manuscript_body(
            manuscript_id: String,
            body: String,
            expected_hash: String
        ) -> WriteResult,
        compile_manuscript(manuscript_id: String) -> CompileResult,
        list_templates() -> Vec<TemplateRecord>,
        create_manuscript_from_template(
            template_id: String,
            title: String
        ) -> Option<ManuscriptRecord>,
    ],
}
