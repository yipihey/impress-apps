//! ADR-0022 WP G7: what the collection migration COSTS the legacy readers.
//!
//! `impress_core::collection_migration` rewrites `imbib/collection` and
//! `manuscript-collection` rows onto `collection@1.0.0`. The kernel
//! (`collection_ops`, and therefore `impress_store_ffi::SharedStore::collection_*`
//! and `CollectionStoreAdapter` in Swift) reads correctly on both sides of that
//! flip, because it consults the `collections.unified` marker.
//!
//! imbib-core's LEGACY readers do not. They query the legacy `schema_ref`
//! literals directly, so after a migration they return EMPTY — and
//! `rename_collection`, whose schema guard runs before the write, returns
//! `NotFound` outright.
//!
//! **This test asserts that on purpose.** It is not a bug report; it is the
//! reason the flag ships OFF and stays off. The Swift surfaces still on these
//! exports would regress the moment somebody flipped it:
//!
//! | export | Swift caller | effect if flipped today |
//! |---|---|---|
//! | `list_collections` | `RustStoreAdapter.listCollections(libraryId:)` → `ImbibSidebarViewModel` (Libraries / Inbox / Exploration), `CollectionViewModel`, `GlobalSearchPaletteView`, `AutomationService` `/api/collections`, App Intents, iOS sidebar, imprint via `ImbibBridge` | every publication collection disappears from the sidebar |
//! | `list_manuscript_collections` | `ImbibSidebarViewModel.manuscriptFolderNodes()` | the whole Manuscripts folder tree disappears — while `CollectionStoreAdapter` (kernel) still creates and renames those folders |
//! | `list_collections_for_publication` | `FirstSyncMerge`, iOS "remove from all collections" | first-sync merge silently drops membership |
//! | `rename_collection` | iOS sidebar inline rename | throws `NotFound` |
//! | `delete_library_undoable` | `RustStoreAdapter.deleteLibrary(id:)` | undo restores the library but orphans its collections |
//! | `get_publication_detail` / `get_manuscript_detail` | detail panes, Mbox/Everything exporters | `.collections` is empty everywhere, including in exported archives |
//!
//! The gate for flipping the flag is moving those readers onto
//! `SharedStore::collection_*` — which already answers correctly here, and is
//! asserted alongside so the contrast is in one place.

#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_core::collection_migration;
use impress_core::collection_ops::{self, IMBIB_COLLECTION, MANUSCRIPT_COLLECTION};
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
fn migration_blinds_the_legacy_collection_readers_and_the_kernel_still_sees() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");

    // A realistic legacy tree, written through imbib-core's own legacy API —
    // the exact rows a shipping database holds today.
    let library = imbib
        .create_library("Main".into())
        .expect("create library")
        .id;
    let reading = imbib
        .create_collection("Reading".into(), library.clone(), false, None)
        .expect("create collection")
        .id;
    let folder = imbib
        .create_manuscript_collection("Drafts".into(), None)
        .expect("create manuscript collection")
        .id;

    assert_eq!(
        imbib.list_collections(library.clone()).unwrap().len(),
        1,
        "precondition: the legacy reader sees its own row"
    );
    assert_eq!(
        imbib.list_manuscript_collections().unwrap().len(),
        1,
        "precondition: so does the manuscript one"
    );

    // Migrate on a second handle — the suite's real WAL topology.
    let kernel = SqliteItemStore::open(std::path::Path::new(&path)).expect("open kernel handle");
    assert!(!collection_migration::is_migrated(&kernel).unwrap());
    let report = collection_migration::migrate_collections(&kernel, false).expect("migrate");
    assert_eq!(report.rewritten(), 2);

    // ── The expected regression. THIS is why the flag stays off. ──
    assert!(
        imbib.list_collections(library.clone()).unwrap().is_empty(),
        "EXPECTED: list_collections queries schema_ref = 'imbib/collection' \
         directly and cannot see a migrated row. Flipping the flag today \
         empties the imbib sidebar."
    );
    assert!(
        imbib.list_manuscript_collections().unwrap().is_empty(),
        "EXPECTED: list_manuscript_collections is blind the same way — and it \
         is the ONLY reader behind ImbibSidebarViewModel.manuscriptFolderNodes(), \
         whose writes already go through the kernel."
    );
    assert!(
        imbib
            .rename_collection(reading.clone(), "Renamed".into())
            .is_err(),
        "EXPECTED: rename_collection's schema guard runs before the write, so \
         it fails loudly rather than returning an empty list."
    );

    // ── The kernel, on the same rows, through the same binding constants. ──
    let publications = collection_ops::list_tree(&kernel, &IMBIB_COLLECTION).expect("imbib tree");
    assert_eq!(publications.len(), 1);
    assert_eq!(publications[0].id, reading);
    assert_eq!(publications[0].name, "Reading");

    let manuscripts =
        collection_ops::list_tree(&kernel, &MANUSCRIPT_COLLECTION).expect("manuscript tree");
    assert_eq!(manuscripts.len(), 1);
    assert_eq!(manuscripts[0].id, folder);
    assert_eq!(manuscripts[0].name, "Drafts");

    collection_ops::rename(&kernel, &IMBIB_COLLECTION, &reading, "Renamed")
        .expect("the kernel renames a migrated row happily");

    // ── Rolling back gives the legacy readers their rows back. ──
    collection_migration::rollback_collections(&kernel).expect("rollback");
    let rows = imbib.list_collections(library).expect("list collections");
    assert_eq!(rows.len(), 1, "the legacy reader can see again");
    assert_eq!(
        rows[0].name, "Reading",
        "and the rollback is a REWIND, not a merge: the rename made while \
         migrated is discarded with the migration. Byte fidelity is what makes \
         the drill auditable; the cost is that `rollback` is a same-session \
         escape hatch, not a late undo."
    );
    assert_eq!(imbib.list_manuscript_collections().unwrap().len(), 1);
}
