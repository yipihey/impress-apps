//! Cross-app orchestration — the seams that make impress a suite rather than
//! five apps.
//!
//! "Integration Over Independence" made executable: cite a paper from imbib
//! into an imprint manuscript, embed an implore figure, pull the papers out of
//! an impart conversation. Nothing else in the suite does this, which makes
//! these the highest-value tools in the server.
//!
//! Every method composes the *service traits*, never HTTP. That is the whole
//! reason this crate exists after the app services rather than beside them: the
//! TypeScript bridges each re-implemented their own calls to each app, so a
//! change to imbib's API meant editing imbib's client and every bridge that
//! touched it. Here a bridge calls a generated method, and the routing —
//! store-backed or over HTTP to a running app — is somebody else's problem.

use std::path::PathBuf;

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// An identifier found in free text, with the kind that was recognised.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ExtractedIdentifier {
    /// `doi`, `arxiv` or `isbn`.
    pub kind: String,
    pub value: String,
}

/// What a citation attempt did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CitationResult {
    pub ok: bool,
    /// Cite keys successfully cited.
    pub cited: Vec<String>,
    /// Cite keys that could not be resolved in imbib, with why.
    pub failed: Vec<String>,
    pub message: String,
}

/// What a figure embed did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct FigureEmbedResult {
    pub ok: bool,
    /// Where the exported image landed.
    pub path: Option<String>,
    /// The Typst snippet inserted, so the caller can see exactly what changed.
    pub inserted: Option<String>,
    pub message: String,
}

/// One item in the shared store, whatever app wrote it.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct StoreItem {
    pub id: String,
    /// e.g. `imbib/bibliography-entry`, `imprint/manuscript`.
    pub schema_ref: String,
    #[serde(default)]
    pub title: Option<String>,
    /// The item's payload as JSON, verbatim.
    pub payload_json: String,
}

/// A structured outline distilled from a conversation.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ConversationOutline {
    pub conversation_id: String,
    pub title: String,
    /// Section headings in the order they should appear.
    pub sections: Vec<String>,
    /// Decisions recorded in the conversation, which usually become methods
    /// or design-rationale paragraphs.
    pub decisions: Vec<String>,
    /// Cite keys and identifiers mentioned, for the bibliography.
    pub references: Vec<String>,
}

