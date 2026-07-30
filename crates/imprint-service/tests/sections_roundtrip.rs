//! End-to-end persistence tests for `SectionStore`.
//!
//! These tests use an on-disk SQLite store (rather than the in-memory store
//! used in unit tests) so we exercise the full open / persist / re-open path
//! plus the on-disk content-addressed blob store.

use imprint_service::{BlobStore, SectionMetadata, SectionStore, LARGE_BODY_THRESHOLD};
use tempfile::TempDir;
use uuid::Uuid;

#[test]
fn open_persists_to_disk() {
    let workspace = TempDir::new().unwrap();
    let store = SectionStore::open(workspace.path()).unwrap();

    // After open we expect the SQLite file (and on first write the blob
    // directory) to live under workspace_root.
    assert!(workspace.path().join("impress.sqlite").exists());

    let doc = Uuid::new_v4();
    store
        .put_section(
            doc,
            "intro",
            "Hello there.",
            SectionMetadata {
                title: Some("Intro".into()),
                section_type: Some("introduction".into()),
                order_index: Some(0),
            },
        )
        .unwrap();

    // Re-open the same workspace and check the section comes back.
    drop(store);
    let store2 = SectionStore::open(workspace.path()).unwrap();
    let got = store2.get_section(doc, "intro").unwrap().unwrap();
    assert_eq!(got.body, "Hello there.");
    assert_eq!(got.title, "Intro");
    assert_eq!(got.section_type.as_deref(), Some("introduction"));
    assert_eq!(got.order_index, Some(0));
    assert!(got.content_hash.is_none(), "small body stays inline");
}

#[test]
fn large_body_is_offloaded_to_cas_directory() {
    let workspace = TempDir::new().unwrap();
    let store = SectionStore::open(workspace.path()).unwrap();
    let doc = Uuid::new_v4();
    let big = "x".repeat(LARGE_BODY_THRESHOLD + 1024);

    let rec = store
        .put_section(doc, "methods", &big, SectionMetadata::default())
        .unwrap();
    assert!(rec.content_hash.is_some());

    // The blob file lives under <workspace>/content/<hash>.
    let blob_dir = workspace.path().join("content");
    assert!(blob_dir.exists(), "blob directory must exist after offload");

    let hash = rec.content_hash.as_ref().unwrap();
    let blob_path = blob_dir.join(hash);
    assert!(blob_path.exists(), "blob file must exist for {hash}");

    // Hash matches our digest of the body.
    assert_eq!(BlobStore::sha256_hex(&big), *hash);

    // Re-open: the body still rehydrates from CAS.
    drop(store);
    let store2 = SectionStore::open(workspace.path()).unwrap();
    let got = store2.get_section(doc, "methods").unwrap().unwrap();
    assert_eq!(got.body, big);
}

#[test]
fn list_sections_orders_by_order_index_then_creation() {
    let workspace = TempDir::new().unwrap();
    let store = SectionStore::open(workspace.path()).unwrap();
    let doc = Uuid::new_v4();

    // Insert out-of-order; expect list_sections to sort by order_index.
    store
        .put_section(
            doc,
            "c",
            "third",
            SectionMetadata {
                order_index: Some(2),
                ..Default::default()
            },
        )
        .unwrap();
    store
        .put_section(
            doc,
            "a",
            "first",
            SectionMetadata {
                order_index: Some(0),
                ..Default::default()
            },
        )
        .unwrap();
    store
        .put_section(
            doc,
            "b",
            "second",
            SectionMetadata {
                order_index: Some(1),
                ..Default::default()
            },
        )
        .unwrap();

    let sections = store.list_sections(doc, 0).unwrap();
    let keys: Vec<&str> = sections.iter().map(|s| s.section_key.as_str()).collect();
    assert_eq!(keys, vec!["a", "b", "c"]);
}

#[test]
fn delete_then_get_returns_none() {
    let workspace = TempDir::new().unwrap();
    let store = SectionStore::open(workspace.path()).unwrap();
    let doc = Uuid::new_v4();
    store
        .put_section(doc, "k", "v", SectionMetadata::default())
        .unwrap();
    store.delete_section(doc, "k").unwrap();
    assert!(store.get_section(doc, "k").unwrap().is_none());
    // Repeated delete must not error.
    store.delete_section(doc, "k").unwrap();
}

/// The writer/reader spelling contract, asserted against the REAL writer.
///
/// `SectionStore::put_section` writes `SECTION_SCHEMA_REF`, and the Swift
/// readers (`ImprintImpressStore.listAllSections` /
/// `allManuscriptSections`, `ManuscriptSection.init(row:)`) query by a
/// hard-coded string. Those two lived in different languages with no shared
/// type, and they disagreed: the writer wrote `manuscript-section`, every
/// reader asked for `manuscript-section@1.0.0`. Because the store matches
/// `schema_ref` by EXACT EQUALITY, the readers returned zero rows forever —
/// silently, so the outline, `/api/manuscripts/{id}/sections` and
/// cross-document search were structurally empty regardless of data.
///
/// This test pins BOTH halves of that: the ref the writer emits, and the fact
/// that the versioned spelling matches nothing. `schema-refs.json` is the
/// cross-language source of truth; `scripts/check-schema-refs.sh` enforces it
/// at every call site. This is the Rust-side proof that the truth it records
/// is the truth the store actually holds.
#[test]
fn sections_are_written_under_the_bare_ref_the_swift_readers_query() {
    let workspace = TempDir::new().unwrap();
    let store = SectionStore::open(workspace.path()).unwrap();
    let doc = Uuid::new_v4();

    for (key, title) in [("intro", "Introduction"), ("methods", "Methods")] {
        store
            .put_section(
                doc,
                key,
                "Body text.",
                SectionMetadata {
                    title: Some(title.into()),
                    section_type: Some(key.into()),
                    order_index: Some(0),
                },
            )
            .unwrap();
    }

    let shared = store.shared_store();

    // What the Swift readers ask for TODAY. Must be non-empty.
    let live = shared
        .query_by_schema("manuscript-section".to_string(), 100, 0)
        .unwrap();
    assert_eq!(
        live.len(),
        2,
        "the bare ref must find the rows put_section just wrote"
    );

    // What they asked for BEFORE the fix. Must find nothing — this is the
    // assertion that would have failed loudly instead of the feature failing
    // quietly.
    let dead = shared
        // schema-ref-lint:allow — naming the dead spelling is the point.
        .query_by_schema("manuscript-section@1.0.0".to_string(), 100, 0)
        .unwrap();
    assert!(
        dead.is_empty(),
        "a versioned ref must match nothing; if this ever returns rows, some \
         writer started emitting `@1.0.0` and schema-refs.json is now wrong"
    );

    // And the constant the writer exports is exactly the canonical spelling,
    // so the manifest, the lint and the Swift readers all name one string.
    assert_eq!(imprint_service::SECTION_SCHEMA_REF, "manuscript-section");
}
