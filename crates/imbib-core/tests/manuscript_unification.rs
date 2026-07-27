//! GUI-meld Phase 0 verification: manuscripts as first-class ImbibStore rows.
//!
//! The load-bearing test here is the cross-adapter round-trip: an item written
//! through `impress-store-ffi::SharedStore` with imprint's exact
//! ManuscriptStoreAdapter payload must surface through `ImbibStore`'s
//! manuscript queries on the same database file — proving both apps speak one
//! `manuscript@1.0.0` vocabulary with no translation layer.
#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_store_ffi::SharedStore;

fn temp_db() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("impress.sqlite")
        .to_string_lossy()
        .to_string();
    (dir, path)
}

/// imprint's ManuscriptStoreAdapter.createManuscript payload, verbatim field
/// set (apps/imprint/Shared/Services/ManuscriptStoreAdapter.swift:249-259).
fn imprint_payload(id: &str, title: &str, body: &str, hash: &str) -> String {
    serde_json::json!({
        "title": title,
        "status": "draft",
        "current_revision_ref": id,
        "authors": ["Abel, Tom"],
        "format": "typst",
        "body_content": body,
        "body_content_hash": hash,
        "body_modified_at": "2026-07-21T00:00:00Z",
        "format_schema_version": 140,
    })
    .to_string()
}

#[test]
fn imprint_written_manuscript_surfaces_in_imbib_store() {
    let (_dir, path) = temp_db();

    // imprint side: SharedStore write with the adapter's exact payload shape.
    let shared = SharedStore::open(path.clone()).expect("open SharedStore");
    let id = uuid::Uuid::new_v4().to_string();
    shared
        .upsert_item(
            id.clone(),
            "manuscript".into(),
            imprint_payload(&id, "Dark Matter Review", "= Intro\nHello", "abc123"),
        )
        .expect("upsert manuscript");

    // imbib side: second handle on the same file (WAL topology of the suite).
    let imbib = ImbibStore::open(path).expect("open ImbibStore");
    let rows = imbib
        .list_manuscripts(None, None, "modified".into(), false, None, None)
        .expect("list manuscripts");
    assert_eq!(rows.len(), 1, "imprint's manuscript must be visible");
    let row = &rows[0];
    assert_eq!(row.id, id);
    assert_eq!(row.title, "Dark Matter Review");
    assert_eq!(row.status, "draft");
    assert_eq!(row.format, "typst");
    assert_eq!(row.author_string, "Abel, Tom");
    assert_eq!(row.body_content_hash.as_deref(), Some("abc123"));
    assert!(!row.body_is_blob_ref);

    let detail = imbib
        .get_manuscript_detail(id.clone())
        .expect("detail query")
        .expect("detail present");
    assert_eq!(detail.body_content, "= Intro\nHello");
    assert_eq!(detail.format_schema_version, Some(140));
    assert_eq!(detail.current_revision_ref.as_deref(), Some(id.as_str()));
}

#[test]
fn imbib_created_manuscript_matches_imprint_shape_and_is_readable_via_shared_store() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");

    let row = imbib
        .create_manuscript(
            "Chassis Paper".into(),
            "typst".into(),
            "= Body".into(),
            vec!["Abel, Tom".into()],
        )
        .expect("create manuscript");

    // Read back through the SharedStore handle (imprint's view).
    let shared = SharedStore::open(path).expect("open SharedStore");
    let item = shared
        .get_item(row.id.clone())
        .expect("get")
        .expect("present");
    assert_eq!(item.schema_ref, "manuscript");
    let payload: serde_json::Value = serde_json::from_str(&item.payload_json).unwrap();
    // The full imprint field set must be present so items are
    // indistinguishable regardless of which app created them.
    assert_eq!(payload["title"], "Chassis Paper");
    assert_eq!(payload["status"], "draft");
    assert_eq!(payload["format"], "typst");
    assert_eq!(payload["body_content"], "= Body");
    assert_eq!(payload["format_schema_version"], 140);
    assert_eq!(payload["current_revision_ref"], row.id);
    assert!(payload["body_content_hash"].as_str().unwrap().len() == 64);
    assert!(payload["body_modified_at"].as_str().unwrap().ends_with('Z'));
}

