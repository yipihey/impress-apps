//! Owned imprint workspace fixtures for manuscript and throughline examples.
//! The default imprint handlers use a separate `IMPRINT_WORKSPACE_ROOT` SQLite
//! file, so this intentionally opens that sidecar under the harness root.
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use imprint_service::throughline::ThroughlineStore;
use imprint_service::{SectionMetadata, SectionStore};
use serde_json::Value;

const MANUSCRIPT: &str = "imprint-manuscript-service_";
const THROUGHLINE: &str = "imprint-throughline-service_";
const SECTION: &str = "intro";
const BODY: &str = "G3 section body";

fn suffix(verb: &str) -> Option<(&str, bool)> {
    verb.strip_prefix(MANUSCRIPT)
        .map(|v| (v, false))
        .or_else(|| verb.strip_prefix(THROUGHLINE).map(|v| (v, true)))
}
fn document_id(method: &str, throughline: bool) -> Result<ItemId, String> {
    let n: u8 = if throughline {
        match method {
            "create-throughline" => 18,
            "get-throughline" => 19,
            "update-throughline-source" => 20,
            "delete-throughline" => 21,
            "get-anchor-states" => 22,
            "get-coverage" => 23,
            "set-anchor" => 24,
            "remove-anchor" => 25,
            "mark-supporting" => 26,
            other => return Err(format!("unknown throughline fixture {other}")),
        }
    } else {
        match method {
            "list-documents" => 1,
            "get-document" => 2,
            "export-document" => 3,
            "list-sections" => 4,
            "get-section" => 5,
            "put-section" => 6,
            "delete-section" => 7,
            "search" => 16,
            "replace-in-section" => 17,
            other => return Err(format!("no document fixture for {other}")),
        }
    };
    format!("62000000-0000-4000-8000-0000000000{n:02x}")
        .parse()
        .map_err(|e| format!("fixture UUID: {e}"))
}
fn sections(root: &Path) -> Result<Arc<SectionStore>, String> {
    SectionStore::open(root.join("imprint"))
        .map(Arc::new)
        .map_err(|e| e.to_string())
}
fn seed_document(store: &SqliteItemStore, id: ItemId, title: &str) -> Result<(), String> {
    if store.get(id).map_err(|e| e.to_string())?.is_some() {
        return Ok(());
    }
    let now = std::time::SystemTime::now().into();
    let row = Item {
        id,
        schema: impress_core::schema::refs::MANUSCRIPT,
        payload: BTreeMap::from([
            ("title".into(), ItemValue::String(title.into())),
            ("format".into(), ItemValue::String("typst".into())),
            (
                "body_content".into(),
                ItemValue::String("= G3 manuscript".into()),
            ),
        ]),
        created: now,
        modified: now,
        author: "system:g3-manuscript-fixture".into(),
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
    };
    store.insert(row).map(|_| ()).map_err(|e| e.to_string())
}
fn needs_document(method: &str, throughline: bool) -> bool {
    throughline
        || matches!(
            method,
            "list-documents"
                | "get-document"
                | "export-document"
                | "list-sections"
                | "get-section"
                | "put-section"
                | "delete-section"
                | "search"
                | "replace-in-section"
        )
}

