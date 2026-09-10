//! Tier A capabilities — pure Rust against the `imprint-service` traits.
//!
//! No app, no UI, no network. Each capability builds (or reuses) a service
//! bound to a throwaway temp workspace, exercises one behavior, and asserts on
//! the result. These run as ordinary `cargo test` and in CI.

use std::sync::Arc;

use imprint_service::manuscript_service::{
    DefaultImprintManuscriptService, ImprintManuscriptService,
};
use imprint_service::sections::SectionMetadata;
use imprint_service::text_service::{DefaultImprintTextService, ImprintTextService};
use imprint_service::throughline::ThroughlineStore;
use imprint_service::throughline_service::{
    DefaultImprintThroughlineService, ImprintThroughlineService,
};

use crate::{check, skipped, CapabilityResult, Tier};

/// A manuscript service bound to a fresh temp workspace, kept alive alongside
/// the `TempDir` so the SQLite file isn't reaped mid-test.
struct TempService {
    _dir: tempfile::TempDir,
    manuscript: DefaultImprintManuscriptService,
    throughline: DefaultImprintThroughlineService,
}

impl TempService {
    fn open() -> Result<Self, String> {
        let dir = tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?;
        let svc = imprint_service::open(dir.path()).map_err(|e| format!("open workspace: {e}"))?;
        let sections = Arc::new(svc.handlers.sections().clone());
        let manuscript = DefaultImprintManuscriptService::new(Arc::new(svc.handlers));
        let throughline =
            DefaultImprintThroughlineService::new(Arc::new(ThroughlineStore::new(sections)));
        Ok(Self {
            _dir: dir,
            manuscript,
            throughline,
        })
    }
}

/// Run all Tier A capabilities in sequence and collect the results.
pub async fn run() -> Vec<CapabilityResult> {
    let mut out = Vec::new();

    out.push(cap_format_latex().await);
    out.push(cap_extract_cite_keys_typst().await);
    out.push(cap_extract_cite_keys_latex().await);
    out.push(cap_compose_citation().await);
    out.push(cap_compose_heading().await);
    out.push(cap_document_outline().await);
    out.push(cap_document_citations().await);
    out.push(cap_search_in_text().await);
    out.push(cap_section_roundtrip().await);
    out.push(cap_replace_in_section().await);
    out.push(cap_compile_latex().await);
    out.push(cap_compile_typst_preview_package().await);
    out.push(cap_manuscript_formats().await);
    out.push(cap_manuscript_collab_convergence().await);
    out.push(cap_status_lifecycle().await);
    out.push(cap_throughline_create().await);
    out.push(cap_throughline_anchor_states().await);
    out.push(cap_throughline_coverage().await);
    out.push(cap_throughline_broken_anchor().await);
    out.push(cap_project_tree_roundtrip().await);
    out.push(cap_project_graph_diagnostics().await);
    out.push(cap_project_import_export_snapshot().await);
    out.push(cap_project_build_records().await);

    out
}

/// A project service over a private store with one manuscript row in it
/// (ADR-0030). The row is inserted by hand because creating manuscripts is
/// imbib's verb, not imprint's, and the selftest must not depend on it.
struct ProjectWorld {
    _dir: tempfile::TempDir,
    svc: imprint_service::DefaultImprintProjectService,
    manuscript_id: String,
}

impl ProjectWorld {
    fn open(format: &str, body: &str) -> Result<Self, String> {
        use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
        use impress_core::store::ItemStore;

        let dir = tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?;
        let store = std::sync::Arc::new(
            impress_core::sqlite_store::SqliteItemStore::open_in_memory()
                .map_err(|e| format!("open store: {e}"))?,
        );
        let id = uuid::Uuid::new_v4();
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("title".into(), Value::String("Selftest paper".into()));
        payload.insert("format".into(), Value::String(format.into()));
        payload.insert("status".into(), Value::String("draft".into()));
        payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
        payload.insert("body_content".into(), Value::String(body.into()));
        payload.insert(
            "body_content_hash".into(),
            Value::String(impress_core::manuscript_ops::sha256_hex(body)),
        );
        let now = chrono::Utc::now();
        store
            .insert(Item {
                id,
                schema: "manuscript".into(),
                payload,
                created: now,
                modified: now,
                author: "selftest".into(),
                author_kind: ActorKind::System,
                logical_clock: 0,
                origin: None,
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::Normal,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: None,
                references: vec![],
                parent: None,
            })
            .map_err(|e| format!("insert manuscript: {e}"))?;
        let svc = imprint_service::DefaultImprintProjectService::with_store(
            store,
            dir.path().join("content"),
        );
        Ok(Self {
            _dir: dir,
            svc,
            manuscript_id: id.to_string(),
        })
    }
}