/// Tier B examples require PID-owned imbib, imprint, implore, and impart
/// hosts backed by the same scratch store. Their 5f-prefixed document,
/// conversation, figure, and library IDs must be created by that host fixture
/// before invocation, with papers `G3Bridge2026` and
/// `G3BridgeFollowup2026`, a writable Typst manuscript, an exportable figure,
/// and a conversation whose summary names known paper identifiers. The
/// pre-exported SVG example also needs that file under the owned workspace.
/// These are not claims about a default running app.
#[impress_service]
pub trait ImpressBridgesService: Send + Sync + 'static {
    // ---- imbib → imprint: citations ---------------------------------------

    /// Cite a paper from imbib in an imprint manuscript: looks the cite key up
    /// in the library, confirms it resolves, and inserts an `@citeKey` at the
    /// end of the document. THE primary way to cite — the bibliography is
    /// assembled from `@` references at compile time, so nothing else needs
    /// editing. Fails loudly when the key is not in imbib rather than inserting
    /// a reference that will not compile.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/library"], reach = [app("imprint")]))]
    #[impress_example(
        name = "cite_isolated_manuscript",
        tier = "b",
        args = r#"{"cite_key":"G3Bridge2026","document_id":"5f000000-0000-4000-8000-000000000010"}"#
    )]
    async fn cite_paper(&self, cite_key: String, document_id: String) -> CitationResult;

    /// Cite several papers at once. Prefer this to repeated single calls: it is
    /// one pass over the library and one document write.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/tag-definition"], reach = [app("imprint")]))]
    #[impress_example(
        name = "cite_two_isolated_papers",
        tier = "b",
        args = r#"{"cite_keys":["G3Bridge2026","G3BridgeFollowup2026"],"document_id":"5f000000-0000-4000-8000-000000000010"}"#
    )]
    async fn cite_multiple(&self, cite_keys: Vec<String>, document_id: String) -> CitationResult;

    /// Cite a paper inside a specific section rather than at the end of the
    /// document. It anchors the append on the section body it just read;
    /// if that body no longer matches, it reports failure instead of claiming
    /// the citation landed. Empty sections cannot be appended by the current
    /// section replacement API.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "manuscript", "manuscript-section"], writes = ["manuscript-section", "citation-usage"]))]
    #[impress_example(
        name = "cite_scratch_methods",
        args = r#"{"cite_key":"G3Bridge2026","document_id":"5f000000-0000-4000-8000-000000000010","section_key":"methods"}"#,
        expect = r#"{"ok":true,"cited":["G3Bridge2026"]}"#
    )]
    async fn cite_in_section(
        &self,
        cite_key: String,
        document_id: String,
        section_key: String,
    ) -> CitationResult;

    /// Papers in imbib that look relevant to what a manuscript already cites —
    /// a starting point for "what am I missing?", not a verdict. Returns cite
    /// keys, which you then cite explicitly.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"], reach = [app("imprint")]))]
    #[impress_example(
        name = "suggest_for_isolated_manuscript",
        tier = "b",
        args = r#"{"document_id":"5f000000-0000-4000-8000-000000000010","limit":5}"#
    )]
    async fn get_citation_suggestions(&self, document_id: String, limit: u32) -> Vec<String>;

    // ---- implore → imprint: figures ---------------------------------------

    /// Figures in implore that can be embedded into a manuscript, with the ids
    /// the embed tools take. Call this first: figure ids are implore's, not
    /// imprint's.
    #[impress_method(effects(reach = [app("implore")]))]
    #[impress_example(name = "list_isolated_figures", tier = "b", args = r#"{}"#)]
    async fn list_available_figures(&self) -> Vec<String>;

    /// Embed an implore figure into an imprint manuscript: exports the figure
    /// to a file and inserts a Typst `#image(...)` reference pointing at it.
    /// `format` is `png`, `pdf` or `svg` — use `pdf` or `svg` for print.
    #[impress_method(effects(reads = [target(figure_id)], reach = [app("implore"), app("imprint"), fs]))]
    #[impress_example(
        name = "embed_isolated_svg",
        tier = "b",
        args = r#"{"figure_id":"5f000000-0000-4000-8000-000000000030","document_id":"5f000000-0000-4000-8000-000000000010","format":"svg"}"#
    )]
    async fn embed_figure(
        &self,
        figure_id: String,
        document_id: String,
        format: String,
    ) -> FigureEmbedResult;

    /// Insert only the `#image(...)` reference, without re-exporting. Use when
    /// the file already exists and you are re-linking it.
    #[impress_method(effects(reads = [target(figure_id)], reach = [app("imprint")]))]
    #[impress_example(
        name = "reference_preexported_figure",
        tier = "b",
        args = r#"{"figure_id":"5f000000-0000-4000-8000-000000000030","document_id":"5f000000-0000-4000-8000-000000000010","path":"{{fixture.root}}/figures/bridge.svg"}"#
    )]
    async fn embed_figure_reference(
        &self,
        figure_id: String,
        document_id: String,
        path: String,
    ) -> FigureEmbedResult;

    /// Re-export a figure that is already embedded, so the manuscript picks up
    /// changes made in implore. The reference is left alone; only the file it
    /// points at is rewritten.
    #[impress_method(effects(reads = [target(figure_id)], reach = [app("implore"), fs]))]
    #[impress_example(
        name = "resync_isolated_figure",
        tier = "b",
        args = r#"{"figure_id":"5f000000-0000-4000-8000-000000000030","format":"svg"}"#
    )]
    async fn sync_figure(&self, figure_id: String, format: String) -> FigureEmbedResult;

    // ---- text and conversations → imbib -----------------------------------

    /// Pull paper identifiers — DOIs, arXiv ids, ISBNs — out of arbitrary text.
    /// Useful on an email body, a reviewer's note, a README. Finds candidates;
    /// it does not import them.
    #[impress_method(safety = read_only, effects())]
    #[impress_example(
        name = "find_doi_and_arxiv",
        args = r#"{"text":"Read 10.1086/145971 and arXiv:2301.00001 before drafting."}"#,
        expect = r#"[{"kind":"doi","value":"10.1086/145971"},{"kind":"arxiv","value":"2301.00001"}]"#
    )]
    async fn extract_papers_from_text(&self, text: String) -> Vec<ExtractedIdentifier>;

    /// The same extraction over every message in an impart conversation.
    #[impress_method(effects(reach = [app("impart"), network]))]
    #[impress_example(
        name = "identifiers_in_isolated_conversation",
        tier = "b",
        args = r#"{"conversation_id":"5f000000-0000-4000-8000-000000000040"}"#
    )]
    async fn extract_papers_from_conversation(
        &self,
        conversation_id: String,
    ) -> Vec<ExtractedIdentifier>;

    /// Extract identifiers from a conversation AND import them into imbib in
    /// one step. Returns the cite keys that landed.
    #[impress_method]
    #[impress_example(
        name = "import_isolated_conversation_papers",
        tier = "b",
        args = r#"{"conversation_id":"5f000000-0000-4000-8000-000000000040","library":"5f000000-0000-4000-8000-000000000001"}"#
    )]
    async fn add_papers_from_conversation(
        &self,
        conversation_id: String,
        library: Option<String>,
    ) -> Vec<String>;

    /// BibTeX for every paper an impart conversation mentions that is already
    /// in imbib — the bibliography for a manuscript grown out of that thread.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/linked-file", "imbib/tag-definition"], reach = [app("impart"), fs]))]
    #[impress_example(
        name = "bibtex_for_isolated_thread",
        tier = "b",
        args = r#"{"conversation_id":"5f000000-0000-4000-8000-000000000040"}"#
    )]
    async fn export_conversation_citations(&self, conversation_id: String) -> String;

    // ---- impart → imprint: structure --------------------------------------

    /// Decisions recorded in a conversation. These are what turn a discussion
    /// into a methods section — they were recorded deliberately rather than
    /// inferred from the messages.
    #[impress_method(effects(reach = [app("impart")]))]
    #[impress_example(
        name = "isolated_thread_decisions",
        tier = "b",
        args = r#"{"conversation_id":"5f000000-0000-4000-8000-000000000040"}"#
    )]
    async fn conversation_decisions(&self, conversation_id: String) -> Vec<String>;

    /// A manuscript outline distilled from a research conversation: its
    /// sections, the decisions behind them, and the references it touches.
    /// Deterministic — it reads what was recorded, it does not invent
    /// structure.
    #[impress_method(effects(reach = [app("impart"), provider]))]
    #[impress_example(
        name = "isolated_thread_outline",
        tier = "b",
        args = r#"{"conversation_id":"5f000000-0000-4000-8000-000000000040"}"#
    )]
    async fn conversation_to_outline(&self, conversation_id: String)
        -> Option<ConversationOutline>;

    // ---- the shared store -------------------------------------------------

    /// Search every app's items at once — papers, manuscripts, conversations,
    /// artifacts — in the one store they share. Reads the store directly, so it
    /// works with every app closed. The right opener when you do not yet know
    /// which app owns what you are looking for.
    #[impress_method(safety = read_only, effects(reads = [any("searches every kind")]))]
    #[impress_example(
        name = "search_scratch_artifacts",
        args = r#"{"query":"G3-bridge-needle","limit":1}"#,
        expect = r#"[{"id":"5f000000-0000-4000-8000-000000000020","title":"G3-bridge-needle source"}]"#
    )]
    async fn search_all(&self, query: String, limit: u32) -> Vec<StoreItem>;

    /// One item from the shared store by id, whichever app wrote it.
    #[impress_method(safety = read_only, effects(reads = [target(item_id)]))]
    #[impress_example(
        name = "get_scratch_artifact",
        args = r#"{"item_id":"5f000000-0000-4000-8000-000000000020"}"#,
        expect = r#"{"id":"5f000000-0000-4000-8000-000000000020","title":"G3-bridge-needle source"}"#
    )]
    async fn get_item(&self, item_id: String) -> Option<StoreItem>;

    /// Items linked to this one. NOTE: the store's edges are BIDIRECTIONAL, so
    /// this answers "what is connected?" and never "what does this depend on?".
    #[impress_method(safety = read_only, effects(reads = [target(item_id), any("walks references across kinds")]))]
    #[impress_example(
        name = "related_scratch_note",
        args = r#"{"item_id":"5f000000-0000-4000-8000-000000000020","limit":5}"#,
        expect = r#"[{"id":"5f000000-0000-4000-8000-000000000021","title":"G3 related note"}]"#
    )]
    async fn get_related(&self, item_id: String, limit: u32) -> Vec<StoreItem>;

    /// Resolve an `impress://` URI to whatever it names — an imbib paper, an
    /// imprint document, an impart conversation — so a reference can be passed
    /// between apps without the caller knowing which app owns it.
    #[impress_method(safety = read_only, effects(reads = [any("resolves a URI to whichever kind it names")]))]
    #[impress_example(
        name = "resolve_scratch_uri",
        args = r#"{"uri":"impress://artifact/5f000000-0000-4000-8000-000000000020"}"#,
        expect = r#"{"id":"5f000000-0000-4000-8000-000000000020","title":"G3-bridge-needle source"}"#
    )]
    async fn resolve_artifact(&self, uri: String) -> Option<StoreItem>;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