#[test]
fn guarded_body_save_detects_conflict_and_fast_path_applies() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");
    let row = imbib
        .create_manuscript("M".into(), "typst".into(), "v1".into(), vec![])
        .expect("create");
    let hash_v1 = row.body_content_hash.clone().expect("hash");

    // Correct guard applies.
    let ok = imbib
        .set_manuscript_body(row.id.clone(), "v2".into(), Some(hash_v1.clone()))
        .expect("guarded save");
    assert!(ok.applied);
    let hash_v2 = ok.new_hash.expect("new hash");
    assert_ne!(hash_v1, hash_v2);

    // Stale guard (still v1) must be rejected with the stored hash reported.
    let conflict = imbib
        .set_manuscript_body(row.id.clone(), "v3-lost-update".into(), Some(hash_v1))
        .expect("guarded save call");
    assert!(!conflict.applied, "stale guard must not clobber");
    assert_eq!(conflict.stored_hash.as_deref(), Some(hash_v2.as_str()));

    // Body unchanged by the rejected write.
    let detail = imbib
        .get_manuscript_detail(row.id.clone())
        .unwrap()
        .unwrap();
    assert_eq!(detail.body_content, "v2");

    // Unguarded save still works (legacy imprint behavior).
    let forced = imbib
        .set_manuscript_body(row.id, "v3".into(), None)
        .expect("unguarded save");
    assert!(forced.applied);
}

#[test]
fn large_inline_body_round_trips_and_blob_ref_is_flagged() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");

    // >1MB inline body: the store must round-trip it byte-identically
    // (SQLite handles multi-MB TEXT; the blob-ref escape hatch is optional).
    let big = "x".repeat(1_200_000);
    let row = imbib
        .create_manuscript("Big".into(), "latex".into(), big.clone(), vec![])
        .expect("create big manuscript");
    assert_eq!(row.body_size, 1_200_000);
    let detail = imbib.get_manuscript_detail(row.id).unwrap().unwrap();
    assert_eq!(detail.body_content.len(), big.len());
    assert!(!detail.body_is_blob_ref);

    // A blob-ref body is passed through and flagged, never mistaken for markup.
    let row2 = imbib
        .create_manuscript(
            "Blobbed".into(),
            "typst".into(),
            "blob:sha256:deadbeef".into(),
            vec![],
        )
        .expect("create blob-ref manuscript");
    assert!(row2.body_is_blob_ref);
    assert_eq!(row2.body_size, 0);
    let detail2 = imbib.get_manuscript_detail(row2.id).unwrap().unwrap();
    assert!(detail2.body_is_blob_ref);
    assert_eq!(detail2.body_content, "blob:sha256:deadbeef");
}

#[test]
fn manuscript_collections_reuse_generic_contains_membership() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");

    let folder = imbib
        .create_manuscript_collection("Cosmology".into(), None)
        .expect("create folder");
    let child = imbib
        .create_manuscript_collection("Drafts".into(), Some(folder.id.clone()))
        .expect("create nested folder");
    assert_eq!(child.parent_id.as_deref(), Some(folder.id.as_str()));

    let m1 = imbib
        .create_manuscript("A".into(), "typst".into(), "".into(), vec![])
        .unwrap();
    let m2 = imbib
        .create_manuscript("B".into(), "typst".into(), "".into(), vec![])
        .unwrap();

    // Membership via the EXISTING schema-agnostic collection API.
    imbib
        .add_to_collection(vec![m1.id.clone(), m2.id.clone()], folder.id.clone())
        .expect("add manuscripts to folder");

    let in_folder = imbib
        .list_manuscripts(
            Some(folder.id.clone()),
            None,
            "title".into(),
            true,
            None,
            None,
        )
        .expect("list folder members");
    assert_eq!(in_folder.len(), 2);
    assert_eq!(in_folder[0].title, "A");

    let folders = imbib.list_manuscript_collections().expect("list folders");
    let cosmology = folders.iter().find(|f| f.id == folder.id).unwrap();
    assert_eq!(cosmology.manuscript_count, 2);

    imbib
        .remove_from_collection(vec![m1.id.clone()], folder.id.clone())
        .expect("remove from folder");
    assert_eq!(
        imbib
            .count_manuscripts(Some(folder.id), None)
            .expect("count"),
        1
    );
}

