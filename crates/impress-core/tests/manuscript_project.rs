//! A manuscript is a project (ADR-0030 P0): the store operations behind the
//! file and build rows, and the collab layer's generalisation to file rows.
//!
//! Everything here is pure Rust against an in-memory store and a temp blob
//! directory — the Tier-A shape the plan asks every phase to land with.

#![cfg(feature = "collab")]

use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::blobs::BlobStore;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use impress_core::manuscript_project::{self as mp, Author, BuildRecord, PutFile};
use impress_core::schemas::{
    manuscript_file_id, BUILD_STATUS_OK, BUILD_STATUS_RUNNING, MANUSCRIPT_FILE_SCHEMA_REF,
};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use uuid::Uuid;

struct Fixture {
    store: SqliteItemStore,
    blobs: BlobStore,
    _dir: tempfile::TempDir,
    manuscript: ItemId,
    author: Author,
}

fn manuscript_row(id: ItemId, format: &str, body: &str) -> Item {
    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String("Paper".into()));
    payload.insert("format".into(), Value::String(format.into()));
    payload.insert("status".into(), Value::String("draft".into()));
    payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
    payload.insert("body_content".into(), Value::String(body.into()));
    payload.insert(
        "body_content_hash".into(),
        Value::String(impress_core::manuscript_ops::sha256_hex(body)),
    );
    let now = Utc::now();
    Item {
        id,
        schema: "manuscript".into(),
        payload,
        created: now,
        modified: now,
        author: "user:test".into(),
        author_kind: ActorKind::Human,
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
    }
}

fn fixture(format: &str, body: &str) -> Fixture {
    let store = SqliteItemStore::open_in_memory().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let blobs = BlobStore::for_workspace(dir.path());
    let manuscript = Uuid::new_v4();
    store
        .insert(manuscript_row(manuscript, format, body))
        .unwrap();
    Fixture {
        store,
        blobs,
        _dir: dir,
        manuscript,
        author: Author::human("user:test"),
    }
}

fn payload_str(store: &SqliteItemStore, id: ItemId, key: &str) -> Option<String> {
    match store.get(id).unwrap().unwrap().payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn payload_int(store: &SqliteItemStore, id: ItemId, key: &str) -> Option<i64> {
    match store.get(id).unwrap().unwrap().payload.get(key) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

#[test]
fn a_manuscript_with_no_file_rows_is_a_one_file_project() {
    let f = fixture("typst", "= Hello\nworld");
    let snap = mp::load_project(&f.store, f.manuscript).unwrap();
    assert_eq!(snap.entry_path, "main.typ");
    assert_eq!(snap.entry_text, "= Hello\nworld");
    assert_eq!(
        snap.entry_hash,
        impress_core::manuscript_ops::sha256_hex("= Hello\nworld")
    );
    assert!(snap.files.is_empty());
    assert_eq!(snap.project_version, 0, "nothing was stamped");
    assert!(snap.targets_json.is_none());

    let latex = fixture("latex", "\\documentclass{article}");
    assert_eq!(
        mp::load_project(&latex.store, latex.manuscript)
            .unwrap()
            .entry_path,
        "main.tex"
    );
}

#[test]
fn text_and_binary_files_round_trip_and_list_sorted() {
    let f = fixture("latex", "\\input{chapters/intro}");
    let chapter = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("chapters/intro.tex", "\\section{Intro}\nText."),
        &f.author,
    )
    .unwrap();
    assert_eq!(chapter.role, "chapter");
    assert_eq!(chapter.kind, "text");
    assert_eq!(chapter.format.as_deref(), Some("latex"));
    assert_eq!(chapter.content.as_deref(), Some("\\section{Intro}\nText."));
    assert!(chapter.blob_ref.is_none());
    assert_eq!(chapter.size, "\\section{Intro}\nText.".len() as i64);
    assert_eq!(chapter.mime_type.as_deref(), Some("text/x-tex"));

    let png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    let figure = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::bytes("figures/fig1.png", &png),
        &f.author,
    )
    .unwrap();
    assert_eq!(figure.role, "figure");
    assert_eq!(figure.kind, "binary", "NUL bytes are not text");
    assert!(figure.content.is_none());
    let blob_ref = figure.blob_ref.clone().expect("binary goes to the CAS");
    assert!(blob_ref.starts_with("blob:sha256:"));
    assert_eq!(
        figure.content_hash,
        impress_core::blobs::sha256_hex_bytes(&png)
    );
    assert_eq!(figure.bytes(&f.blobs).unwrap().as_deref(), Some(&png[..]));
    assert_eq!(
        chapter.bytes(&f.blobs).unwrap().unwrap(),
        b"\\section{Intro}\nText."
    );

    let bib = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("refs.bib", "@article{a, title={A}}"),
        &f.author,
    )
    .unwrap();
    assert_eq!(bib.role, "bibliography");
    assert_eq!(bib.format.as_deref(), Some("bibtex"));

    let listed: Vec<String> = mp::list_files(&f.store, f.manuscript)
        .unwrap()
        .into_iter()
        .map(|r| r.path)
        .collect();
    assert_eq!(
        listed,
        vec!["chapters/intro.tex", "figures/fig1.png", "refs.bib"]
    );

    let snap = mp::load_project(&f.store, f.manuscript).unwrap();
    assert_eq!(snap.files.len(), 3);
    assert_eq!(
        snap.project_version, 1,
        "the first file row stamps the manuscript"
    );
    assert!(snap.file("refs.bib").is_some());

    assert!(mp::delete_file(&f.store, f.manuscript, "refs.bib").unwrap());
    assert!(!mp::delete_file(&f.store, f.manuscript, "refs.bib").unwrap());
    assert!(mp::get_file(&f.store, f.manuscript, "refs.bib")
        .unwrap()
        .is_none());
}