#[derive(Clone, Default)]
pub struct DefaultImpressBridgesService;

impl DefaultImpressBridgesService {
    pub fn new() -> Self {
        Self
    }
}

fn log(method: &str, msg: impl std::fmt::Display) {
    eprintln!("[impress-bridges] {method}: {msg}");
}

/// The shared store path, matching every other consumer in the suite.
fn shared_store_path() -> PathBuf {
    if let Some(path) = std::env::var_os("IMPRESS_STORE_PATH").filter(|path| !path.is_empty()) {
        return PathBuf::from(path);
    }
    dirs::home_dir()
        .map(|h| {
            h.join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
        })
        .unwrap_or_default()
}

fn open_store() -> Option<impress_core::sqlite_store::SqliteItemStore> {
    let path = shared_store_path();
    if !path.exists() {
        log("open_store", format!("no store at {}", path.display()));
        return None;
    }
    match impress_core::sqlite_store::SqliteItemStore::open(&path) {
        Ok(s) => Some(s),
        Err(e) => {
            log("open_store", e);
            None
        }
    }
}

/// How many (newest) rows `search_all` scans (LR-1's "a limit").
const SEARCH_ALL_SCAN_LIMIT: usize = 5_000;

fn to_store_item(item: &impress_core::item::Item) -> StoreItem {
    let payload_json = serde_json::to_string(&item.payload).unwrap_or_else(|_| "{}".into());
    let title = match item.payload.get("title") {
        Some(impress_core::item::Value::String(s)) => Some(s.clone()),
        _ => None,
    };
    StoreItem {
        id: item.id.to_string(),
        schema_ref: item.schema.to_string(),
        title,
        payload_json,
    }
}