#[test]
fn status_filter_and_revision_lifecycle() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open");

    let m = imbib
        .create_manuscript("Paper".into(), "typst".into(), "draft body".into(), vec![])
        .unwrap();

    // Status filter.
    assert_eq!(
        imbib.count_manuscripts(None, Some("draft".into())).unwrap(),
        1
    );
    assert_eq!(
        imbib
            .count_manuscripts(None, Some("published".into()))
            .unwrap(),
        0
    );

    // Revision snapshot advances the head and shows up in the row count.
    let rev = imbib
        .create_manuscript_revision(m.id.clone(), "v1".into(), "manual".into())
        .expect("create revision");
    assert_eq!(rev.parent_manuscript_ref, m.id);
    assert_eq!(rev.revision_tag, "v1");
    assert!(rev.pdf_artifact_ref.is_none(), "no compiled PDF yet");

    let row = imbib
        .get_manuscript_row(m.id.clone())
        .unwrap()
        .expect("row");
    assert_eq!(row.revision_count, 1);

    let detail = imbib.get_manuscript_detail(m.id.clone()).unwrap().unwrap();
    assert_eq!(
        detail.current_revision_ref.as_deref(),
        Some(rev.id.as_str())
    );

    // Second revision chains to the first — and is visible over SharedStore
    // too (imprint's pre-cutover Versions UI reads that surface).
    imbib
        .set_manuscript_body(m.id.clone(), "edited body".into(), None)
        .unwrap();
    let rev2 = imbib
        .create_manuscript_revision(m.id.clone(), "v2".into(), "user-tag".into())
        .expect("second revision");
    assert_eq!(
        rev2.predecessor_revision_ref.as_deref(),
        Some(rev.id.as_str())
    );

    let shared = SharedStore::open(path).expect("open shared");
    let shared_revs = shared
        .list_manuscript_revisions(m.id.clone())
        .expect("shared revisions");
    assert_eq!(shared_revs.len(), 2);

    // Operation history over SharedStore: the body edit is flagged as such.
    let ops = shared.operations_for(m.id, 0).expect("ops");
    assert!(!ops.is_empty());
    assert!(
        ops.iter().any(|o| o.is_body_edit),
        "body_content SetPayload must be classified as a body edit"
    );
    assert!(
        ops.iter()
            .any(|o| o.field_names == vec!["current_revision_ref".to_string()]),
        "head advance must be visible as a metadata op"
    );
}

#[test]
fn search_manuscripts_matches_title_and_body() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");
    imbib
        .create_manuscript(
            "Reionization".into(),
            "typst".into(),
            "= Section on quasars".into(),
            vec![],
        )
        .unwrap();
    imbib
        .create_manuscript("Unrelated".into(), "typst".into(), "nothing".into(), vec![])
        .unwrap();

    // Contains is token-based (FTS): match whole words, not prefixes.
    let by_title = imbib
        .search_manuscripts("Reionization".into(), None)
        .expect("title search");
    assert_eq!(by_title.len(), 1);

    let by_body = imbib
        .search_manuscripts("quasars".into(), None)
        .expect("body search");
    assert_eq!(by_body.len(), 1);
    assert_eq!(by_body[0].title, "Reionization");
}

#[test]
fn plot_spec_crud_roundtrip() {
    let (_dir, path) = temp_db();
    let store = ImbibStore::open(path).expect("open ImbibStore");
    let spec_json = r#"{"title":"t","series":[{"kind":"line","xs":[1,2],"ys":[3,4]}]}"#;
    let row = store
        .save_plot_spec(
            "My plot".into(),
            "series".into(),
            spec_json.into(),
            Some("data.csv".into()),
        )
        .expect("save");
    assert_eq!(row.name, "My plot");
    assert_eq!(row.spec_kind, "series");

    let listed = store.list_plot_specs(10).expect("list");
    assert!(listed.iter().any(|r| r.id == row.id));

    let got = store
        .get_plot_spec(row.id.clone())
        .expect("get")
        .expect("exists");
    assert_eq!(got.spec_json, spec_json);
    assert_eq!(got.data_source.as_deref(), Some("data.csv"));

    // invalid inputs error cleanly
    assert!(store
        .save_plot_spec("x".into(), "bogus".into(), "{}".into(), None)
        .is_err());
    assert!(store
        .save_plot_spec("x".into(), "series".into(), "not json".into(), None)
        .is_err());

    store.delete_item(row.id.clone()).expect("delete");
    assert!(store.get_plot_spec(row.id).expect("get2").is_none());
}