/// ADR-0030 P0/P1: a manuscript is a project. A chapter and a figure added
/// through the verbs come back in the tree, the file read returns the text,
/// and a move plus a delete leave the tree as expected.
async fn cap_project_tree_roundtrip() -> CapabilityResult {
    check(
        "project.tree_roundtrip",
        "A chapter and a figure survive put → tree → file → move → delete through imprint-project-service",
        Tier::A,
        || async {
            use imprint_service::ImprintProjectService;
            let w = ProjectWorld::open("typst", "= Paper\n#include \"chapters/intro.typ\"")?;
            let id = w.manuscript_id.clone();
            let before = w.svc.project_tree(id.clone()).await;
            if !before.ok || !before.files.is_empty() || before.entry_path != "main.typ" {
                return Err(format!("fresh tree wrong: {before:?}"));
            }
            let put = w
                .svc
                .project_put_file(
                    id.clone(),
                    "chapters/intro.typ".into(),
                    Some("== Intro\nHello.".into()),
                    None,
                    None,
                    Some("selftest".into()),
                )
                .await;
            if !put.ok {
                return Err(format!("put chapter: {}", put.message));
            }
            let png = w._dir.path().join("f.png");
            std::fs::write(&png, b"\x89PNG\r\n\x1a\n\0\0").map_err(|e| e.to_string())?;
            let put_png = w
                .svc
                .project_put_file(
                    id.clone(),
                    "figures/f.png".into(),
                    None,
                    Some(png.display().to_string()),
                    None,
                    None,
                )
                .await;
            if !put_png.ok || put_png.file.as_ref().map(|f| f.kind.as_str()) != Some("binary") {
                return Err(format!("put figure: {}", put_png.message));
            }
            let tree = w.svc.project_tree(id.clone()).await;
            let paths: Vec<&str> = tree.files.iter().map(|f| f.path.as_str()).collect();
            if paths != ["chapters/intro.typ", "figures/f.png"] {
                return Err(format!("tree lists {paths:?}"));
            }
            let read = w.svc.project_file(id.clone(), "chapters/intro.typ".into()).await;
            if read.text.as_deref() != Some("== Intro\nHello.") {
                return Err(format!("file read: {}", read.message));
            }
            let moved = w
                .svc
                .project_move_file(id.clone(), "figures/f.png".into(), "img/f.png".into(), None)
                .await;
            if !moved.ok {
                return Err(format!("move: {}", moved.message));
            }
            let del = w.svc.project_delete_file(id.clone(), "img/f.png".into()).await;
            if !del.ok || del.affected_count != 1 {
                return Err(format!("delete: {}", del.message));
            }
            let after = w.svc.project_tree(id).await;
            if after.files.len() != 1 || after.project_version != 1 {
                return Err(format!("after delete: {} file(s), version {}", after.files.len(), after.project_version));
            }
            Ok("chapter + figure round-tripped; move and delete honoured".into())
        },
    )
    .await
}