fn extract_identifiers(text: &str) -> Vec<ExtractedIdentifier> {
    let mut out = Vec::new();
    for value in impress_identifiers::extract_dois(text.to_string()) {
        out.push(ExtractedIdentifier {
            kind: "doi".into(),
            value,
        });
    }
    for value in impress_identifiers::extract_arxiv_ids(text.to_string()) {
        out.push(ExtractedIdentifier {
            kind: "arxiv".into(),
            value,
        });
    }
    for value in impress_identifiers::extract_isbns(text.to_string()) {
        out.push(ExtractedIdentifier {
            kind: "isbn".into(),
            value,
        });
    }
    out
}

fn citation_replacement_landed(
    replacements: u32,
    new_body: &str,
    anchor: &str,
    cite_key: &str,
) -> bool {
    replacements == 1 && new_body == format!("{anchor} @{cite_key}")
}

/// Compose the `@citeKey` tokens and append them to a document.
async fn append_citations(document_id: &str, keys: &[String]) -> bool {
    let imprint_app = imprint_service::backend::app_service_instance();
    let Some(content) = imprint_app.get_content(document_id.to_string()).await else {
        return false;
    };
    let tokens: String = keys
        .iter()
        .map(|k| format!(" @{k}"))
        .collect::<Vec<_>>()
        .join("");
    imprint_app
        .insert_text(
            document_id.to_string(),
            content.chars().count() as u32,
            tokens,
        )
        .await
}

/// Which of these cite keys actually exist in imbib.
async fn resolve_cite_keys(keys: &[String]) -> (Vec<String>, Vec<String>) {
    let search = imbib_service::backend::search_service_instance();
    let mut found = Vec::new();
    let mut missing = Vec::new();
    for key in keys {
        if search.find_by_cite_key(key.clone(), None).await.is_some() {
            found.push(key.clone());
        } else {
            missing.push(key.clone());
        }
    }
    (found, missing)
}

#[async_trait::async_trait]
impl ImpressBridgesService for DefaultImpressBridgesService {
    async fn cite_paper(&self, cite_key: String, document_id: String) -> CitationResult {
        self.cite_multiple(vec![cite_key], document_id).await
    }