#[test]
fn ids_derive_from_the_path_and_a_second_put_updates_in_place() {
    let f = fixture("typst", "");
    let first = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("ch/one.typ", "v1").with_role("supplement"),
        &f.author,
    )
    .unwrap();
    assert_eq!(first.id, manuscript_file_id(f.manuscript, "ch/one.typ"));
    assert_eq!(first.role, "supplement");

    let second = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("./ch//one.typ", "v2"),
        &f.author,
    )
    .unwrap();
    assert_eq!(
        second.id, first.id,
        "same path, same row, however it is spelled"
    );
    assert_eq!(second.content.as_deref(), Some("v2"));
    assert_eq!(
        second.role, "supplement",
        "a put without a role keeps the old one"
    );
    assert_eq!(mp::list_files(&f.store, f.manuscript).unwrap().len(), 1);

    // The one-get read path.
    let got = mp::get_file(&f.store, f.manuscript, "ch/one.typ")
        .unwrap()
        .unwrap();
    assert_eq!(
        got.content_hash,
        impress_core::blobs::sha256_hex_bytes(b"v2")
    );
}

#[test]
fn the_entry_stays_on_the_manuscript_row() {
    let f = fixture("typst", "= Main");
    let err = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("main.typ", "= Shadow"),
        &f.author,
    )
    .unwrap_err();
    assert!(err.to_string().contains("entry file"), "{err}");

    // Renaming the entry is a durable, attributed edit on the manuscript row.
    let path = mp::set_entry_path(&f.store, f.manuscript, "paper.typ", &f.author).unwrap();
    assert_eq!(path, "paper.typ");
    assert_eq!(
        payload_str(&f.store, f.manuscript, "entry_path").as_deref(),
        Some("paper.typ")
    );
    let snap = mp::load_project(&f.store, f.manuscript).unwrap();
    assert_eq!(snap.entry_path, "paper.typ");
    assert_eq!(snap.entry_text, "= Main");
    // ...and `main.typ` is now a legal file path.
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("main.typ", "= Old"),
        &f.author,
    )
    .unwrap();
    // But a file row cannot become the entry without going first.
    let err = mp::set_entry_path(&f.store, f.manuscript, "main.typ", &f.author).unwrap_err();
    assert!(err.to_string().contains("file row"), "{err}");
    let err = mp::set_entry_path(&f.store, f.manuscript, "../x.typ", &f.author).unwrap_err();
    assert!(err.to_string().contains(".."), "{err}");
}