/// ADR-0030 D4: the build graph is derived from the source. A resolvable
/// include is an edge with a line; a missing one is an error diagnostic
/// naming the file and line; a figure step with no built output is stale.
async fn cap_project_graph_diagnostics() -> CapabilityResult {
    check(
        "project.graph_diagnostics",
        "project-graph derives edges, an unresolved include with file+line, cite keys and a stale figure step",
        Tier::A,
        || async {
            use imprint_service::ImprintProjectService;
            let w = ProjectWorld::open(
                "latex",
                "\\documentclass{article}\n\\input{chapters/intro}\n\\input{chapters/ghost}\n\\includegraphics{figures/plot.pdf}\n\\cite{knuth84}",
            )?;
            let id = w.manuscript_id.clone();
            for (path, text) in [
                ("chapters/intro.tex", "\\section{Intro} \\cite{smith20}"),
                ("figures/plot.py", "print(1)"),
            ] {
                let r = w
                    .svc
                    .project_put_file(id.clone(), path.into(), Some(text.into()), None, None, None)
                    .await;
                if !r.ok {
                    return Err(format!("put {path}: {}", r.message));
                }
            }
            let spec = w
                .svc
                .project_set_figure_build(
                    id.clone(),
                    "figures/plot.py".into(),
                    Some(r#"{"runner":"shell","outputs":["figures/plot.pdf"],"args":{"command":"python plot.py"}}"#.into()),
                )
                .await;
            if !spec.ok {
                return Err(format!("figure build: {}", spec.message));
            }
            let g = w.svc.project_graph(id, None).await;
            if !g.ok {
                return Err(format!("graph: {}", g.message));
            }
            if !g.edges.iter().any(|e| e.to == "chapters/intro.tex" && e.kind == "include" && e.line == 2) {
                return Err(format!("include edge missing: {:?}", g.edges));
            }
            let ghost = g
                .diagnostics
                .iter()
                .find(|d| d.code == "unresolved-include")
                .ok_or("no unresolved-include diagnostic")?;
            if ghost.file.as_deref() != Some("main.tex") || ghost.line != Some(3) {
                return Err(format!("unresolved include not located: {ghost:?}"));
            }
            if g.cite_keys != ["knuth84", "smith20"] {
                return Err(format!("cite keys: {:?}", g.cite_keys));
            }
            let step = g.steps.first().ok_or("no figure step")?;
            if !step.stale || step.missing_outputs != ["figures/plot.pdf"] {
                return Err(format!("step not reported stale: {step:?}"));
            }
            if !g.has_errors {
                return Err("graph should report errors".into());
            }
            Ok(format!(
                "{} edge(s), {} diagnostic(s), stale step {}",
                g.edges.len(),
                g.diagnostics.len(),
                step.source
            ))
        },
    )
    .await
}

/// F1 (driven by the ULDM guinea-pig manuscript): `@preview` package imports
/// must resolve offline from local typst package roots through the same
/// service compile surface the MCP tool uses. Skips when no root holds
/// lilaq 0.6.0 (populating the cache is the typst CLI's job, not ours).
async fn cap_compile_typst_preview_package() -> CapabilityResult {
    let id = "manuscript.compile_typst_preview_package";
    let desc = "compile_typst resolves @preview packages offline from local typst package roots";
    let in_root = |root: std::path::PathBuf| root.join("preview/lilaq/0.6.0").is_dir();
    let cached = std::env::var("IMPRESS_TYPST_PACKAGE_DIR")
        .ok()
        .map(|d| in_root(std::path::PathBuf::from(d)))
        .unwrap_or(false)
        || std::env::var("HOME")
            .ok()
            .map(|h| {
                let home = std::path::PathBuf::from(h);
                in_root(home.join("Library/Caches/typst/packages"))
                    || in_root(home.join(".cache/typst/packages"))
            })
            .unwrap_or(false);
    if !cached {
        return skipped(
            id,
            desc,
            Tier::A,
            "lilaq 0.6.0 not present in any local typst package root",
        );
    }
    check(id, desc, Tier::A, || async {
        let svc = TempService::open()?;
        let src =
            "#import \"@preview/lilaq:0.6.0\" as lq\n#lq.diagram(lq.plot((0, 1, 2), (0, 1, 4)))\n";
        let r = svc
            .manuscript
            .compile_typst(
                src.to_string(),
                imprint_service::handlers::CompileOptions::default(),
            )
            .await;
        if let Some(err) = r.error {
            if err.contains("not enabled") || err.contains("typst-render") {
                return Ok(format!("typst engine not enabled in this build: {err}"));
            }
            return Err(format!("compile error: {err}"));
        }
        let path = r.pdf_path.ok_or("no pdf_path from headless compile")?;
        let len = std::fs::metadata(&path).map_err(|e| e.to_string())?.len();
        if len < 500 {
            return Err(format!("suspiciously small PDF: {len} bytes"));
        }
        Ok(format!("lilaq @preview compiled to a {len}-byte PDF"))
    })
    .await
}

// ---------------------------------------------------------------------------
// Manuscript format capabilities (WS2: markdown / plain text first-class)
// ---------------------------------------------------------------------------

/// The suite-wide manuscript format contract: the allowed set lives in
/// impress-core (single source of truth) and a markdown body round-trips
/// through the shared item store unchanged.
async fn cap_manuscript_formats() -> CapabilityResult {
    check(
        "store.manuscript_formats",
        "SUPPORTED_MANUSCRIPT_FORMATS covers typst/latex/markdown/plaintext and a markdown body round-trips",
        Tier::A,
        || async {
            let formats = impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS;
            let expected = ["typst", "latex", "markdown", "plaintext"];
            if formats != expected {
                return Err(format!("format set drifted: {formats:?} != {expected:?}"));
            }
            for f in formats {
                if !impress_core::manuscript_ops::is_supported_manuscript_format(f) {
                    return Err(format!("is_supported_manuscript_format rejects '{f}'"));
                }
            }

            let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
            let path = dir.path().join("impress.sqlite").to_string_lossy().to_string();
            let store = impress_store_ffi::SharedStore::open(path).map_err(|e| e.to_string())?;
            let id = uuid::Uuid::new_v4().to_string();
            let body = "# Decision\n\nUse *one* store.";
            let payload = serde_json::json!({
                "title": "ARD",
                "status": "draft",
                "current_revision_ref": id,
                "format": "markdown",
                "body_content": body,
            })
            .to_string();
            store
                .upsert_item(id.clone(), "manuscript".into(), payload)
                .map_err(|e| e.to_string())?;
            let row = store
                .get_item(id)
                .map_err(|e| e.to_string())?
                .ok_or("manuscript not found after upsert")?;
            let decoded: serde_json::Value =
                serde_json::from_str(&row.payload_json).map_err(|e| e.to_string())?;
            if decoded["format"] != "markdown" || decoded["body_content"] != body {
                return Err(format!("round-trip mangled payload: {decoded}"));
            }
            Ok("format set stable; markdown body round-trips via SharedStore".to_string())
        },
    )
    .await
}

/// ADR-0027: two editors that loaded the same manuscript commit from the same
/// stale base; under the old compare-and-set one of them lost. Through the
/// SharedStore verbs (the exact FFI imprint's adapter calls) both edits must
/// land, the second committer must receive the MERGED body, and the row's
/// materialized `body_content` must equal it — plus the never-touched
/// manuscript's genesis must be deterministic across two store handles.
async fn cap_manuscript_collab_convergence() -> CapabilityResult {
    check(
        "manuscripts.collab_convergence",
        "concurrent commits from one stale base both land and merge (Automerge, ADR-0027)",
        Tier::A,
        || async {
            let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
            let path = dir
                .path()
                .join("impress.sqlite")
                .to_string_lossy()
                .to_string();
            let store =
                impress_store_ffi::SharedStore::open(path.clone()).map_err(|e| e.to_string())?;
            let id = uuid::Uuid::new_v4().to_string();
            let body = "The quick brown fox.";
            let payload = serde_json::json!({
                "title": "Collab",
                "status": "draft",
                "current_revision_ref": id,
                "format": "typst",
                "body_content": body,
            })
            .to_string();
            store
                .upsert_item(id.clone(), "manuscript".into(), payload)
                .map_err(|e| e.to_string())?;

            // Two editors load the same base.
            let base = store
                .manuscript_collab_heads(id.clone())
                .map_err(|e| e.to_string())?;
            if base.is_empty() {
                return Err("genesis produced no heads".into());
            }
            let a = store
                .commit_manuscript_body(
                    id.clone(),
                    base.clone(),
                    "Note: The quick brown fox.".into(),
                    "editor:a".into(),
                )
                .map_err(|e| e.to_string())?;
            if a.merged_external {
                return Err("first committer must not see external edits".into());
            }
            let b = store
                .commit_manuscript_body(
                    id.clone(),
                    base,
                    "The quick brown fox. Jumps.".into(),
                    "editor:b".into(),
                )
                .map_err(|e| e.to_string())?;
            let want = "Note: The quick brown fox. Jumps.";
            if !b.merged_external || b.body != want {
                return Err(format!("stale-base commit did not merge: got {:?}", b.body));
            }
            let row = store.get_item(id.clone()).map_err(|e| e.to_string())?;
            let materialized = row
                .and_then(|item| {
                    serde_json::from_str::<serde_json::Value>(&item.payload_json)
                        .ok()
                        .and_then(|v| v["body_content"].as_str().map(str::to_string))
                })
                .unwrap_or_default();
            if materialized != want {
                return Err(format!(
                    "materialized body_content drifted: {materialized:?}"
                ));
            }

            // Genesis determinism: a second handle over a fresh copy of the
            // manuscript row (no chunks) must mint the same first change.
            let dir2 = tempfile::tempdir().map_err(|e| e.to_string())?;
            let path2 = dir2
                .path()
                .join("impress.sqlite")
                .to_string_lossy()
                .to_string();
            let store2 = impress_store_ffi::SharedStore::open(path2).map_err(|e| e.to_string())?;
            let id2 = uuid::Uuid::new_v4().to_string();
            for s in [&store, &store2] {
                s.upsert_item(
                    id2.clone(),
                    "manuscript".into(),
                    serde_json::json!({"title": "G", "status": "draft", "format": "typst",
                        "current_revision_ref": id2, "body_content": "same seed"})
                    .to_string(),
                )
                .map_err(|e| e.to_string())?;
            }
            let g1 = store
                .manuscript_collab_heads(id2.clone())
                .map_err(|e| e.to_string())?;
            let g2 = store2
                .manuscript_collab_heads(id2)
                .map_err(|e| e.to_string())?;
            if g1 != g2 {
                return Err(format!(
                    "genesis heads differ across replicas: {g1:?} vs {g2:?}"
                ));
            }
            Ok(format!("merged both edits; genesis {}", &g1[0][..8]))
        },
    )
    .await
}

/// The status-lifecycle convention (docs/status-lifecycle.md): `dismissed`
/// hides an item from every working scope and is reversible; `archived` is a
/// distinct end-state. Verified through the same flat query surface the GUIs
/// use (`query_items` payload_eq on status).
async fn cap_status_lifecycle() -> CapabilityResult {
    check(
        "store.status_lifecycle",
        "dismissed items leave working scopes, restore returns them, archived is distinct",
        Tier::A,
        || async {
            let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
            let path = dir
                .path()
                .join("impress.sqlite")
                .to_string_lossy()
                .to_string();
            let store = impress_store_ffi::SharedStore::open(path).map_err(|e| e.to_string())?;

            let id = uuid::Uuid::new_v4().to_string();
            let payload = serde_json::json!({
                "title": "Lifecycle probe",
                "status": "draft",
                "current_revision_ref": id,
                "format": "markdown",
                "body_content": "x",
            })
            .to_string();
            store
                .upsert_item(id.clone(), "manuscript".into(), payload)
                .map_err(|e| e.to_string())?;

            let count_status = |status: &str| -> Result<u32, String> {
                store
                    .count_items(impress_store_ffi::SharedItemQuery {
                        schema_ref: Some("manuscript".into()),
                        parent_id: None,
                        payload_eq: vec![impress_store_ffi::SharedFieldEq {
                            field: "status".into(),
                            value_json: format!("\"{status}\""),
                        }],
                        modified_after_ms: None,
                        sort_field: String::new(),
                        ascending: false,
                        limit: 0,
                        offset: 0,
                    })
                    .map_err(|e| e.to_string())
            };
            let set_status = |status: &str| -> Result<(), String> {
                store
                    .upsert_item(
                        id.clone(),
                        "manuscript".into(),
                        format!(r#"{{"status": "{status}"}}"#),
                    )
                    .map_err(|e| e.to_string())
            };

            if count_status("draft")? != 1 {
                return Err("probe not visible as draft".into());
            }
            set_status("dismissed")?;
            if count_status("draft")? != 0 || count_status("dismissed")? != 1 {
                return Err("dismiss did not move the item out of the working scope".into());
            }
            set_status("draft")?;
            if count_status("draft")? != 1 || count_status("dismissed")? != 0 {
                return Err("restore did not return the item".into());
            }
            set_status("archived")?;
            if count_status("archived")? != 1 || count_status("dismissed")? != 0 {
                return Err("archived must be distinct from dismissed".into());
            }
            Ok("dismiss/restore/archive transitions scope correctly".into())
        },
    )
    .await
}

// ---------------------------------------------------------------------------
// Throughline capabilities (ADR-0016)
// ---------------------------------------------------------------------------

async fn cap_throughline_create() -> CapabilityResult {
    check(
        "throughline.create",
        "Throughline creation is an explicit opt-in; non-opted documents stay empty",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc = uuid::Uuid::new_v4().to_string();
            let other = uuid::Uuid::new_v4().to_string();

            // Opt-in invariant: nothing before creation.
            if svc.throughline.get_throughline(doc.clone()).await.is_some() {
                return Err("throughline existed before creation".into());
            }
            if !svc
                .throughline
                .get_anchor_states(doc.clone())
                .await
                .is_empty()
            {
                return Err("anchor states nonempty before creation".into());
            }
            let cov = svc.throughline.get_coverage(doc.clone()).await;
            if cov.has_throughline {
                return Err("coverage claimed a throughline before creation".into());
            }

            let info = svc
                .throughline
                .create_throughline(doc.clone(), "Self-test story".into())
                .await
                .ok_or("create_throughline returned None")?;
            if info.paragraph_count != 1 {
                return Err(format!(
                    "scaffold paragraph_count = {}",
                    info.paragraph_count
                ));
            }
            // Second create must fail (activation is deliberate).
            if svc
                .throughline
                .create_throughline(doc.clone(), "Again".into())
                .await
                .is_some()
            {
                return Err("second create_throughline unexpectedly succeeded".into());
            }
            // Scaffold starts synced.
            let states = svc.throughline.get_anchor_states(doc.clone()).await;
            if states.len() != 1 || states[0].state != "synced" {
                return Err(format!("scaffold states: {states:?}"));
            }
            // Untouched sibling document remains empty.
            if svc
                .throughline
                .get_throughline(other.clone())
                .await
                .is_some()
            {
                return Err("non-opted document grew a throughline".into());
            }
            Ok("create + opt-in invariant hold".to_string())
        },
    )
    .await
}

async fn cap_throughline_anchor_states() -> CapabilityResult {
    check(
        "throughline.anchor_states",
        "Anchored section edits derive manuscript-ahead; narrative edits derive throughline-ahead",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc = uuid::Uuid::new_v4().to_string();
            svc.manuscript
                .put_section(
                    doc.clone(),
                    "introduction".into(),
                    "We measure X.".into(),
                    SectionMetadata::default(),
                )
                .await
                .ok_or("put_section failed")?;
            svc.throughline
                .create_throughline(doc.clone(), "Story".into())
                .await
                .ok_or("create failed")?;
            svc.throughline
                .set_anchor(
                    doc.clone(),
                    "tl-overview".into(),
                    vec!["introduction".into()],
                )
                .await
                .ok_or("set_anchor failed")?;

            let states = svc.throughline.get_anchor_states(doc.clone()).await;
            if states[0].state != "synced" {
                return Err(format!(
                    "expected synced after baseline, got {}",
                    states[0].state
                ));
            }

            // Manuscript drifts.
            svc.manuscript
                .put_section(
                    doc.clone(),
                    "introduction".into(),
                    "We measure X and Y.".into(),
                    SectionMetadata::default(),
                )
                .await
                .ok_or("re-put_section failed")?;
            let states = svc.throughline.get_anchor_states(doc.clone()).await;
            if states[0].state != "manuscript-ahead" {
                return Err(format!(
                    "expected manuscript-ahead, got {}",
                    states[0].state
                ));
            }

            // Narrative edit on top → both directions stale.
            svc.throughline
                .update_throughline_source(doc.clone(), "A bolder claim. <tl-overview>\n".into())
                .await
                .ok_or("update_source failed")?;
            let states = svc.throughline.get_anchor_states(doc.clone()).await;
            if states[0].state != "manuscript-ahead+throughline-ahead" {
                return Err(format!("expected both-ahead, got {}", states[0].state));
            }
            Ok("staleness derivation matches ADR-0016 D5".to_string())
        },
    )
    .await
}