    async fn cite_multiple(&self, cite_keys: Vec<String>, document_id: String) -> CitationResult {
        let (found, missing) = resolve_cite_keys(&cite_keys).await;
        if found.is_empty() {
            return CitationResult {
                ok: false,
                cited: vec![],
                failed: missing,
                message: "None of those cite keys are in imbib. Search the library (or the \
                          outside world) and import them before citing."
                    .into(),
            };
        }
        let inserted = append_citations(&document_id, &found).await;
        CitationResult {
            ok: inserted,
            cited: if inserted { found.clone() } else { vec![] },
            failed: missing.clone(),
            message: if inserted {
                format!(
                    "Cited {} paper(s). The bibliography is assembled from @ references at \
                     compile time, so nothing else needs editing.{}",
                    found.len(),
                    if missing.is_empty() {
                        String::new()
                    } else {
                        format!(" Not found in imbib: {}.", missing.join(", "))
                    }
                )
            } else {
                "Could not write to the manuscript — is imprint running?".into()
            },
        }
    }

    async fn cite_in_section(
        &self,
        cite_key: String,
        document_id: String,
        section_key: String,
    ) -> CitationResult {
        let (found, missing) = resolve_cite_keys(std::slice::from_ref(&cite_key)).await;
        if found.is_empty() {
            return CitationResult {
                ok: false,
                cited: vec![],
                failed: missing,
                message: format!("{cite_key} is not in imbib."),
            };
        }
        let manuscript = imprint_service::backend::manuscript_service_instance();
        // The section replacement API rejects an empty find. Read the full
        // body as the anchor, then require a real replacement: a missing or
        // changed section must not masquerade as a successful citation.
        let Some(section) = manuscript
            .get_section(document_id.clone(), section_key.clone())
            .await
        else {
            return CitationResult {
                ok: false,
                cited: vec![],
                failed: missing,
                message: format!("Could not read section {section_key}."),
            };
        };
        if section.body.is_empty() {
            return CitationResult {
                ok: false,
                cited: vec![],
                failed: missing,
                message: format!("Could not cite in empty section {section_key}."),
            };
        }
        let result = manuscript
            .replace_in_section(
                document_id.clone(),
                section_key.clone(),
                section.body.clone(),
                format!("{} @{cite_key}", section.body),
            )
            .await;
        let ok = citation_replacement_landed(
            result.replacements,
            &result.new_body,
            &section.body,
            &cite_key,
        );
        CitationResult {
            ok,
            cited: if ok { found } else { vec![] },
            failed: missing,
            message: if ok {
                format!("Cited {cite_key} in section {section_key}.")
            } else {
                format!("Could not write section {section_key}.")
            },
        }
    }

    async fn get_citation_suggestions(&self, document_id: String, limit: u32) -> Vec<String> {
        // What the manuscript already cites tells us what it is about; feed
        // that back into the library as a search. Deliberately simple — this
        // suggests, it does not decide.
        let imprint_app = imprint_service::backend::app_service_instance();
        let Some(content) = imprint_app.get_content(document_id).await else {
            return vec![];
        };
        let text = imprint_service::text_service::DefaultImprintTextService;
        use imprint_service::text_service::ImprintTextService;
        let existing = text.extract_cite_keys(content, "typst".into()).await;
        if existing.is_empty() {
            return vec![];
        }
        let search = imbib_service::backend::search_service_instance();
        let mut out = Vec::new();
        for key in existing.iter().take(3) {
            for hit in search
                .full_text_search(key.clone(), None, if limit == 0 { 5 } else { limit })
                .await
            {
                if !existing.contains(&hit.cite_key) && !out.contains(&hit.cite_key) {
                    out.push(hit.cite_key);
                }
            }
        }
        out.truncate(if limit == 0 { 10 } else { limit as usize });
        out
    }

    async fn list_available_figures(&self) -> Vec<String> {
        implore_service::service_instance()
            .list_figures(None)
            .await
            .into_iter()
            .map(|f| format!("{} — {}", f.id, f.name))
            .collect()
    }

    async fn embed_figure(
        &self,
        figure_id: String,
        document_id: String,
        format: String,
    ) -> FigureEmbedResult {
        let implore = implore_service::service_instance();
        let Some(path) = implore.export_figure(figure_id.clone(), format).await else {
            return FigureEmbedResult {
                ok: false,
                path: None,
                inserted: None,
                message: "implore could not export that figure — is it running, and is the \
                          figure id from list_available_figures?"
                    .into(),
            };
        };
        self.embed_figure_reference(figure_id, document_id, path)
            .await
    }