/// Regression: `CollectionRow.parent_id` must be the tree parent from the
/// payload, NOT `item.parent` (which is the owning library for every
/// collection). c902a22f briefly returned the library, which made every
/// collection a "subcollection" of nothing and flattened the sidebar tree.
#[test]
fn collection_parent_id_is_payload_not_owning_library() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");

    let lib = imbib.create_library("Papers".into()).expect("library");
    let root = imbib
        .create_collection("Cosmology".into(), lib.id.clone(), false, None)
        .expect("root collection");
    let child = imbib
        .create_collection("Reionization".into(), lib.id.clone(), false, None)
        .expect("child collection");

    // Reparenting writes payload `parent_id` — exactly what the sidebar does.
    imbib
        .update_field(child.id.clone(), "parent_id".into(), Some(root.id.clone()))
        .expect("reparent");

    let rows = imbib.list_collections(lib.id).expect("list");
    let root_row = rows.iter().find(|r| r.id == root.id).unwrap();
    let child_row = rows.iter().find(|r| r.id == child.id).unwrap();
    assert_eq!(
        root_row.parent_id, None,
        "root collection must have no parent"
    );
    assert_eq!(
        child_row.parent_id.as_deref(),
        Some(root.id.as_str()),
        "reparented collection must surface its payload parent_id"
    );
}

/// Flags live on the generic item envelope; `list_flagged_manuscripts` is the
/// manuscript-schema counterpart of `get_flagged_publications`.
#[test]
fn flagged_manuscripts_are_queryable_by_color() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");

    let m1 = imbib
        .create_manuscript("Flagged".into(), "typst".into(), "".into(), vec![])
        .unwrap();
    let _m2 = imbib
        .create_manuscript("Unflagged".into(), "typst".into(), "".into(), vec![])
        .unwrap();
    imbib
        .set_flag(vec![m1.id.clone()], Some("red".into()), None, None)
        .expect("flag");

    let any = imbib.list_flagged_manuscripts(None).expect("any");
    assert_eq!(any.len(), 1);
    assert_eq!(any[0].id, m1.id);

    let red = imbib
        .list_flagged_manuscripts(Some("red".into()))
        .expect("red");
    assert_eq!(red.len(), 1);

    let blue = imbib
        .list_flagged_manuscripts(Some("blue".into()))
        .expect("blue");
    assert!(blue.is_empty());
}

/// Markdown and plain text are first-class manuscript formats (WS2): creation
/// must accept them, reject typos, and round-trip format + body untouched.
#[test]
fn markdown_and_plaintext_formats_round_trip() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path).expect("open");

    let md = imbib
        .create_manuscript(
            "ARD 12".into(),
            "markdown".into(),
            "# Decision\n\nUse *one* store.".into(),
            vec![],
        )
        .expect("create markdown");
    let txt = imbib
        .create_manuscript(
            "Scratch".into(),
            "plaintext".into(),
            "raw notes".into(),
            vec![],
        )
        .expect("create plaintext");
    assert!(imbib
        .create_manuscript("Nope".into(), "orgmode".into(), "".into(), vec![])
        .is_err());

    let md_detail = imbib
        .get_manuscript_detail(md.id)
        .expect("detail")
        .expect("exists");
    assert_eq!(md_detail.format, "markdown");
    assert_eq!(md_detail.body_content, "# Decision\n\nUse *one* store.");
    let txt_detail = imbib
        .get_manuscript_detail(txt.id)
        .expect("detail")
        .expect("exists");
    assert_eq!(txt_detail.format, "plaintext");

    let formats = imbib.supported_manuscript_formats();
    assert_eq!(formats, vec!["typst", "latex", "markdown", "plaintext"]);
}