#[test]
fn moving_a_source_carries_its_outputs_and_frees_the_old_path() {
    let f = fixture("latex", "");
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("figures/make_fig1.py", "print('hi')"),
        &f.author,
    )
    .unwrap();
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::bytes("figures/fig1.pdf", b"%PDF-1.4\n\0"),
        &f.author,
    )
    .unwrap();
    let out = mp::record_derived(
        &f.store,
        f.manuscript,
        "figures/fig1.pdf",
        "figures/make_fig1.py",
        "hash-1",
    )
    .unwrap();
    assert_eq!(out.derived_from.as_deref(), Some("figures/make_fig1.py"));
    assert_eq!(out.derived_from_hash.as_deref(), Some("hash-1"));

    let moved = mp::move_file(
        &f.store,
        f.manuscript,
        "figures/make_fig1.py",
        "scripts/fig1.py",
        &f.author,
    )
    .unwrap();
    assert_eq!(moved.path, "scripts/fig1.py");
    assert_eq!(
        moved.id,
        manuscript_file_id(f.manuscript, "scripts/fig1.py")
    );
    assert_eq!(moved.content.as_deref(), Some("print('hi')"));
    assert_eq!(moved.format.as_deref(), Some("python"));
    assert!(mp::get_file(&f.store, f.manuscript, "figures/make_fig1.py")
        .unwrap()
        .is_none());
    let out = mp::get_file(&f.store, f.manuscript, "figures/fig1.pdf")
        .unwrap()
        .unwrap();
    assert_eq!(
        out.derived_from.as_deref(),
        Some("scripts/fig1.py"),
        "the output follows its source"
    );

    // Refusals: onto an existing path, from a missing path.
    let err = mp::move_file(
        &f.store,
        f.manuscript,
        "scripts/fig1.py",
        "figures/fig1.pdf",
        &f.author,
    )
    .unwrap_err();
    assert!(err.to_string().contains("already exists"), "{err}");
    let err = mp::move_file(&f.store, f.manuscript, "nope.tex", "x.tex", &f.author).unwrap_err();
    assert!(err.to_string().contains("no file"), "{err}");
}