    async fn embed_figure_reference(
        &self,
        _figure_id: String,
        document_id: String,
        path: String,
    ) -> FigureEmbedResult {
        let snippet = format!("\n#figure(image(\"{path}\"))\n");
        let imprint_app = imprint_service::backend::app_service_instance();
        let Some(content) = imprint_app.get_content(document_id.clone()).await else {
            return FigureEmbedResult {
                ok: false,
                path: Some(path),
                inserted: None,
                message: "Could not read the manuscript — is imprint running?".into(),
            };
        };
        let ok = imprint_app
            .insert_text(document_id, content.chars().count() as u32, snippet.clone())
            .await;
        FigureEmbedResult {
            ok,
            path: Some(path),
            inserted: if ok { Some(snippet) } else { None },
            message: if ok {
                "Figure embedded. The path is absolute — move the file and the reference breaks."
                    .into()
            } else {
                "Could not write to the manuscript.".into()
            },
        }
    }

    async fn sync_figure(&self, figure_id: String, format: String) -> FigureEmbedResult {
        let implore = implore_service::service_instance();
        match implore.export_figure(figure_id, format).await {
            Some(path) => FigureEmbedResult {
                ok: true,
                path: Some(path),
                inserted: None,
                message: "Figure re-exported. Any manuscript referencing that path picks it up \
                          on the next compile."
                    .into(),
            },
            None => FigureEmbedResult {
                ok: false,
                path: None,
                inserted: None,
                message: "implore could not re-export that figure.".into(),
            },
        }
    }

    async fn extract_papers_from_text(&self, text: String) -> Vec<ExtractedIdentifier> {
        extract_identifiers(&text)
    }

    async fn extract_papers_from_conversation(
        &self,
        conversation_id: String,
    ) -> Vec<ExtractedIdentifier> {
        let impart = impart_service::service_instance();
        let Some(conv) = impart.get_conversation(conversation_id).await else {
            return vec![];
        };
        let mut text = conv.title.clone();
        if let Some(s) = conv.summary {
            text.push('\n');
            text.push_str(&s);
        }
        extract_identifiers(&text)
    }

    async fn add_papers_from_conversation(
        &self,
        conversation_id: String,
        library: Option<String>,
    ) -> Vec<String> {
        // import_papers wants structured imports, not bare strings: route each
        // identifier into the field that matches its kind so imbib resolves it
        // rather than trying to parse it as BibTeX.
        let papers: Vec<imbib_service::library_service::PaperImport> = self
            .extract_papers_from_conversation(conversation_id)
            .await
            .into_iter()
            .map(|i| imbib_service::library_service::PaperImport {
                bibtex: String::new(),
                doi: (i.kind == "doi").then(|| i.value.clone()),
                arxiv_id: (i.kind == "arxiv").then(|| i.value.clone()),
                bibcode: None,
            })
            .collect();
        if papers.is_empty() {
            return vec![];
        }
        let imbib = imbib_service::backend::library_service_instance();
        let summary = imbib
            .import_papers(papers, library.unwrap_or_default())
            .await;
        summary.imported_ids
    }

    async fn export_conversation_citations(&self, conversation_id: String) -> String {
        let found_ids = self.extract_papers_from_conversation(conversation_id).await;
        let dois: Vec<String> = found_ids
            .iter()
            .filter(|i| i.kind == "doi")
            .map(|i| i.value.clone())
            .collect();
        let arxiv: Vec<String> = found_ids
            .iter()
            .filter(|i| i.kind == "arxiv")
            .map(|i| i.value.clone())
            .collect();
        if dois.is_empty() && arxiv.is_empty() {
            return String::new();
        }
        let search = imbib_service::backend::search_service_instance();
        let found = search.find_by_identifiers_batch(dois, arxiv, vec![]).await;
        // export_bibtex keys off publication ids, not cite keys.
        let ids: Vec<String> = found.into_iter().map(|p| p.id).collect();
        if ids.is_empty() {
            return String::new();
        }
        imbib_service::backend::library_service_instance()
            .export_bibtex(ids)
            .await
    }

    async fn conversation_decisions(&self, conversation_id: String) -> Vec<String> {
        let impart = impart_service::service_instance();
        match impart.get_conversation(conversation_id).await {
            // impart exposes decisions through the conversation payload; when
            // the app is closed this is empty rather than wrong.
            Some(c) => c.summary.into_iter().collect(),
            None => vec![],
        }
    }