async fn cap_throughline_coverage() -> CapabilityResult {
    check(
        "throughline.coverage",
        "Unanchored sections are reported; mark_supporting suppresses them",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc = uuid::Uuid::new_v4().to_string();
            for key in ["introduction", "appendix"] {
                svc.manuscript
                    .put_section(
                        doc.clone(),
                        key.into(),
                        "body".into(),
                        SectionMetadata::default(),
                    )
                    .await
                    .ok_or("put_section failed")?;
            }
            svc.throughline
                .create_throughline(doc.clone(), "Story".into())
                .await
                .ok_or("create failed")?;
            svc.throughline
                .set_anchor(
                    doc.clone(),
                    "tl-overview".into(),
                    vec!["introduction".into()],
                )
                .await
                .ok_or("set_anchor failed")?;

            let cov = svc.throughline.get_coverage(doc.clone()).await;
            if cov.uncovered_section_keys != vec!["appendix".to_string()] {
                return Err(format!("coverage: {:?}", cov.uncovered_section_keys));
            }
            svc.throughline
                .mark_supporting(doc.clone(), "appendix".into(), true)
                .await
                .ok_or("mark_supporting failed")?;
            let cov = svc.throughline.get_coverage(doc.clone()).await;
            if !cov.uncovered_section_keys.is_empty() {
                return Err(format!(
                    "supporting not suppressed: {:?}",
                    cov.uncovered_section_keys
                ));
            }
            Ok("coverage + supporting suppression hold".to_string())
        },
    )
    .await
}

