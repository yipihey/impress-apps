//! ADR-0022 WP G7: what the collection migration COSTS the legacy readers —
//! and, since F2, what it no longer costs.
//!
//! `impress_core::collection_migration` rewrites `imbib/collection` and
//! `manuscript-collection` rows onto `collection@1.0.0`. The kernel
//! (`collection_ops`, and therefore `impress_store_ffi::SharedStore::collection_*`
//! and `CollectionStoreAdapter` in Swift) reads correctly on both sides of that
//! flip, because it consults the `collections.unified` marker.
//!
//! imbib-core's exports used to be uniformly blind: they queried the legacy
//! `schema_ref` literals directly, so after a migration they returned EMPTY —
//! and `rename_collection`, whose schema guard ran before the write, returned
//! `NotFound` outright. **F2 converted four of them** to go through the kernel
//! (`collections_containing`, `create_in_with_payload`,
//! `ResolvedBinding::matches`), so this file now has two halves:
//!
//! | export | post-flip | asserted by |
//! |---|---|---|
//! | `list_collections_for_publication` | ✅ correct | `the_f2_exports_stay_correct_across_the_flip` |
//! | `get_publication_detail` (`.collections`) | ✅ correct | same |
//! | `rename_collection` | ✅ correct | same |
//! | `create_collection` | ✅ correct, and byte-compatible with a migrated row | `create_collection_writes_a_row_a_migration_would_have_produced` |
//! | `list_collections(library_id)` | ❌ EMPTY | `migration_blinds_the_remaining_legacy_readers` |
//! | `list_manuscript_collections` | ❌ EMPTY | same |
//! | `count_collections` | ❌ 0 | same |
//! | `delete_library_undoable` | ❌ snapshot omits the library's collections | same |
//! | `get_manuscript_detail` (`.collections`) | ❌ EMPTY | same |
//!
//! The second half is asserted ON PURPOSE. It is not a bug report; it is the
//! residue the flip-readiness verdict is written against, and the day someone
//! fixes one of those exports this file is where the assertion flips.
//!
//! `list_collections` is the interesting one: it is still blind HERE, but no
//! longer reached from imbib's sidebar, because F1 rerouted
//! `RustStoreAdapter.listCollections(libraryId:)` onto the kernel's
//! `collectionTreeIn`. Blindness of the Rust export and reachability from Swift
//! are two different questions, and the audit answers both.

#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_core::collection_migration;
use impress_core::collection_ops::{self, IMBIB_COLLECTION, MANUSCRIPT_COLLECTION};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;

fn temp_db() -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir
        .path()
        .join("impress.sqlite")
        .to_string_lossy()
        .to_string();
    (dir, path)
}

/// Migrate on a SECOND handle over the same file — the suite's real WAL
/// topology, and the only way to prove the `ImbibStore` handle picks the marker
/// up without being reopened.
fn migrate(path: &str) -> SqliteItemStore {
    let kernel = SqliteItemStore::open(std::path::Path::new(path)).expect("open kernel handle");
    assert!(!collection_migration::is_migrated(&kernel).unwrap());
    collection_migration::migrate_collections(&kernel, false).expect("migrate");
    assert!(collection_migration::is_migrated(&kernel).unwrap());
    kernel
}

