//! Scratch manuscript projects for descriptor examples.
//!
//! Rows and paths belong to the harness's store/root. Every example gets a
//! distinct manuscript UUID, so inventory traversal cannot provide setup.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use impress_core::item::{ActorKind, Item, ItemId, Priority, Value as ItemValue, Visibility};
use impress_core::manuscript_project::{self as project, Author, BuildRecord};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use imprint_service::{DefaultImprintProjectService, ImprintProjectService};
use serde_json::Value;

const PREFIX: &str = "imprint-project-service_project-";
const PAPER_COLLECT: &str = "5e000000-0000-4000-8000-000000000082";
const PAPER_UNCOLLECT: &str = "5e000000-0000-4000-8000-000000000083";
const PAPER_SYNC: &str = "5e000000-0000-4000-8000-000000000084";
const PAPER_LIST: &str = "5e000000-0000-4000-8000-000000000085";
const LIBRARY: &str = "5e000000-0000-4000-8000-000000000081";
const CHAPTER: &str = "chapters/intro.typ";
const CHAPTER_TEXT: &str = "== Introduction\nG3 project evidence.";

fn method(verb: &str) -> Option<&str> {
    verb.strip_prefix(PREFIX)
}
fn manuscript_id(method: &str, example: &str) -> Result<ItemId, String> {
    let n: u8 = if example == "g3-compile-positive" {
        31
    } else {
        match method {
            "build" => 1,
            "build-output" => 2,
            "builds" => 3,
            "checkin" => 4,
            "checkout" => 5,
            "citations" => 6,
            "collect" => 7,
            "compile" => 8,
            "delete-file" => 9,
            "export" => 10,
            "figure-preview" => 11,
            "file" => 12,
            "graph" => 13,
            "import-directory" => 14,
            "materialize" => 15,
            "move-file" => 16,
            "new-figure" => 17,
            "outline" => 18,
            "put-file" => 19,
            "reading-list" => 20,
            "render-figure" => 21,
            "set-bibliography" => 22,
            "set-entry" => 23,
            "set-figure-build" => 24,
            "set-targets" => 25,
            "snapshot" => 26,
            "status" => 27,
            "sync-reading-collection" => 28,
            "tree" => 29,
            "uncollect" => 30,
            other => return Err(format!("unknown project fixture method {other}")),
        }
    };
    format!("5e000000-0000-4000-8000-0000000000{n:02x}")
        .parse()
        .map_err(|e| format!("fixture UUID: {e}"))
}
fn path(root: &Path, method: &str) -> PathBuf {
    root.join("projects").join(method)
}
fn item(id: ItemId, schema: &str, parent: Option<ItemId>) -> Result<Item, String> {
    let now = std::time::SystemTime::now().into();
    Ok(Item {
        id,
        schema: schema.parse().map_err(|e| format!("fixture schema: {e}"))?,
        payload: BTreeMap::new(),
        created: now,
        modified: now,
        author: "system:g3-project-fixture".into(),
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
        parent,
    })
}
fn cited_key(method: &str) -> &'static str {
    match method {
        "collect" => "g3collect",
        "reading-list" => "g3reading",
        "sync-reading-collection" => "g3sync",
        "uncollect" => "g3uncollect",
        _ => "g3paper",
    }
}
fn seed_manuscript(store: &SqliteItemStore, id: ItemId, method: &str) -> Result<(), String> {
    if store.get(id).map_err(|e| e.to_string())?.is_some() {
        return Ok(());
    }
    let body = if matches!(
        method,
        "citations" | "collect" | "reading-list" | "sync-reading-collection" | "uncollect"
    ) {
        format!(
            "= G3 project\nSee @{} and compare the result.",
            cited_key(method)
        )
    } else if matches!(method, "graph" | "outline") {
        "= G3 project\n#include \"chapters/intro.typ\"".to_string()
    } else {
        "= G3 project\nA valid isolated manuscript.".to_string()
    };
    let mut row = item(id, "manuscript", None)?;
    row.payload = BTreeMap::from([
        ("title".into(), ItemValue::String(format!("G3 {method}"))),
        ("format".into(), ItemValue::String("typst".into())),
        ("status".into(), ItemValue::String("draft".into())),
        (
            "current_revision_ref".into(),
            ItemValue::String(id.to_string()),
        ),
        ("body_content".into(), ItemValue::String(body.clone())),
        (
            "body_content_hash".into(),
            ItemValue::String(impress_core::manuscript_ops::sha256_hex(&body)),
        ),
    ]);
    store.insert(row).map(|_| ()).map_err(|e| e.to_string())
}
fn seed_paper(store: &SqliteItemStore, paper: &str, key: &str) -> Result<(), String> {
    let lib: ItemId = LIBRARY.parse().map_err(|e| format!("library UUID: {e}"))?;
    if store.get(lib).map_err(|e| e.to_string())?.is_none() {
        let mut row = item(lib, "imbib/library", None)?;
        row.payload.insert(
            "name".into(),
            ItemValue::String("G3 project library".into()),
        );
        store.insert(row).map_err(|e| e.to_string())?;
    }
    let id: ItemId = paper.parse().map_err(|e| format!("paper UUID: {e}"))?;
    if store.get(id).map_err(|e| e.to_string())?.is_none() {
        let mut row = item(id, "imbib/bibliography-entry", Some(lib))?;
        row.payload
            .insert("cite_key".into(), ItemValue::String(key.into()));
        row.payload
            .insert("title".into(), ItemValue::String("G3 cited paper".into()));
        store.insert(row).map_err(|e| e.to_string())?;
    }
    Ok(())
}
fn ok(flag: bool, message: String, step: &str) -> Result<(), String> {
    if flag {
        Ok(())
    } else {
        Err(format!("{step}: {message}"))
    }
}
fn seed_build(
    store: &SqliteItemStore,
    root: &Path,
    id: ItemId,
    method: &str,
) -> Result<(), String> {
    let dir = path(root, method);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let pdf = dir.join("output.pdf");
    let bytes = b"%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n";
    std::fs::write(&pdf, bytes).map_err(|e| e.to_string())?;
    let outputs = serde_json::json!([{"kind":"pdf","name":"output.pdf","path":pdf.display().to_string(),"blob_ref":null,"size":bytes.len()}]);
    let record = BuildRecord {
        target_id: "default".into(),
        engine: "typst".into(),
        status: "ok".into(),
        input_stamp: "g3-owned-build".into(),
        started_ms: 1,
        finished_ms: Some(2),
        duration_ms: Some(1),
        outputs_json: Some(outputs.to_string()),
        diagnostics_json: None,
        steps_json: None,
        allow_shell: false,
        message: Some("G3 recorded fixture build".into()),
    };
    project::record_build(store, id, &record, &Author::agent("g3-project-fixture"))
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn prepare(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    root: &Path,
) -> Result<(), String> {
    let Some(method) = method(verb) else {
        return Ok(());
    };
    if !example.starts_with("g3-") {
        return Ok(());
    }
    let dir = path(root, method);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if method == "import-directory" {
        let import_dir = root.join("projects/import");
        std::fs::create_dir_all(import_dir.join("chapters")).map_err(|e| e.to_string())?;
        std::fs::write(
            import_dir.join("main.typ"),
            "= G3 imported\n#include \"chapters/intro.typ\"",
        )
        .map_err(|e| e.to_string())?;
        std::fs::write(import_dir.join("chapters/intro.typ"), CHAPTER_TEXT)
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    let id = manuscript_id(method, example)?;
    seed_manuscript(store, id, method)?;
    let svc = DefaultImprintProjectService::new();
    let ms = id.to_string();
    match method {
        "build-output" | "builds" => seed_build(store, root, id, method)?,
        "delete-file" | "file" | "graph" | "move-file" | "outline" | "checkout" | "status"
        | "checkin" | "export" | "materialize" | "snapshot" | "tree" => {
            let put = svc
                .project_put_file(
                    ms.clone(),
                    CHAPTER.into(),
                    Some(CHAPTER_TEXT.into()),
                    None,
                    None,
                    None,
                )
                .await;
            ok(put.ok, put.message, "seed chapter")?;
        }
        _ => {}
    }
    match method {
        "collect" => seed_paper(store, PAPER_COLLECT, cited_key(method))?,
        "uncollect" => {
            seed_paper(store, PAPER_UNCOLLECT, cited_key(method))?;
            let got = svc
                .project_collect(ms.clone(), vec![PAPER_UNCOLLECT.into()], None)
                .await;
            ok(got.ok, got.message, "precollect paper")?;
        }
        "sync-reading-collection" => seed_paper(store, PAPER_SYNC, cited_key(method))?,
        "reading-list" => seed_paper(store, PAPER_LIST, cited_key(method))?,
        "set-bibliography" => {
            let put = svc
                .project_put_file(
                    ms.clone(),
                    "refs.bib".into(),
                    Some("@article{g3paper,title={G3}}".into()),
                    None,
                    None,
                    None,
                )
                .await;
            ok(put.ok, put.message, "seed bibliography")?;
        }
        "set-figure-build" | "figure-preview" | "render-figure" => {
            let made = svc
                .project_new_figure(
                    ms.clone(),
                    "figures/chart".into(),
                    "impress-plot".into(),
                    None,
                )
                .await;
            ok(made.ok, made.message, "seed figure")?;
        }
        "status" | "checkin" => {
            let wd = dir.clone(); // matches {{fixture.root}}/projects/<method>
            let checked = svc
                .project_checkout(ms.clone(), wd.display().to_string(), None)
                .await;
            ok(checked.ok, checked.message, "seed checkout")?;
            std::fs::write(
                wd.join("main.typ"),
                "= G3 project revised\nAn owned working copy.",
            )
            .map_err(|e| e.to_string())?;
        }
        _ => {}
    }
    Ok(())
}

pub fn verify(
    verb: &str,
    example: &str,
    store: &Arc<SqliteItemStore>,
    args: &Value,
    result: &Value,
) -> Result<(), String> {
    let Some(method) = method(verb) else {
        return Ok(());
    };
    if !example.starts_with("g3-") {
        return Ok(());
    }
    let positive = method != "compile" || example == "g3-compile-positive";
    if result["ok"].as_bool() != Some(positive) {
        return Err(format!("{verb} returned unexpected status: {result}"));
    }
    if method == "import-directory" {
        let id: ItemId = result["manuscript_id"]
            .as_str()
            .ok_or("import omitted manuscript ID")?
            .parse()
            .map_err(|e| format!("import ID: {e}"))?;
        if store.get(id).map_err(|e| e.to_string())?.is_none()
            || result["entry_path"] != "main.typ"
            || result["files"].as_array().is_none_or(Vec::is_empty)
        {
            return Err("directory import did not persist its entry and chapter".into());
        }
        return Ok(());
    }
    let id = manuscript_id(method, example)?;
    let row = store
        .get(id)
        .map_err(|e| e.to_string())?
        .ok_or("fixture manuscript vanished")?;
    if args["manuscript_id"] != id.to_string() {
        return Err("example escaped its owned manuscript".into());
    }
    match method {
        "build" if result["job"]["id"].as_str().is_none() => {
            return Err("build did not start a job".into())
        }
        "build-output" => {
            let path = result["path"].as_str().ok_or("build output had no path")?;
            if !path.starts_with("/")
                || !std::fs::read(path)
                    .map_err(|e| e.to_string())?
                    .starts_with(b"%PDF")
            {
                return Err("build output did not return owned PDF bytes".into());
            }
        }
        "builds" if result["builds"].as_array().is_none_or(Vec::is_empty) => {
            return Err("build list omitted recorded build".into())
        }
        "checkin"
            if row
                .payload
                .get("body_content")
                .is_none_or(|v| !format!("{v:?}").contains("revised")) =>
        {
            return Err("checkin did not persist revised entry".into())
        }
        "checkout"
            if result["entry"]
                .as_str()
                .is_none_or(|p| !Path::new(p).is_file()) =>
        {
            return Err("checkout wrote no entry file".into())
        }
        "citations"
            if !result["keys"]
                .as_array()
                .is_some_and(|keys| keys.iter().any(|v| v == "g3paper")) =>
        {
            return Err("citations omitted cited G3 paper".into())
        }
        "collect" | "uncollect" if !result["changed"].as_array().is_some_and(|v| v.len() == 1) => {
            return Err("reading collection membership did not change".into())
        }
        "compile" if example == "g3-compile-positive" => {
            if result["pdf_path"]
                .as_str()
                .is_none_or(|p| !Path::new(p).is_file())
            {
                return Err("positive Typst compile wrote no PDF".into());
            }
        }
        "compile"
            if result["engine"] != "typst"
                || result["message"].as_str().is_none_or(str::is_empty) =>
        {
            return Err("invalid Typst compile gave no meaningful refusal".into())
        }
        "delete-file" if result["affected_count"] != 1 => {
            return Err("file deletion did not affect one row".into())
        }
        "export" | "materialize"
            if result["entry"]
                .as_str()
                .is_none_or(|p| !Path::new(p).is_file()) =>
        {
            return Err("project export/materialization omitted entry".into())
        }
        "figure-preview"
            if result["svg"].as_str().is_none_or(|s| !s.contains("<svg"))
                || result["outputs"].as_array().is_none_or(|v| !v.is_empty()) =>
        {
            return Err("figure preview lacked SVG or wrote output rows".into())
        }
        "file" if result["text"].as_str() != Some(CHAPTER_TEXT) => {
            return Err("project file did not return seeded chapter".into())
        }
        "graph"
            if !result["edges"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|edge| edge["to"] == CHAPTER)) =>
        {
            return Err("project graph omitted the include edge".into())
        }
        "move-file" if result["file"]["path"] != "chapters/moved.typ" => {
            return Err("move-file did not rename the chapter".into())
        }
        "new-figure" if result["file"]["role"] != "figure-source" => {
            return Err("new figure did not persist a source row".into())
        }
        "outline" if result["sections"].as_array().is_none_or(Vec::is_empty) => {
            return Err("project outline has no sections".into())
        }
        "put-file" if result["file"]["path"] != "chapters/new.typ" => {
            return Err("put-file did not return new chapter".into())
        }
        "reading-list"
            if !result["rows"].as_array().is_some_and(|rows| {
                rows.iter()
                    .any(|r| r["cite_key"] == "g3reading" && r["publication_id"] == PAPER_LIST)
            }) =>
        {
            return Err("reading list did not resolve cited paper".into())
        }
        "render-figure" if result["outputs"].as_array().is_none_or(Vec::is_empty) => {
            return Err("figure render recorded no output".into())
        }
        "set-bibliography" if result["file"]["bib_source_json"] != "{\"kind\":\"cited\"}" => {
            return Err("bibliography projection was not stored".into())
        }
        "set-entry"
            if row.payload.get("entry_path") != Some(&ItemValue::String("paper.typ".into())) =>
        {
            return Err("entry path did not persist".into())
        }
        "set-figure-build"
            if result["file"]["build_json"]
                .as_str()
                .is_none_or(|s| !s.contains("impress-plot")) =>
        {
            return Err("figure build spec was not stored".into())
        }
        "set-targets"
            if !result["targets"]
                .as_array()
                .is_some_and(|rows| rows.iter().any(|r| r["id"] == "paper")) =>
        {
            return Err("targets were not stored".into())
        }
        "snapshot" => {
            let revision: ItemId = result["revision_id"]
                .as_str()
                .ok_or("snapshot omitted revision ID")?
                .parse()
                .map_err(|e| format!("revision UUID: {e}"))?;
            if store.get(revision).map_err(|e| e.to_string())?.is_none() {
                return Err("project snapshot did not persist revision".into());
            }
        }
        "status"
            if result["changed"]
                .as_array()
                .is_none_or(|rows| !rows.iter().any(|v| v == "main.typ")) =>
        {
            return Err("status did not detect working-copy edit".into())
        }
        "sync-reading-collection"
            if result["added"]
                .as_array()
                .is_none_or(|rows| !rows.iter().any(|v| v == PAPER_SYNC)) =>
        {
            return Err("sync did not add cited paper".into())
        }
        "tree"
            if result["files"]
                .as_array()
                .is_none_or(|v| !v.iter().any(|f| f["path"] == CHAPTER)) =>
        {
            return Err("project tree omitted seeded chapter".into())
        }
        _ => {}
    }
    Ok(())
}
