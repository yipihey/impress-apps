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

use crate::{check, CapabilityResult, Tier};

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
    out.push(cap_manuscript_formats().await);
    out.push(cap_status_lifecycle().await);
    out.push(cap_throughline_create().await);
    out.push(cap_throughline_anchor_states().await);
    out.push(cap_throughline_coverage().await);
    out.push(cap_throughline_broken_anchor().await);

    out
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
