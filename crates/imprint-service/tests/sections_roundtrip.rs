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