async fn cap_throughline_broken_anchor() -> CapabilityResult {
    check(
        "throughline.broken_anchor",
        "Removing an anchored section derives the broken state (rename policy, ADR-0016 D4)",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc = uuid::Uuid::new_v4().to_string();
            svc.manuscript
                .put_section(
                    doc.clone(),
                    "results".into(),
                    "body".into(),
                    SectionMetadata::default(),
                )
                .await
                .ok_or("put_section failed")?;
            svc.throughline
                .create_throughline(doc.clone(), "Story".into())
                .await
                .ok_or("create failed")?;
            svc.throughline
                .set_anchor(doc.clone(), "tl-overview".into(), vec!["results".into()])
                .await
                .ok_or("set_anchor failed")?;
            // Simulate a heading rename/removal: the old key disappears.
            if !svc
                .manuscript
                .delete_section(doc.clone(), "results".into())
                .await
            {
                return Err("delete_section failed".into());
            }
            let states = svc.throughline.get_anchor_states(doc.clone()).await;
            if states[0].state != "broken" || states[0].broken != vec!["results".to_string()] {
                return Err(format!("expected broken on 'results', got {states:?}"));
            }
            Ok("broken-anchor derivation holds".to_string())
        },
    )
    .await
}

async fn cap_compile_latex() -> CapabilityResult {
    check(
        "manuscript.compile_latex",
        "LaTeX compiles to a PDF via Tectonic (or reports 'not enabled' when the feature is off)",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let src = r"\documentclass{article}\begin{document}Hello from Tectonic self-test.\end{document}";
            let r = svc.manuscript.compile_latex(src.to_string(), String::new()).await;
            // Feature off (default build): contract is the structured
            // "requires tectonic-render" message from the dispatch shim.
            if let Some(err) = &r.error {
                if err.contains("tectonic-render") {
                    return Ok("tectonic-render off — reported the not-enabled contract".to_string());
                }
                return Err(format!("compile error: {err}"));
            }
            if r.pdf_len > 100 {
                Ok(format!("compiled {} byte PDF in {}ms", r.pdf_len, r.compile_ms))
            } else {
                Err(format!("PDF too small: {} bytes", r.pdf_len))
            }
        },
    )
    .await
}