pub async fn prepare(
    verb: &str,
    example: &str,
    _store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    let Some((method, throughline)) = suffix(verb) else {
        return Ok(());
    };
    if !example.starts_with("g3-") {
        return Ok(());
    }
    std::fs::create_dir_all(root.join("manuscripts")).map_err(|e| e.to_string())?;
    if !needs_document(method, throughline) {
        return Ok(());
    }
    let doc = document_id(method, throughline)?;
    let sidecar = sections(root)?;
    seed_document(
        sidecar.shared_store(),
        doc,
        &format!("G3 {}", method.replace('-', " ")),
    )?;
    let manuscript = imprint_service::backend::manuscript_service_instance();
    let throughlines = imprint_service::backend::throughline_service_instance();
    if matches!(
        method,
        "list-sections" | "get-section" | "delete-section" | "replace-in-section" | "search"
    ) || (throughline
        && matches!(
            method,
            "get-anchor-states"
                | "get-coverage"
                | "set-anchor"
                | "remove-anchor"
                | "mark-supporting"
        ))
    {
        let body = match method {
            "replace-in-section" => "G3 before result",
            "search" => "A g3uniquesearchneedle supports this finding.",
            _ => BODY,
        };
        let got = manuscript
            .put_section(
                doc.to_string(),
                SECTION.into(),
                body.into(),
                SectionMetadata {
                    title: Some("Introduction".into()),
                    section_type: Some("introduction".into()),
                    order_index: Some(0),
                },
            )
            .await;
        if got.is_none() {
            return Err(format!("seed section for {method} refused"));
        }
    }
    if throughline && method != "create-throughline" {
        let got = throughlines
            .create_throughline(doc.to_string(), "G3 research story".into())
            .await;
        if got.is_none() {
            return Err(format!("seed throughline for {method} refused"));
        }
        if matches!(method, "get-anchor-states" | "remove-anchor") {
            let got = throughlines
                .set_anchor(doc.to_string(), "tl-overview".into(), vec![SECTION.into()])
                .await;
            if got.is_none() {
                return Err(format!("seed anchor for {method} refused"));
            }
        }
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    example: &str,
    _store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
    root: &Path,
) -> Result<(), String> {
    let Some((method, throughline)) = suffix(verb) else {
        return Ok(());
    };
    if !example.starts_with("g3-") {
        return Ok(());
    }
    let sidecar = sections(root)?;
    let doc = if needs_document(method, throughline) {
        let doc = document_id(method, throughline)?;
        if sidecar
            .shared_store()
            .get(doc)
            .map_err(|e| e.to_string())?
            .is_none()
        {
            return Err(format!("owned manuscript missing after {method}"));
        }
        Some(doc)
    } else {
        None
    };
    let section = |doc: ItemId| sidecar.get_section(doc, SECTION).map_err(|e| e.to_string());
    let fail = |why: &str| Err(format!("{verb} / {example}: {why}; result={result}"));
    match method {
        "list-documents"
            if !result
                .as_array()
                .is_some_and(|rows| rows.iter().any(|v| v["id"] == doc.unwrap().to_string())) =>
        {
            fail("seeded manuscript absent from listing")
        }
        "get-document" if result["id"] != doc.unwrap().to_string() => fail("document id mismatch"),
        "export-document"
            if result["ok"] != false
                || !result["message"]
                    .as_str()
                    .is_some_and(|s| s.contains("native imprint host")) =>
        {
            fail("headless export did not explicitly refuse native-only work")
        }
        "list-sections"
            if !result
                .as_array()
                .is_some_and(|rows| rows.iter().any(|v| v["section_key"] == SECTION)) =>
        {
            fail("section listing omitted seeded section")
        }
        "get-section" if result["body"] != BODY => fail("section body mismatch"),
        "put-section"
            if sidecar
                .get_section(
                    doc.unwrap(),
                    args["section_key"].as_str().unwrap_or_default(),
                )
                .map_err(|e| e.to_string())?
                .is_none_or(|s| s.body != args["body"].as_str().unwrap_or_default()) =>
        {
            fail("put section did not persist body")
        }
        "delete-section" if section(doc.unwrap())?.is_some() => fail("deleted section survived"),
        "document-outline" if result["entries"].as_array().is_none_or(Vec::is_empty) => {
            fail("outline omitted heading")
        }
        "document-citations"
            if !result
                .as_array()
                .is_some_and(|rows| rows.iter().any(|v| v["cite_key"] == "g3source")) =>
        {
            fail("citation key absent")
        }
        "search-in-text"
            if !result
                .as_array()
                .is_some_and(|rows| rows.iter().any(|v| v["text"] == "beta")) =>
        {
            fail("text search missed beta")
        }
        "presentation-outline"
            if !result["slides"].as_array().is_some_and(|rows| {
                rows.len() == 2 && rows[0]["id"] == "one" && rows[1]["id"] == "two"
            }) =>
        {
            fail("slide outline missed stable IDs")
        }
        "reorder-presentation-slide"
            if result["error"] != Value::Null
                || !result["source"]
                    .as_str()
                    .is_some_and(|s| s.starts_with("#slide(id: \"two\")")) =>
        {
            fail("slide order not changed")
        }
        "set-presentation-slide-beat"
            if result["error"] != Value::Null
                || !result["source"]
                    .as_str()
                    .is_some_and(|s| s.contains("beat: \"tl-method\"")) =>
        {
            fail("beat not assigned")
        }
        "compile-typst"
            if result["error"] != Value::Null
                || result["pdf_path"]
                    .as_str()
                    .is_none_or(|p| !Path::new(p).is_file()) =>
        {
            fail("Typst compilation produced no owned PDF")
        }
        "compile-latex"
            if result["error"] != Value::Null
                || result["pdf_len"].as_u64().is_none_or(|n| n == 0) =>
        {
            fail("LaTeX compilation produced no PDF")
        }
        "search"
            if !result.as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|v| v["document_id"] == doc.unwrap().to_string())
            }) =>
        {
            fail("indexed section absent from search")
        }
        "replace-in-section"
            if section(doc.unwrap())?.is_none_or(|s| s.body != "G3 after result") =>
        {
            fail("replacement not persisted")
        }
        "create-throughline" | "get-throughline"
            if result["document_id"] != doc.unwrap().to_string() =>
        {
            fail("throughline for wrong document")
        }
        "update-throughline-source"
            if !result["source"]
                .as_str()
                .is_some_and(|s| s.contains("New evidence")) =>
        {
            fail("narrative update absent")
        }
        "delete-throughline"
            if ThroughlineStore::new(sidecar.clone())
                .get_throughline(doc.unwrap())
                .map_err(|e| e.to_string())?
                .is_some() =>
        {
            fail("deleted throughline survived")
        }
        "get-anchor-states"
            if !result.as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|v| v["label"] == "tl-overview" && v["state"] == "synced")
            }) =>
        {
            fail("anchored paragraph not synced")
        }
        "get-coverage"
            if result["has_throughline"] != true
                || !result["uncovered_section_keys"]
                    .as_array()
                    .is_some_and(|rows| rows.iter().any(|v| v == SECTION)) =>
        {
            fail("uncovered section not reported")
        }
        "set-anchor"
            if !result["anchor_map_json"]
                .as_str()
                .is_some_and(|s| s.contains(SECTION)) =>
        {
            fail("anchor ledger did not persist section")
        }
        "remove-anchor"
            if result["anchor_map_json"]
                .as_str()
                .is_none_or(|s| s.contains("\"tl-overview\"")) =>
        {
            fail("anchor removal invalidated narrative map")
        }
        "mark-supporting"
            if !result["anchor_map_json"]
                .as_str()
                .is_some_and(|s| s.contains(SECTION)) =>
        {
            fail("supporting section not recorded")
        }
        _ => Ok(()),
    }
}