#[test]
fn file_fields_are_settable_and_json_fields_are_checked() {
    let f = fixture("typst", "");
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("refs.bib", ""),
        &f.author,
    )
    .unwrap();
    let row = mp::set_file_field(
        &f.store,
        f.manuscript,
        "refs.bib",
        "bib_source_json",
        Some(r#"{"kind":"cited"}"#),
    )
    .unwrap();
    assert_eq!(row.bib_source_json.as_deref(), Some(r#"{"kind":"cited"}"#));
    let err = mp::set_file_field(
        &f.store,
        f.manuscript,
        "refs.bib",
        "build_json",
        Some("{nope"),
    )
    .unwrap_err();
    assert!(err.to_string().contains("not valid JSON"), "{err}");
    let err =
        mp::set_file_field(&f.store, f.manuscript, "refs.bib", "role", Some("main")).unwrap_err();
    assert!(err.to_string().contains("role"), "{err}");
    let err =
        mp::set_file_field(&f.store, f.manuscript, "refs.bib", "content", Some("x")).unwrap_err();
    assert!(err.to_string().contains("not a settable"), "{err}");
    let cleared =
        mp::set_file_field(&f.store, f.manuscript, "refs.bib", "bib_source_json", None).unwrap();
    assert!(cleared.bib_source_json.is_none());
}

#[test]
fn targets_are_validated_and_clearable() {
    let f = fixture("typst", "");
    let err =
        mp::set_targets(&f.store, f.manuscript, Some("{not an array}"), &f.author).unwrap_err();
    assert!(err.to_string().contains("JSON array"), "{err}");
    let err = mp::set_targets(
        &f.store,
        f.manuscript,
        Some(r#"[{"id":"a"},{"id":"a"}]"#),
        &f.author,
    )
    .unwrap_err();
    assert!(err.to_string().contains("duplicate"), "{err}");
    let err = mp::set_targets(
        &f.store,
        f.manuscript,
        Some(r#"[{"id":"a","entry":"../evil.typ"}]"#),
        &f.author,
    )
    .unwrap_err();
    assert!(err.to_string().contains(".."), "{err}");
    mp::set_targets(
        &f.store,
        f.manuscript,
        Some(r#"[{"id":"paper","entry":"main.typ","engine":"typst"},{"id":"talk","entry":"talk.typ","engine":"typst"}]"#),
        &f.author,
    )
    .unwrap();
    let snap = mp::load_project(&f.store, f.manuscript).unwrap();
    assert!(snap.targets_json.unwrap().contains("\"talk\""));
    assert_eq!(snap.project_version, 1);
    mp::set_targets(&f.store, f.manuscript, None, &f.author).unwrap();
    assert!(mp::load_project(&f.store, f.manuscript)
        .unwrap()
        .targets_json
        .is_none());
}

#[test]
fn the_input_stamp_moves_with_any_byte() {
    let f = fixture("typst", "= A");
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("b.typ", "b"),
        &f.author,
    )
    .unwrap();
    let s1 = mp::load_project(&f.store, f.manuscript)
        .unwrap()
        .input_stamp("main");
    let s1_again = mp::load_project(&f.store, f.manuscript)
        .unwrap()
        .input_stamp("main");
    assert_eq!(s1, s1_again);
    assert_ne!(
        s1,
        mp::load_project(&f.store, f.manuscript)
            .unwrap()
            .input_stamp("talk"),
        "the target is part of the stamp"
    );
    mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("b.typ", "B"),
        &f.author,
    )
    .unwrap();
    let s2 = mp::load_project(&f.store, f.manuscript)
        .unwrap()
        .input_stamp("main");
    assert_ne!(s1, s2);
}

#[test]
fn builds_are_recorded_finished_listed_and_compacted() {
    let f = fixture("typst", "= A");
    let snap = mp::load_project(&f.store, f.manuscript).unwrap();
    let mut record = BuildRecord {
        target_id: "main".into(),
        engine: "typst".into(),
        status: BUILD_STATUS_RUNNING.into(),
        input_stamp: snap.input_stamp("main"),
        started_ms: 1_000,
        ..Default::default()
    };
    let running = mp::record_build(&f.store, f.manuscript, &record, &f.author).unwrap();
    assert_eq!(running.record.status, "running");
    assert!(mp::latest_ok_build(&f.store, f.manuscript, None)
        .unwrap()
        .is_none());

    record.status = BUILD_STATUS_OK.into();
    record.finished_ms = Some(1_400);
    record.duration_ms = Some(400);
    record.outputs_json =
        Some(r#"[{"path":"main.pdf","blob_ref":"blob:sha256:ab","kind":"pdf","size":3}]"#.into());
    record.diagnostics_json = Some("[]".into());
    record.message = Some("ok".into());
    let finished = mp::finish_build(&f.store, running.id, &record).unwrap();
    assert_eq!(finished.id, running.id);
    assert_eq!(finished.record.status, "ok");
    assert_eq!(finished.record.duration_ms, Some(400));
    assert!(finished.record.outputs_json.unwrap().contains("main.pdf"));
    assert_eq!(
        mp::latest_ok_build(&f.store, f.manuscript, Some("main"))
            .unwrap()
            .unwrap()
            .id,
        running.id
    );
    assert!(mp::latest_ok_build(&f.store, f.manuscript, Some("talk"))
        .unwrap()
        .is_none());

    // Twenty-five more, then compaction keeps the newest twenty.
    for i in 0..25 {
        let mut r = record.clone();
        r.started_ms = 2_000 + i;
        mp::record_build(&f.store, f.manuscript, &r, &f.author).unwrap();
    }
    assert_eq!(
        mp::list_builds(&f.store, f.manuscript, None).unwrap().len(),
        26
    );
    let newest_first = mp::list_builds(&f.store, f.manuscript, Some(3)).unwrap();
    assert_eq!(newest_first.len(), 3);
    assert!(newest_first[0].created_ms >= newest_first[2].created_ms);
    assert_eq!(mp::compact_builds(&f.store, f.manuscript, 20).unwrap(), 6);
    assert_eq!(
        mp::list_builds(&f.store, f.manuscript, None).unwrap().len(),
        20
    );

    // The daemon's sweep: an orphaned build (manuscript deleted) is gone.
    f.store.delete(f.manuscript).unwrap();
    assert_eq!(mp::compact_all_builds(&f.store, 20).unwrap(), 20);

    let err = mp::record_build(
        &f.store,
        Uuid::new_v4(),
        &BuildRecord {
            target_id: "main".into(),
            engine: "typst".into(),
            ..Default::default()
        },
        &f.author,
    )
    .unwrap_err();
    assert!(matches!(err, impress_core::store::StoreError::NotFound(_)));
}

#[test]
fn a_text_file_row_is_a_collaborative_document() {
    let f = fixture("typst", "= Main");
    let row = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("chapters/intro.typ", "== Intro\nfirst"),
        &f.author,
    )
    .unwrap();
    assert_eq!(row.id.to_string().len(), 36);

    // Heads on first touch: genesis from the row's content.
    let heads = f.store.manuscript_collab_heads(row.id).unwrap();
    assert_eq!(heads.len(), 1, "genesis is one change");

    // An agent commits against those heads; the row is re-materialised.
    let outcome = f
        .store
        .commit_manuscript_body(row.id, &heads, "== Intro\nfirst\nsecond", "agent:test")
        .unwrap();
    assert_eq!(outcome.body, "== Intro\nfirst\nsecond");
    assert!(!outcome.merged_external);
    assert_eq!(
        payload_str(&f.store, row.id, "content").as_deref(),
        Some("== Intro\nfirst\nsecond")
    );
    assert_eq!(
        payload_str(&f.store, row.id, "content_hash").as_deref(),
        Some(outcome.body_hash.as_str())
    );
    assert_eq!(
        payload_int(&f.store, row.id, "size"),
        Some("== Intro\nfirst\nsecond".len() as i64)
    );
    assert!(payload_int(&f.store, row.id, "modified_ms").unwrap() > 0);
    // The chunks hang off the FILE row, not the manuscript.
    let history = f.store.manuscript_change_history(row.id).unwrap();
    assert_eq!(history.len(), 2, "genesis + one commit");
    assert_eq!(
        f.store
            .manuscript_change_history(f.manuscript)
            .unwrap()
            .len(),
        1,
        "the manuscript's own genesis, untouched by the file's edits"
    );

    // Concurrent edits merge (the whole point of D3).
    let stale_base = heads.clone();
    let merged = f
        .store
        .commit_manuscript_body(row.id, &stale_base, "== Intro\nzeroth\nfirst", "user:test")
        .unwrap();
    assert!(merged.merged_external, "the other side's line survived");
    assert!(merged.body.contains("zeroth") && merged.body.contains("second"));

    // Time travel reads the file at its genesis.
    let at_genesis = f.store.manuscript_text_at(row.id, &heads).unwrap();
    assert_eq!(at_genesis, "== Intro\nfirst");

    // A binary row has no document.
    let png = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::bytes("figures/f.png", b"\x89PNG\0"),
        &f.author,
    )
    .unwrap();
    let err = f.store.manuscript_collab_heads(png.id).unwrap_err();
    assert!(err.to_string().contains("not inline text"), "{err}");
    let err = f.store.manuscript_collab_heads(Uuid::new_v4()).unwrap_err();
    assert!(matches!(err, impress_core::store::StoreError::NotFound(_)));

    // And the schema on the row is the versioned spelling, so HasParent
    // readers and the manifest agree.
    assert_eq!(
        f.store.get(row.id).unwrap().unwrap().schema,
        MANUSCRIPT_FILE_SCHEMA_REF
    );
}

#[test]
fn large_text_goes_to_the_cas_and_is_not_collaborative() {
    let f = fixture("typst", "");
    let big = "x".repeat(impress_core::schemas::INLINE_TEXT_LIMIT + 1);
    let row = mp::put_file(
        &f.store,
        &f.blobs,
        f.manuscript,
        PutFile::text("big.typ", &big),
        &f.author,
    )
    .unwrap();
    assert_eq!(row.kind, "text");
    assert!(row.content.is_none());
    assert!(row.blob_ref.is_some());
    assert_eq!(row.bytes(&f.blobs).unwrap().unwrap().len(), big.len());
    let err = f.store.manuscript_collab_heads(row.id).unwrap_err();
    assert!(err.to_string().contains("not inline text"), "{err}");
}