    async fn conversation_to_outline(
        &self,
        conversation_id: String,
    ) -> Option<ConversationOutline> {
        let impart = impart_service::service_instance();
        let conv = impart.get_conversation(conversation_id.clone()).await?;
        let decisions = self.conversation_decisions(conversation_id.clone()).await;
        let references = self
            .extract_papers_from_conversation(conversation_id.clone())
            .await
            .into_iter()
            .map(|i| i.value)
            .collect();
        Some(ConversationOutline {
            conversation_id,
            title: conv.title,
            // Deliberately the conventional skeleton rather than an invented
            // one: this tool reads what was recorded, it does not guess at
            // structure the conversation never settled.
            sections: vec![
                "Introduction".into(),
                "Methods".into(),
                "Results".into(),
                "Discussion".into(),
            ],
            decisions,
            references,
        })
    }

    async fn search_all(&self, query: String, limit: u32) -> Vec<StoreItem> {
        use impress_core::store::ItemStore;
        let Some(store) = open_store() else {
            return vec![];
        };
        // Bounded (LR-1): this is a substring scan over payloads in Rust,
        // and unbounded it walked every row on the device — millions of
        // operation rows included. The newest SEARCH_ALL_SCAN_LIMIT items
        // are the window; a store-side search is `search_ops`' job.
        let q = impress_core::query::ItemQuery {
            sort: vec![impress_core::query::SortDescriptor {
                field: "modified".into(),
                ascending: false,
            }],
            limit: Some(SEARCH_ALL_SCAN_LIMIT),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let needle = query.to_lowercase();
        match store.query(&q) {
            Ok(items) => items
                .iter()
                .filter(|i| {
                    serde_json::to_string(&i.payload)
                        .map(|s| s.to_lowercase().contains(&needle))
                        .unwrap_or(false)
                })
                .take(if limit == 0 { 20 } else { limit as usize })
                .map(to_store_item)
                .collect(),
            Err(e) => {
                log("search_all", e);
                vec![]
            }
        }
    }

    async fn get_item(&self, item_id: String) -> Option<StoreItem> {
        use impress_core::store::ItemStore;
        let store = open_store()?;
        let id = item_id.parse().ok()?;
        match store.get(id) {
            Ok(Some(item)) => Some(to_store_item(&item)),
            Ok(None) => None,
            Err(e) => {
                log("get_item", e);
                None
            }
        }
    }

    async fn get_related(&self, item_id: String, limit: u32) -> Vec<StoreItem> {
        use impress_core::store::ItemStore;
        let Some(store) = open_store() else {
            return vec![];
        };
        let Ok(id) = item_id.parse() else {
            return vec![];
        };
        // Depth 1: direct links only. The store's edges are bidirectional, so
        // deeper walks fan out fast and stop meaning "related to this".
        match store.neighbors(id, &[], 1) {
            Ok(items) => items
                .iter()
                .take(if limit == 0 { 20 } else { limit as usize })
                .map(to_store_item)
                .collect(),
            Err(e) => {
                log("get_related", e);
                vec![]
            }
        }
    }

    async fn resolve_artifact(&self, uri: String) -> Option<StoreItem> {
        // impress://<kind>/<id> — the id is what the store knows; the kind is
        // a hint for the caller, not something we need to dispatch on.
        let id = uri
            .strip_prefix("impress://")
            .and_then(|rest| rest.rsplit('/').next())
            .unwrap_or(&uri)
            .to_string();
        self.get_item(id).await
    }
}

impress_service_impl! {
    service = ImpressBridgesService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: ["conversation@1.0.0", "chat-message", "imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper"],
        writes: ["imbib/bibliography-entry"],
        reach: [app("impart"), network],
    },
    impl = DefaultImpressBridgesService,
    instance = DefaultImpressBridgesService::new,
    methods = [
        cite_paper(
            /// Cite key already present in imbib, without a leading `@`.
            cite_key: String,
            /// UUID of the imprint manuscript to append the reference to.
            document_id: String
        ) -> CitationResult,
        cite_multiple(
            /// Existing imbib cite keys to append in one document write.
            cite_keys: Vec<String>,
            /// UUID of the imprint manuscript receiving the references.
            document_id: String
        ) -> CitationResult,
        cite_in_section(
            /// Existing imbib cite key, without a leading `@`.
            cite_key: String,
            /// UUID of the manuscript that owns the section.
            document_id: String,
            /// Stable key of a nonempty stored manuscript section.
            section_key: String
        ) -> CitationResult,
        get_citation_suggestions(
            /// UUID of a manuscript whose existing citations seed the search.
            document_id: String,
            /// Maximum distinct suggestions; zero uses the default of ten.
            limit: u32
        ) -> Vec<String>,
        list_available_figures() -> Vec<String>,
        embed_figure(
            /// Figure id returned by the isolated implore host.
            figure_id: String,
            /// UUID of the imprint manuscript receiving a Typst image reference.
            document_id: String,
            /// Export format: `png`, `pdf`, or `svg`.
            format: String
        ) -> FigureEmbedResult,
        embed_figure_reference(
            /// Id of the already-exported implore figure.
            figure_id: String,
            /// UUID of the imprint manuscript receiving the reference.
            document_id: String,
            /// Absolute path of the image already exported into the owned workspace.
            path: String
        ) -> FigureEmbedResult,
        sync_figure(
            /// Id of the implore figure to re-export.
            figure_id: String,
            /// Re-export format: `png`, `pdf`, or `svg`.
            format: String
        ) -> FigureEmbedResult,
        extract_papers_from_text(
            /// Text to scan locally for DOI, arXiv, and ISBN candidates.
            text: String
        ) -> Vec<ExtractedIdentifier>,
        extract_papers_from_conversation(
            /// UUID of the impart conversation whose title and summary are scanned.
            conversation_id: String
        ) -> Vec<ExtractedIdentifier>,
        add_papers_from_conversation(
            /// UUID of the impart conversation containing paper identifiers.
            conversation_id: String,
            /// Target imbib library UUID; null selects the service default.
            library: Option<String>
        ) -> Vec<String>,
        export_conversation_citations(
            /// UUID of the impart conversation to turn into BibTeX.
            conversation_id: String
        ) -> String,
        conversation_decisions(
            /// UUID of the impart conversation whose recorded summary is returned.
            conversation_id: String
        ) -> Vec<String>,
        conversation_to_outline(
            /// UUID of the impart conversation to structure into an outline.
            conversation_id: String
        ) -> Option<ConversationOutline>,
        search_all(
            /// Case-insensitive payload substring to find across the latest 5,000 items.
            query: String,
            /// Maximum matching items; zero selects the default of twenty.
            limit: u32
        ) -> Vec<StoreItem>,
        get_item(
            /// UUID of any item in the shared store.
            item_id: String
        ) -> Option<StoreItem>,
        get_related(
            /// UUID of the item whose direct graph neighbors are needed.
            item_id: String,
            /// Maximum direct neighbors; zero selects the default of twenty.
            limit: u32
        ) -> Vec<StoreItem>,
        resolve_artifact(
            /// `impress://<kind>/<uuid>` URI, or a bare item UUID.
            uri: String
        ) -> Option<StoreItem>,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identifiers_come_out_of_free_text() {
        let text = "See 10.1086/145971 and arXiv:2301.00001 for the details.";
        let found = extract_identifiers(text);
        assert!(
            found.iter().any(|i| i.kind == "doi"),
            "expected a DOI in {found:?}"
        );
        assert!(
            found.iter().any(|i| i.kind == "arxiv"),
            "expected an arXiv id in {found:?}"
        );
    }

    #[test]
    fn artifact_uris_reduce_to_an_item_id() {
        // The resolver takes the last path segment, so every impress:// shape
        // lands on the same store lookup.
        for uri in [
            "impress://paper/0190C0DE-0000-0000-0000-000000000000",
            "impress://imprint/document/0190C0DE-0000-0000-0000-000000000000",
        ] {
            let id = uri
                .strip_prefix("impress://")
                .and_then(|rest| rest.rsplit('/').next())
                .unwrap();
            assert_eq!(id, "0190C0DE-0000-0000-0000-000000000000");
        }
    }

    #[test]
    fn section_citation_requires_an_actual_match_of_the_body_just_read() {
        let original = "The method uses spectra.";
        assert!(citation_replacement_landed(
            1,
            "The method uses spectra. @G3Bridge2026",
            original,
            "G3Bridge2026"
        ));
        // The section changed after our read: the replacement API returns
        // its unchanged current body, which must not be reported as cited.
        assert!(!citation_replacement_landed(
            0,
            "The method now uses photometry.",
            original,
            "G3Bridge2026"
        ));
        assert!(!citation_replacement_landed(
            1,
            "",
            original,
            "G3Bridge2026"
        ));
    }
}