#[test]
fn migration_blinds_the_remaining_legacy_readers() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");

    // A realistic legacy tree, written through imbib-core's own API — the exact
    // rows a shipping database holds today.
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
    assert_eq!(imbib.count_collections().unwrap(), 1);

    let kernel = migrate(&path);

    // ── The expected regression. THIS is the residue behind the verdict. ──
    assert!(
        imbib.list_collections(library.clone()).unwrap().is_empty(),
        "EXPECTED: list_collections queries schema_ref = 'imbib/collection' \
         directly and cannot see a migrated row. Harmless in imbib since F1 \
         rerouted RustStoreAdapter through the kernel — but the EXPORT is still \
         blind, so anything reaching it directly is not."
    );
    assert!(
        imbib.list_manuscript_collections().unwrap().is_empty(),
        "EXPECTED: list_manuscript_collections is blind the same way — and it \
         is the ONLY reader behind ImbibSidebarViewModel.manuscriptFolderNodes(), \
         whose writes already go through the kernel."
    );
    assert_eq!(
        imbib.count_collections().unwrap(),
        0,
        "EXPECTED: counts rows by the legacy schema_ref, so /api/status reports 0"
    );

    // `delete_library_undoable` is the DANGEROUS one: it does not fail, it
    // snapshots an incomplete truth. Its collection walk is the same blind
    // query, so undoing a library delete would re-parent the publications and
    // leave every collection orphaned.
    let snapshot = imbib
        .delete_library_undoable(library.clone())
        .expect("delete library");
    assert!(
        snapshot.child_collection_ids.is_empty(),
        "EXPECTED: the undo snapshot silently omits the library's collections"
    );
    imbib.restore_library(snapshot).expect("restore");
    assert_eq!(
        collection_ops::list_tree_in(&kernel, &IMBIB_COLLECTION, Some(&library))
            .unwrap()
            .len(),
        0,
        "EXPECTED: and the restore leaves the collection orphaned — the kernel \
         cannot find it in the library any more either, because the envelope \
         parent the FK cleared was never put back"
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
}

/// The F2 half: the four exports that now resolve the marker. Every assertion
/// here was an "EXPECTED: goes blind" assertion before F2, and each one is a
/// Swift surface that would have regressed at the flip —
/// `PublicationListMutations.removeFromAllCollections`, `FirstSyncMerge`, the
/// iOS rename sheets, `EverythingExporter`'s `X-Imbib-Collections` header, and
/// every collection anyone creates afterwards.
#[test]
fn the_f2_exports_stay_correct_across_the_flip() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");

    let library = imbib.create_library("Main".into()).unwrap().id;
    let reading = imbib
        .create_collection("Reading".into(), library.clone(), false, None)
        .unwrap()
        .id;
    let starred = imbib
        .create_collection("Starred".into(), library.clone(), true, Some("s:1".into()))
        .unwrap()
        .id;
    let pub_id = imbib
        .import_bibtex("@article{X, title={Test}}".into(), library.clone())
        .unwrap()
        .remove(0);
    imbib
        .add_to_collection(vec![pub_id.clone()], reading.clone())
        .unwrap();
    imbib
        .add_to_collection(vec![pub_id.clone()], starred.clone())
        .unwrap();

    let before = imbib
        .list_collections_for_publication(pub_id.clone())
        .unwrap();
    let before_detail = imbib
        .get_publication_detail(pub_id.clone())
        .unwrap()
        .expect("detail")
        .collections;
    assert_eq!(before.len(), 2, "precondition");
    assert_eq!(before_detail.len(), 2, "precondition");

    let kernel = migrate(&path);

    // 1 — list_collections_for_publication: identical rows, counts included.
    let after = imbib
        .list_collections_for_publication(pub_id.clone())
        .unwrap();
    assert_eq!(
        after.len(),
        2,
        "membership survives the flip and is READABLE"
    );
    assert_eq!(
        after.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
        before.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
    );
    assert_eq!(
        after
            .iter()
            .map(|c| c.publication_count)
            .collect::<Vec<_>>(),
        before
            .iter()
            .map(|c| c.publication_count)
            .collect::<Vec<_>>(),
        "the badge count is the outgoing Contains-edge count on both sides"
    );
    assert!(
        after.iter().any(|c| c.id == starred && c.is_smart),
        "and is_smart still rides on the row — the migration keeps it canonical"
    );

    // 2 — get_publication_detail's .collections projection, the same query in
    //     its id-only shape. EverythingExporter writes these into the archive.
    let after_detail = imbib
        .get_publication_detail(pub_id.clone())
        .unwrap()
        .expect("detail")
        .collections;
    assert_eq!(
        after_detail, before_detail,
        "the exported X-Imbib-Collections header is byte-identical across the flip"
    );

    // 3 — rename_collection: the guard is marker-aware, the write stays on the
    //     store op log (imbib's ⌘Z path is unchanged).
    let renamed = imbib
        .rename_collection(reading.clone(), "Renamed".into())
        .expect("the marker-aware guard admits a migrated row");
    assert_eq!(renamed.name, "Renamed");
    assert_eq!(
        renamed.publication_count, 1,
        "and the returned row still counts its members"
    );
    assert_eq!(
        collection_ops::list_tree_in(&kernel, &IMBIB_COLLECTION, Some(&library))
            .unwrap()
            .iter()
            .find(|r| r.id == reading)
            .map(|r| r.name.clone()),
        Some("Renamed".into()),
        "the kernel sees the rename — one tree, one writer"
    );
    // The guard still discriminates: a non-collection is still NotFound.
    assert!(
        imbib
            .rename_collection(pub_id.clone(), "Nope".into())
            .is_err(),
        "a publication is not a collection, marker or no marker"
    );

    // 4 — create_collection: the new row is visible to the kernel, to the
    //     reverse-membership read, and to the migration's own status counters.
    let fresh = imbib
        .create_collection("Post-flip".into(), library.clone(), false, None)
        .expect("create after the flip");
    imbib
        .add_to_collection(vec![pub_id.clone()], fresh.id.clone())
        .unwrap();
    assert!(
        collection_ops::list_tree_in(&kernel, &IMBIB_COLLECTION, Some(&library))
            .unwrap()
            .iter()
            .any(|r| r.id == fresh.id),
        "a post-flip creation is NOT a second writer to a tree the kernel \
         cannot see — that was the two-writers hazard"
    );
    assert!(
        imbib
            .list_collections_for_publication(pub_id)
            .unwrap()
            .iter()
            .any(|c| c.id == fresh.id),
        "and it is reachable through the F2 read path immediately"
    );
    let status = collection_migration::migration_status(&kernel).unwrap();
    assert_eq!(
        status.legacy_total(),
        0,
        "nothing was written back under a legacy schema_ref"
    );
}

