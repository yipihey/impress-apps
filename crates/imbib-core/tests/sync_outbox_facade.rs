//! ADR-0007 Phase 3, Phase A gate: change capture is TRIGGER-based, so it
//! must hold for writes made through the high-level `ImbibStore` façade
//! without any per-call-site wiring. Outbox inspected through a second
//! `SqliteItemStore` handle on the same file (separate connection — also
//! proves the capture tables are in the main database, not TEMP).
#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_core::sqlite_store::SqliteItemStore;

fn temp_db() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("impress.sqlite")
        .to_string_lossy()
        .to_string();
    (dir, path)
}

#[test]
fn facade_writes_enqueue_and_deletes_tombstone() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open imbib");
    let probe = SqliteItemStore::open(std::path::Path::new(&path)).expect("open probe");

    let lib = imbib.create_library("Sync Test".into()).expect("lib");
    let ids = imbib
        .import_bibtex(
            "@article{Sync2026, author={Abel, Tom}, title={Convergence}}".into(),
            lib.id.clone(),
        )
        .expect("import");
    assert_eq!(ids.len(), 1);
    let pub_id = ids[0].to_lowercase();

    let entries = probe.sync_outbox_entries(200).expect("outbox");
    assert!(
        entries.iter().any(|(_, k, r)| k == "item" && r == &pub_id),
        "imported publication must be enqueued (got {entries:?})"
    );
    assert!(
        entries
            .iter()
            .any(|(_, k, r)| k == "item" && r == &lib.id.to_lowercase()),
        "created library must be enqueued"
    );

    // Flag mutation through the façade re-enqueues (still one row, deduped).
    imbib
        .set_read(vec![ids[0].clone()], true)
        .expect("set_read");
    let item_rows = probe
        .sync_outbox_entries(200)
        .expect("outbox")
        .into_iter()
        .filter(|(_, k, r)| k == "item" && r == &pub_id)
        .count();
    assert_eq!(item_rows, 1);

    // Façade delete → tombstone + delete_item, pending push pruned.
    imbib
        .delete_publications(vec![ids[0].clone()])
        .expect("delete");
    let entries = probe.sync_outbox_entries(200).expect("outbox");
    assert!(entries
        .iter()
        .any(|(_, k, r)| k == "delete_item" && r == &pub_id));
    assert!(!entries.iter().any(|(_, k, r)| k == "item" && r == &pub_id));
    let tombs = probe.list_tombstones_since(0).expect("tombstones");
    assert!(
        tombs
            .iter()
            .any(|(id, schema, _)| id.to_lowercase() == pub_id
                && schema == "imbib/bibliography-entry"),
        "façade delete must record a tombstone (got {tombs:?})"
    );
}