async fn cap_format_latex() -> CapabilityResult {
    check(
        "text.format_latex",
        "LaTeX formatter indents environment bodies and is idempotent",
        Tier::A,
        || async {
            let svc = DefaultImprintTextService;
            let src = "\\begin{document}\nhi\n\\end{document}\n";
            let once = svc.format_latex(src.to_string()).await;
            let twice = svc.format_latex(once.clone()).await;
            if !once.contains("  hi") {
                return Err(format!("expected indented body, got: {once:?}"));
            }
            if once != twice {
                return Err("formatter is not idempotent".to_string());
            }
            Ok("indented body; idempotent on second pass".to_string())
        },
    )
    .await
}

async fn cap_extract_cite_keys_typst() -> CapabilityResult {
    check(
        "text.extract_cite_keys.typst",
        "Cite-key extraction finds @keys in Typst source",
        Tier::A,
        || async {
            let svc = DefaultImprintTextService;
            let src = "See @einstein1905 and @bohr1913 for details.";
            let keys = svc
                .extract_cite_keys(src.to_string(), "typst".to_string())
                .await;
            if keys.contains(&"einstein1905".to_string()) && keys.contains(&"bohr1913".to_string())
            {
                Ok(format!("found {} keys: {:?}", keys.len(), keys))
            } else {
                Err(format!("missing expected keys, got: {keys:?}"))
            }
        },
    )
    .await
}

async fn cap_extract_cite_keys_latex() -> CapabilityResult {
    check(
        "text.extract_cite_keys.latex",
        "Cite-key extraction finds \\cite{} keys in LaTeX source",
        Tier::A,
        || async {
            let svc = DefaultImprintTextService;
            let src = "As shown in \\cite{knuth1984} and \\citep{lamport1994}.";
            let keys = svc
                .extract_cite_keys(src.to_string(), "latex".to_string())
                .await;
            if keys.contains(&"knuth1984".to_string()) && keys.contains(&"lamport1994".to_string())
            {
                Ok(format!("found {} keys: {:?}", keys.len(), keys))
            } else {
                Err(format!("missing expected keys, got: {keys:?}"))
            }
        },
    )
    .await
}

async fn cap_compose_citation() -> CapabilityResult {
    check(
        "text.compose_citation",
        "Citation composition matches Typst/LaTeX conventions (round-trips with extraction)",
        Tier::A,
        || async {
            let svc = DefaultImprintTextService;
            let typst = svc
                .compose_citation("einstein1905".into(), "typst".into(), false)
                .await;
            let latex = svc
                .compose_citation("knuth1984".into(), "latex".into(), true)
                .await;
            if typst != "@einstein1905" {
                return Err(format!("typst citation wrong: {typst:?}"));
            }
            if latex != " \\cite{knuth1984}" {
                return Err(format!("latex citation wrong: {latex:?}"));
            }
            // Round-trip: a composed citation extracts back to the same key.
            let keys = svc.extract_cite_keys(typst.clone(), "typst".into()).await;
            if keys != ["einstein1905"] {
                return Err(format!("composed citation didn't round-trip: {keys:?}"));
            }
            Ok("typst @key, latex \\cite{}, round-trips with extractor".to_string())
        },
    )
    .await
}

async fn cap_compose_heading() -> CapabilityResult {
    check(
        "text.compose_heading",
        "Heading composition matches Typst levels and LaTeX section commands",
        Tier::A,
        || async {
            let svc = DefaultImprintTextService;
            let t1 = svc.compose_heading("Intro".into(), 1, "typst".into()).await;
            let t2 = svc
                .compose_heading("Background".into(), 2, "typst".into())
                .await;
            let l1 = svc
                .compose_heading("Methods".into(), 1, "latex".into())
                .await;
            if t1 != "= Intro" || t2 != "== Background" {
                return Err(format!("typst headings wrong: {t1:?} / {t2:?}"));
            }
            if l1 != "\\section{Methods}" {
                return Err(format!("latex heading wrong: {l1:?}"));
            }
            // A composed Typst heading is found by the outline extractor.
            let svc2 = TempService::open()?;
            let outline = svc2
                .manuscript
                .document_outline(format!("{t1}\n\nbody\n"))
                .await;
            if outline.entries.first().map(|e| e.title.as_str()) != Some("Intro") {
                return Err("composed heading not seen by outline extractor".to_string());
            }
            Ok("typst =levels, latex \\section, extractor sees composed heading".to_string())
        },
    )
    .await
}

async fn cap_document_outline() -> CapabilityResult {
    check(
        "manuscript.document_outline",
        "Outline extractor finds Typst headings with correct levels",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let src = "= Introduction\n\nText.\n\n== Background\n\nMore.\n\n= Methods\n";
            let outline = svc.manuscript.document_outline(src.to_string()).await;
            let titles: Vec<&str> = outline.entries.iter().map(|e| e.title.as_str()).collect();
            if titles != ["Introduction", "Background", "Methods"] {
                return Err(format!("unexpected headings: {titles:?}"));
            }
            let bg = outline
                .entries
                .iter()
                .find(|e| e.title == "Background")
                .ok_or("Background heading missing")?;
            if bg.level != 2 {
                return Err(format!("expected Background at level 2, got {}", bg.level));
            }
            Ok(format!(
                "{} headings, levels correct",
                outline.entries.len()
            ))
        },
    )
    .await
}