/// The write-shape proof, end to end through the shipping export: a collection
/// created BEFORE the flip and then migrated is the same row as one created
/// AFTER it. If those two ever diverge the store has two spellings of one kind,
/// and whichever reader runs first decides which of a user's collections exist.
///
/// (The kernel-level half of this proof, including the payload comparison and
/// the rollback's treatment of a natively-created row, is
/// `impress-core/tests/collection_container_axis.rs`
/// `a_created_collection_is_indistinguishable_from_a_migrated_one`.)
#[test]
fn create_collection_writes_a_row_a_migration_would_have_produced() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");
    let library = imbib.create_library("Main".into()).unwrap().id;

    let before = imbib
        .create_collection("Starred".into(), library.clone(), true, Some("s:1".into()))
        .expect("create pre-flip");

    let kernel = migrate(&path);

    let after = imbib
        .create_collection("Starred".into(), library.clone(), true, Some("s:1".into()))
        .expect("create post-flip");

    // The imbib row shape both callers get back: everything but the id.
    assert_eq!(
        (
            before.name.clone(),
            before.parent_id.clone(),
            before.is_smart,
            before.sort_order,
            before.publication_count
        ),
        (
            after.name.clone(),
            after.parent_id.clone(),
            after.is_smart,
            after.sort_order,
            after.publication_count
        ),
        "create_collection returns the same row before and after the flip"
    );

    // And the two STORED rows agree once the migration has caught the first up.
    let rows = collection_ops::list_tree_in(&kernel, &IMBIB_COLLECTION, Some(&library)).unwrap();
    let migrated = rows.iter().find(|r| r.id == before.id).expect("migrated");
    let native = rows.iter().find(|r| r.id == after.id).expect("native");
    assert_eq!(
        collection_ops::CollectionRow {
            id: migrated.id.clone(),
            ..native.clone()
        },
        *migrated,
        "migrated and natively-created rows are indistinguishable to the kernel"
    );

    for id in [&before.id, &after.id] {
        let item = kernel
            .get(uuid::Uuid::parse_str(id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(item.schema, "collection", "both on the generic schema");
        assert_eq!(
            item.parent.map(|p| p.to_string()),
            Some(library.clone()),
            "both still filed under the owning library — the envelope is the \
             axis the migration cannot touch"
        );
    }
}