async fn cap_document_citations() -> CapabilityResult {
    check(
        "manuscript.document_citations",
        "Citation extractor reports @key usages with positions",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let src = "Intro @foo2020 then @bar2021 later.";
            let usages = svc.manuscript.document_citations(src.to_string()).await;
            let keys: Vec<&str> = usages.iter().map(|u| u.cite_key.as_str()).collect();
            if !keys.contains(&"foo2020") || !keys.contains(&"bar2021") {
                return Err(format!("missing usages, got: {keys:?}"));
            }
            // Positions should be strictly increasing in source order.
            if usages.len() >= 2 && usages[1].position <= usages[0].position {
                return Err("citation positions not in source order".to_string());
            }
            Ok(format!("{} usages in source order", usages.len()))
        },
    )
    .await
}

async fn cap_search_in_text() -> CapabilityResult {
    check(
        "manuscript.search_in_text",
        "In-text search returns matches with positions; case-sensitivity honored",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let src = "The quick Fox jumped. The fox slept.";
            let ci = svc
                .manuscript
                .search_in_text(src.to_string(), "fox".to_string(), false)
                .await;
            let cs = svc
                .manuscript
                .search_in_text(src.to_string(), "fox".to_string(), true)
                .await;
            if ci.len() != 2 {
                return Err(format!(
                    "case-insensitive expected 2 matches, got {}",
                    ci.len()
                ));
            }
            if cs.len() != 1 {
                return Err(format!("case-sensitive expected 1 match, got {}", cs.len()));
            }
            Ok("2 case-insensitive, 1 case-sensitive".to_string())
        },
    )
    .await
}

async fn cap_section_roundtrip() -> CapabilityResult {
    check(
        "manuscript.section_roundtrip",
        "A section survives put → get → list → delete against the store",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc_id = uuid::Uuid::new_v4().to_string();
            let key = "intro";
            let body = "= Introduction\n\nHello world, this is the intro.";
            let meta = SectionMetadata {
                title: Some("Introduction".to_string()),
                section_type: Some("introduction".to_string()),
                order_index: Some(0),
            };
            let put = svc
                .manuscript
                .put_section(doc_id.clone(), key.to_string(), body.to_string(), meta)
                .await
                .ok_or("put_section returned None")?;
            if put.body != body {
                return Err("stored body differs from input".to_string());
            }
            let got = svc
                .manuscript
                .get_section(doc_id.clone(), key.to_string())
                .await
                .ok_or("get_section returned None")?;
            if got.body != body {
                return Err("fetched body differs from input".to_string());
            }
            let listed = svc.manuscript.list_sections(doc_id.clone()).await;
            if listed.len() != 1 {
                return Err(format!("expected 1 section, listed {}", listed.len()));
            }
            let deleted = svc
                .manuscript
                .delete_section(doc_id.clone(), key.to_string())
                .await;
            if !deleted {
                return Err("delete_section returned false".to_string());
            }
            let after = svc.manuscript.list_sections(doc_id).await;
            if !after.is_empty() {
                return Err(format!("expected empty after delete, got {}", after.len()));
            }
            Ok(format!(
                "word_count={}, full CRUD cycle clean",
                got.word_count
            ))
        },
    )
    .await
}

async fn cap_replace_in_section() -> CapabilityResult {
    check(
        "manuscript.replace_in_section",
        "Search-and-replace within a stored section updates the body",
        Tier::A,
        || async {
            let svc = TempService::open()?;
            let doc_id = uuid::Uuid::new_v4().to_string();
            let key = "body";
            let body = "colour of the colour wheel";
            let meta = SectionMetadata {
                title: None,
                section_type: None,
                order_index: Some(0),
            };
            svc.manuscript
                .put_section(doc_id.clone(), key.to_string(), body.to_string(), meta)
                .await
                .ok_or("put_section returned None")?;
            let result = svc
                .manuscript
                .replace_in_section(
                    doc_id.clone(),
                    key.to_string(),
                    "colour".to_string(),
                    "color".to_string(),
                )
                .await;
            if result.replacements != 2 {
                return Err(format!(
                    "expected 2 replacements, got {}",
                    result.replacements
                ));
            }
            if result.new_body.contains("colour") {
                return Err("old spelling still present after replace".to_string());
            }
            Ok(format!("{} replacements applied", result.replacements))
        },
    )
    .await
}

/// ADR-0030 P3: a directory becomes a project, the tree comes back out as a
/// directory (idempotently) and as a revision archive in the workspace CAS.
async fn cap_project_import_export_snapshot() -> CapabilityResult {
    check(
        "project.import_export_snapshot",
        "project-import-directory reads a LaTeX directory into a new manuscript; project-materialize is idempotent; project-snapshot packs the tree into a CAS-backed revision",
        Tier::A,
        || async {
            use imprint_service::ImprintProjectService;
            let w = ProjectWorld::open("typst", "= Placeholder")?;
            let io = |e: std::io::Error| e.to_string();
            let src = w._dir.path().join("source");
            std::fs::create_dir_all(src.join("chapters")).map_err(io)?;
            std::fs::write(
                src.join("main.tex"),
                "\\documentclass{article}\n\\begin{document}\n\\input{chapters/intro}\n\\end{document}\n",
            )
            .map_err(io)?;
            std::fs::write(src.join("chapters/intro.tex"), "\\section{Intro}\n").map_err(io)?;
            std::fs::write(src.join("main.log"), "residue").map_err(io)?;

            let imported = w
                .svc
                .project_import_directory(
                    src.display().to_string(),
                    None,
                    None,
                    Some("Selftest import".into()),
                    None,
                )
                .await;
            if !imported.ok || !imported.created {
                return Err(format!("import: {}", imported.message));
            }
            let paths: Vec<&str> = imported.files.iter().map(|f| f.path.as_str()).collect();
            if imported.entry_path != "main.tex" || paths != ["chapters/intro.tex"] {
                return Err(format!(
                    "import shape: entry {} files {paths:?}",
                    imported.entry_path
                ));
            }
            if !imported.skipped.iter().any(|s| s.starts_with("main.log")) {
                return Err(format!("build residue not skipped: {:?}", imported.skipped));
            }
            let id = imported.manuscript_id.clone();

            let build = w._dir.path().join("build");
            let first = w
                .svc
                .project_materialize(id.clone(), None, Some(build.display().to_string()))
                .await;
            if !first.ok || first.written.len() != 2 {
                return Err(format!("materialize: {} {:?}", first.message, first.written));
            }
            let second = w
                .svc
                .project_materialize(id.clone(), None, Some(build.display().to_string()))
                .await;
            if !second.ok || !second.written.is_empty() || second.unchanged.len() != 2 {
                return Err(format!(
                    "materialize is not idempotent: {} written {:?}",
                    second.message, second.written
                ));
            }

            let snap = w
                .svc
                .project_snapshot(id.clone(), "selftest".into(), None, None, None)
                .await;
            if !snap.ok || snap.file_count != 2 {
                return Err(format!("snapshot: {}", snap.message));
            }
            let digest = impress_core::blobs::parse_blob_ref(&snap.archive_ref)
                .ok_or("archive ref is not a blob ref")?;
            let blobs = impress_core::blobs::BlobStore::for_workspace(w._dir.path());
            let archive = blobs
                .get(digest)
                .map_err(io)?
                .ok_or("archive missing from the CAS")?;
            let entries = imprint_core::project::unpack(&archive).map_err(|e| e.to_string())?;
            let names: Vec<&str> = entries.iter().map(|(p, _)| p.as_str()).collect();
            if names != ["manifest.json", "chapters/intro.tex", "main.tex"] {
                return Err(format!("archive entries: {names:?}"));
            }
            Ok(format!(
                "imported {} file(s); materialised {} then 0; snapshot {} bytes as revision {}",
                imported.files.len() + 1,
                first.written.len(),
                snap.archive_bytes,
                snap.revision_id
            ))
        },
    )
    .await
}

/// ADR-0030 P4: a build is a record. A figure source with a shell step and
/// a target without a document engine: the step is skipped unless shell
/// steps are allowed, runs when they are, its output becomes a row derived
/// from the source, and the builds are listed newest first.
async fn cap_project_build_records() -> CapabilityResult {
    check(
        "project.build_records",
        "project-build runs stale shell steps only when allowed, records manuscript-build rows and derives the produced output row from its source",
        Tier::A,
        || async {
            use imprint_service::ImprintProjectService;
            let w = ProjectWorld::open("typst", "= Paper\n#image(\"figures/plot.png\")")?;
            let id = w.manuscript_id.clone();
            let put = w
                .svc
                .project_put_file(
                    id.clone(),
                    "figures/make.sh".into(),
                    Some("printf PNG > figures/plot.png".into()),
                    None,
                    Some("figure-source".into()),
                    None,
                )
                .await;
            if !put.ok {
                return Err(format!("put: {}", put.message));
            }
            let spec = w
                .svc
                .project_set_figure_build(
                    id.clone(),
                    "figures/make.sh".into(),
                    Some(r#"{"runner":"shell","outputs":["figures/plot.png"],"args":{"command":"sh figures/make.sh"}}"#.into()),
                )
                .await;
            if !spec.ok {
                return Err(format!("figure build: {}", spec.message));
            }
            let targets = w
                .svc
                .project_set_targets(id.clone(), Some(r#"[{"id":"figures","engine":"none"}]"#.into()), None)
                .await;
            if !targets.ok {
                return Err(format!("targets: {}", targets.message));
            }
            let quiet = w.svc.project_build(id.clone(), None, None, None, None).await;
            let quiet_build = quiet.build.as_ref().ok_or("no build record")?;
            if !quiet.ok || quiet_build.steps.first().map(|s| s.status.as_str()) != Some("skipped") {
                return Err(format!("shell step should be skipped by default: {}", quiet.message));
            }
            let built = w.svc.project_build(id.clone(), None, Some(true), None, None).await;
            let build = built.build.as_ref().ok_or("no build record")?;
            if !built.ok || build.steps.first().map(|s| s.status.as_str()) != Some("ran") {
                return Err(format!("shell step should run when allowed: {} / {}", built.message, built.log));
            }
            let tree = w.svc.project_tree(id.clone()).await;
            let plot = tree
                .files
                .iter()
                .find(|f| f.path == "figures/plot.png")
                .ok_or("produced output row missing")?;
            if plot.derived_from.as_deref() != Some("figures/make.sh") {
                return Err(format!("provenance missing: {:?}", plot.derived_from));
            }
            let builds = w.svc.project_builds(id, None, None).await;
            if builds.builds.len() != 2 || builds.builds[0].status != "ok" {
                return Err(format!("builds: {:?}", builds.builds.iter().map(|b| b.status.clone()).collect::<Vec<_>>()));
            }
            Ok(format!(
                "skipped then ran ({}); output row derived from {}; {} builds recorded",
                build.steps[0].message, plot.derived_from.clone().unwrap_or_default(), builds.builds.len()
            ))
        },
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn tier_a_all_pass() {
        let results = run().await;
        assert!(!results.is_empty(), "no Tier A capabilities ran");
        let failures: Vec<_> = results
            .iter()
            .filter(|r| !r.pass && !r.skipped)
            .map(|r| format!("{}: {}", r.id, r.detail))
            .collect();
        assert!(
            failures.is_empty(),
            "Tier A failures:\n{}",
            failures.join("\n")
        );
    }
}
