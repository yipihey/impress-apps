//! ADR-0022 WP G7: what the collection migration costs the legacy readers —
//! and, since F3, what it costs is **nothing**.
//!
//! `impress_core::collection_migration` rewrites `imbib/collection`,
//! `manuscript-collection` and `figure-collection` rows onto
//! `collection@1.0.0`. The kernel (`collection_ops`, and therefore
//! `impress_store_ffi::SharedStore::collection_*` and `CollectionStoreAdapter`
//! in Swift) reads correctly on both sides of that flip, because it consults
//! the `collections.unified` marker.
//!
//! imbib-core's exports used to be uniformly blind: they queried the legacy
//! `schema_ref` literals directly, so after a migration they returned EMPTY —
//! and `rename_collection`, whose schema guard ran before the write, returned
//! `NotFound` outright. **F2 converted four**, **F3 converted the rest**, so
//! this file changed character a second time. It was:
//!
//! 1. "the legacy readers go blind, and that is why the flag is off" (G7),
//! 2. two halves — a stays-correct half for F2's four, a still-blind half for
//!    the residue (F2),
//!
//! and it is now **one half**: every collection export in imbib-core answers
//! identically on both sides of the flip, and the file that used to hold the
//! blindness assertions holds the all-clear instead.
//!
//! | export | post-flip | asserted by |
//! |---|---|---|
//! | `list_collections(library_id)` | ✅ identical rows, order and counts | `every_collection_export_answers_identically_across_the_flip` |
//! | `count_collections` | ✅ same total | same |
//! | `list_manuscript_collections` | ✅ identical rows, incl. `is_workspace` | same |
//! | `get_manuscript_detail` (`.collections`) | ✅ correct | same |
//! | `delete_library_undoable` → `restore_library` | ✅ round-trips a library WITH its collections | `deleting_and_undoing_a_library_keeps_its_collections` |
//! | `list_collections_for_publication` | ✅ correct | `the_f2_exports_stay_correct_across_the_flip` |
//! | `get_publication_detail` (`.collections`) | ✅ correct | same |
//! | `rename_collection` | ✅ correct | same |
//! | `create_collection` | ✅ correct, byte-compatible with a migrated row | `create_collection_writes_a_row_a_migration_would_have_produced` |
//!
//! Two exports are absent because they no longer exist:
//! `create_manuscript_collection` was the last legacy manuscript-folder WRITER
//! and had zero callers (F3 deleted it, and its Swift wrapper, in favour of
//! `CollectionStoreAdapter.create`); `get_manuscript_detail`'s blind
//! `.collections` query was replaced by `collections_containing` in F2.
//!
//! The oracle for "identically" is deliberately the SAME store, read twice:
//! seed through the real writers, snapshot every export, migrate on a second
//! WAL handle, snapshot again, compare. A per-export expected value would only
//! prove the test's arithmetic.

#![cfg(feature = "native")]

use imbib_core::unified::store_api::ImbibStore;
use impress_core::collection_migration;
use impress_core::collection_ops::{self, IMBIB_COLLECTION, MANUSCRIPT_COLLECTION};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;
use impress_store_ffi::{SharedCollectionBinding, SharedStore};

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

/// One `CollectionRow` as `list_collections` returns it, flattened so a
/// snapshot can be compared with `==`: `(id, name, parent_id, is_smart,
/// publication_count, sort_order)`.
type CollectionFacts = (String, String, Option<String>, bool, i32, i32);

/// One `ManuscriptCollectionRow`, likewise: `(id, name, parent_id, sort_order,
/// is_smart, is_workspace, manuscript_count)`.
type ManuscriptFolderFacts = (String, String, Option<String>, i32, bool, bool, i32);

/// An answer keyed by the id it was asked about, so a mismatch names its row.
type PerId<T> = Vec<(String, T)>;

/// Every collection fact a caller can read out of `ImbibStore`, in one
/// comparable value. Built from the SHIPPING exports, not from the kernel, so
/// what is compared is what a consumer sees.
#[derive(Debug, PartialEq)]
struct ExportSnapshot {
    /// Per library, in the order `list_collections` returned them.
    collections: PerId<Vec<CollectionFacts>>,
    total: u32,
    /// In `list_manuscript_collections` order.
    manuscript_folders: Vec<ManuscriptFolderFacts>,
    /// `list_collections_for_publication` per publication.
    per_publication: PerId<Vec<(String, i32)>>,
    /// `get_publication_detail(...).collections` per publication.
    detail_collections: PerId<Vec<String>>,
    /// `get_manuscript_detail(...).collections` per manuscript.
    manuscript_detail_collections: PerId<Vec<String>>,
}

fn snapshot(
    imbib: &ImbibStore,
    libraries: &[String],
    pubs: &[String],
    mss: &[String],
) -> ExportSnapshot {
    ExportSnapshot {
        collections: libraries
            .iter()
            .map(|lib| {
                let rows = imbib
                    .list_collections(lib.clone())
                    .expect("list_collections")
                    .into_iter()
                    .map(|r| {
                        (
                            r.id,
                            r.name,
                            r.parent_id,
                            r.is_smart,
                            r.publication_count,
                            r.sort_order,
                        )
                    })
                    .collect();
                (lib.clone(), rows)
            })
            .collect(),
        total: imbib.count_collections().expect("count_collections"),
        manuscript_folders: imbib
            .list_manuscript_collections()
            .expect("list_manuscript_collections")
            .into_iter()
            .map(|r| {
                (
                    r.id,
                    r.name,
                    r.parent_id,
                    r.sort_order,
                    r.is_smart,
                    r.is_workspace,
                    r.manuscript_count,
                )
            })
            .collect(),
        per_publication: pubs
            .iter()
            .map(|id| {
                (
                    id.clone(),
                    imbib
                        .list_collections_for_publication(id.clone())
                        .expect("list_collections_for_publication")
                        .into_iter()
                        .map(|c| (c.id, c.publication_count))
                        .collect(),
                )
            })
            .collect(),
        detail_collections: pubs
            .iter()
            .map(|id| {
                (
                    id.clone(),
                    imbib
                        .get_publication_detail(id.clone())
                        .expect("get_publication_detail")
                        .expect("detail")
                        .collections,
                )
            })
            .collect(),
        manuscript_detail_collections: mss
            .iter()
            .map(|id| {
                (
                    id.clone(),
                    imbib
                        .get_manuscript_detail(id.clone())
                        .expect("get_manuscript_detail")
                        .expect("detail")
                        .collections,
                )
            })
            .collect(),
    }
}

/// The seeded world: all three legacy collection kinds, nested, with members.
struct Seeded {
    libraries: Vec<String>,
    publications: Vec<String>,
    manuscripts: Vec<String>,
    workspace: String,
    figure_folder: String,
}

/// Seed a store through the REAL writers.
///
/// Publication collections through `ImbibStore::create_collection` (imbib's
/// shipping export), manuscript and figure folders through the kernel on a
/// second `SharedStore` handle — which is exactly how the shipping apps write
/// them (`ManuscriptStoreAdapter.createCollection` /
/// `CollectionStoreAdapter.create`), and the only writers left for those two
/// kinds now that F3 deleted `create_manuscript_collection`. `is_workspace`
/// rides on as the additive follow-up field imprint writes.
fn seed(imbib: &ImbibStore, path: &str) -> Seeded {
    let shared = SharedStore::open(path.to_string()).expect("open SharedStore");

    // ── Publication collections: two libraries, one nested tree, one smart. ──
    let main = imbib.create_library("Main".into()).unwrap().id;
    let side = imbib.create_library("Side".into()).unwrap().id;

    let reading = imbib
        .create_collection("Reading".into(), main.clone(), false, None)
        .unwrap()
        .id;
    let subcollection = imbib
        .create_collection("Reionization".into(), main.clone(), false, None)
        .unwrap()
        .id;
    imbib
        .update_field(
            subcollection.clone(),
            "parent_id".into(),
            Some(reading.clone()),
        )
        .expect("nest the publication collection");
    let starred = imbib
        .create_collection("Starred".into(), main.clone(), true, Some("s:1".into()))
        .unwrap()
        .id;
    let elsewhere = imbib
        .create_collection("Elsewhere".into(), side.clone(), false, None)
        .unwrap()
        .id;

    let paper_a = imbib
        .import_bibtex("@article{A, title={Alpha}}".into(), main.clone())
        .unwrap()
        .remove(0);
    let paper_b = imbib
        .import_bibtex("@article{B, title={Beta}}".into(), main.clone())
        .unwrap()
        .remove(0);
    imbib
        .add_to_collection(vec![paper_a.clone(), paper_b.clone()], reading.clone())
        .unwrap();
    imbib
        .add_to_collection(vec![paper_a.clone()], subcollection)
        .unwrap();
    imbib
        .add_to_collection(vec![paper_b.clone()], starred)
        .unwrap();
    imbib
        .add_to_collection(vec![paper_a.clone()], elsewhere)
        .unwrap();

    // ── Manuscript folders: a workspace with a nested child, two members. ──
    let workspace = shared
        .collection_create(
            SharedCollectionBinding::Manuscript,
            "Workspace".into(),
            None,
            None,
            Some(0),
        )
        .expect("workspace")
        .id;
    // imprint's `is_workspace` — not a kernel concept, written as an additive
    // follow-up field on whatever schema the kernel just wrote
    // (`ManuscriptStoreAdapter.createCollection` does exactly this).
    let workspace_schema = shared
        .get_item(workspace.clone())
        .expect("get workspace")
        .expect("workspace row")
        .schema_ref;
    shared
        .upsert_item_v2(impress_store_ffi::SharedItemUpsert {
            id: workspace.clone(),
            schema_ref: workspace_schema,
            payload_json: r#"{"is_workspace":true}"#.into(),
            parent_id: None,
            tags: vec![],
            created_ms: None,
            is_read: None,
            is_starred: None,
        })
        .expect("stamp is_workspace");
    let drafts = shared
        .collection_create(
            SharedCollectionBinding::Manuscript,
            "Drafts".into(),
            Some(workspace.clone()),
            None,
            Some(1),
        )
        .expect("drafts")
        .id;

    let ms_a = imbib
        .create_manuscript("Alpha".into(), "typst".into(), "".into(), vec![])
        .unwrap()
        .id;
    let ms_b = imbib
        .create_manuscript("Beta".into(), "typst".into(), "".into(), vec![])
        .unwrap()
        .id;
    imbib
        .add_to_collection(vec![ms_a.clone(), ms_b.clone()], drafts)
        .unwrap();

    // ── Figure folders: envelope-nested, envelope-filed members. ──
    let figures = shared
        .collection_create(
            SharedCollectionBinding::Figure,
            "Figures".into(),
            None,
            None,
            Some(0),
        )
        .expect("figure folder")
        .id;
    let panels = shared
        .collection_create(
            SharedCollectionBinding::Figure,
            "Panels".into(),
            Some(figures.clone()),
            None,
            Some(1),
        )
        .expect("nested figure folder")
        .id;
    let figure_id = uuid::Uuid::new_v4().to_string();
    shared
        .upsert_item_v2(impress_store_ffi::SharedItemUpsert {
            id: figure_id,
            schema_ref: "figure".into(),
            payload_json: r#"{"title":"Panel A","format":"png"}"#.into(),
            parent_id: Some(panels),
            tags: vec![],
            created_ms: None,
            is_read: None,
            is_starred: None,
        })
        .expect("file a figure");

    Seeded {
        libraries: vec![main, side],
        publications: vec![paper_a, paper_b],
        manuscripts: vec![ms_a, ms_b],
        workspace,
        figure_folder: figures,
    }
}

/// **The all-clear.** Every collection export in imbib-core, snapshotted
/// before and after a real migration on a store seeded through the real
/// writers, with all three legacy kinds, nesting and membership present.
///
/// This assertion is the exact inverse of the one this file carried until F3
/// (`migration_blinds_the_remaining_legacy_readers`). Each line of the snapshot
/// was a documented regression: an emptied sidebar, a zeroed `/api/status`, an
/// agent seeing an empty library, imprint's folder tree vanishing.
#[test]
fn every_collection_export_answers_identically_across_the_flip() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");
    let seeded = seed(&imbib, &path);

    let before = snapshot(
        &imbib,
        &seeded.libraries,
        &seeded.publications,
        &seeded.manuscripts,
    );

    // Preconditions, so a snapshot of two empty vectors can never pass.
    assert_eq!(
        before.collections[0].1.len(),
        3,
        "Main has three collections"
    );
    assert_eq!(before.collections[1].1.len(), 1, "Side has one");
    assert_eq!(before.total, 4);
    assert_eq!(before.manuscript_folders.len(), 2);
    assert!(
        before.manuscript_folders.iter().any(|f| f.5),
        "one of them is imprint's workspace"
    );
    assert!(before.per_publication.iter().all(|(_, cs)| !cs.is_empty()));
    assert!(before
        .manuscript_detail_collections
        .iter()
        .any(|(_, cs)| !cs.is_empty()));

    let kernel = migrate(&path);

    let after = snapshot(
        &imbib,
        &seeded.libraries,
        &seeded.publications,
        &seeded.manuscripts,
    );
    assert_eq!(
        before, after,
        "every imbib-core collection export answers identically on both sides \
         of the collections.unified flip — rows, ORDER, parents, smart flags, \
         member counts, the workspace flag, and the reverse-membership \
         projections"
    );

    // And the migration really did happen: nothing is left under a legacy
    // schema_ref, so `before == after` is invariance, not a no-op.
    let status = collection_migration::migration_status(&kernel).unwrap();
    assert_eq!(status.legacy_total(), 0, "all three kinds converged");
    assert_eq!(
        status.generic_total(),
        4 + 2 + 2,
        "pubs + folders + figures"
    );

    // The workspace flag specifically: the migration files `is_workspace` into
    // the `legacy` extras bag, so reading it back is a fallback, not a field.
    // Without it the flip would silently demote every migrated workspace.
    assert!(
        after
            .manuscript_folders
            .iter()
            .any(|f| f.0 == seeded.workspace && f.5),
        "a migrated workspace is still a workspace"
    );

    // The figure binding has no imbib-core export at all — it is read by
    // implore and the chassis through `CollectionStoreAdapter` — so its
    // invariance is asserted on the kernel it actually goes through.
    let figure_tree =
        collection_ops::list_tree(&kernel, &collection_ops::FIGURE_COLLECTION).expect("figures");
    assert_eq!(figure_tree.len(), 2);
    assert_eq!(figure_tree[0].id, seeded.figure_folder);
    assert_eq!(
        figure_tree[1].parent_id.as_deref(),
        Some(seeded.figure_folder.as_str()),
        "envelope nesting survives as payload nesting"
    );
    assert_eq!(
        figure_tree[1].member_count, 1,
        "and the filed figure with it"
    );
}

/// `delete_library_undoable` → `restore_library`, the one residue item that
/// lost DATA rather than a display.
///
/// Its child-collection walk was a `schema_ref = "imbib/collection"` query, so
/// post-flip the snapshot came back empty while the delete orphaned the
/// collections anyway (`ON DELETE SET NULL` on the envelope parent). Undo then
/// restored the library and its publications and left every collection filed
/// under nothing — present in the database, invisible to every per-library read
/// in the suite, with a working "Undo Delete Library" entry in the Edit menu.
///
/// This test asserted that loss until F3. It now asserts the round trip, and it
/// runs the SAME sequence on both sides of the flip so the pre-flip behaviour is
/// pinned as well.
#[test]
fn deleting_and_undoing_a_library_keeps_its_collections() {
    for migrated in [false, true] {
        let (_dir, path) = temp_db();
        let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");

        let library = imbib.create_library("Main".into()).unwrap().id;
        let root = imbib
            .create_collection("Reading".into(), library.clone(), false, None)
            .unwrap()
            .id;
        let nested = imbib
            .create_collection("Reionization".into(), library.clone(), false, None)
            .unwrap()
            .id;
        imbib
            .update_field(nested.clone(), "parent_id".into(), Some(root.clone()))
            .expect("nest");
        let paper = imbib
            .import_bibtex("@article{A, title={Alpha}}".into(), library.clone())
            .unwrap()
            .remove(0);
        imbib
            .add_to_collection(vec![paper.clone()], nested.clone())
            .unwrap();

        let kernel = if migrated { Some(migrate(&path)) } else { None };

        let before = imbib.list_collections(library.clone()).unwrap();
        assert_eq!(before.len(), 2, "precondition (migrated = {migrated})");

        let snapshot = imbib
            .delete_library_undoable(library.clone())
            .expect("delete library");
        assert_eq!(
            snapshot.child_collection_ids.len(),
            2,
            "the undo snapshot names BOTH collections — the root and the nested \
             one, which carries the same owning library on its envelope \
             (migrated = {migrated})"
        );
        assert_eq!(snapshot.child_publication_ids.len(), 1);

        imbib.restore_library(snapshot).expect("restore");

        let after = imbib.list_collections(library.clone()).unwrap();
        assert_eq!(
            after.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            before.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
            "delete → undo round-trips a library WITH its collections \
             (migrated = {migrated})"
        );
        assert_eq!(
            after
                .iter()
                .map(|r| (r.parent_id.clone(), r.publication_count))
                .collect::<Vec<_>>(),
            before
                .iter()
                .map(|r| (r.parent_id.clone(), r.publication_count))
                .collect::<Vec<_>>(),
            "nesting and membership come back too (migrated = {migrated})"
        );

        // The kernel agrees, on the handle that did the migration.
        if let Some(kernel) = kernel {
            assert_eq!(
                collection_ops::list_tree_in(&kernel, &IMBIB_COLLECTION, Some(&library))
                    .unwrap()
                    .len(),
                2,
                "and the collections are back IN the library, not merely alive"
            );
        }
    }
}

/// The F2 half: the four exports that first learned to resolve the marker.
/// Every assertion here was an "EXPECTED: goes blind" assertion before F2, and
/// each one is a Swift surface that would have regressed at the flip —
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
    // F3: the legacy tree read sees it too, which is what makes the sidebar's
    // fallback path and the agent surface safe.
    assert!(
        imbib
            .list_collections(library.clone())
            .unwrap()
            .iter()
            .any(|r| r.id == fresh.id),
        "and through list_collections, the export imbib-service reads"
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

/// **The flip drill, on the F3-touched paths.** Dry run → compare → migrate →
/// rollback, on a store seeded through the real writers with all three legacy
/// kinds, nesting and membership.
///
/// G7 proved this at the kernel level (`collection_migration`'s own test
/// module). What it could not prove is the half F3 is about: that the drill is
/// invisible to the EXPORTS a user's app and agents read through. So this runs
/// the same three commands the flip procedure names and snapshots imbib-core's
/// whole collection surface at each step.
///
/// The dry run is the load-bearing one. It is the same code path as the real
/// run — the plan is computed once and only APPLIED when `dry_run` is false —
/// so its counts are evidence about the real run rather than about a parallel
/// implementation of it. This asserts both halves of that claim: the numbers
/// match the real run's, and the store is untouched (marker off, every export
/// answering exactly as before, not one row rewritten).
#[test]
fn the_dry_run_rehearses_the_flip_and_rollback_rewinds_it() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");
    let seeded = seed(&imbib, &path);
    let kernel = SqliteItemStore::open(std::path::Path::new(&path)).expect("kernel handle");

    let baseline = snapshot(
        &imbib,
        &seeded.libraries,
        &seeded.publications,
        &seeded.manuscripts,
    );

    // ── 1. migration_status — read-only, always safe. ──
    let status = collection_migration::migration_status(&kernel).unwrap();
    assert!(!status.migrated, "the marker ships OFF");
    assert_eq!(
        status.legacy_total(),
        8,
        "4 publication + 2 manuscript + 2 figure"
    );
    assert_eq!(status.generic_total(), 0);

    // ── 2. migrate(dry_run: true) — writes NOTHING, reports everything. ──
    let dry = collection_migration::migrate_collections(&kernel, true).expect("dry run");
    assert!(dry.dry_run);
    assert!(!dry.was_migrated);
    assert_eq!(dry.found(), 8);
    assert_eq!(
        dry.rewritten(),
        8,
        "a dry run reports what it WOULD rewrite"
    );
    assert_eq!(
        dry.bindings
            .iter()
            .map(|b| (
                b.schema_ref,
                b.kind_scope,
                b.found,
                b.skipped_already_generic
            ))
            .collect::<Vec<_>>(),
        vec![
            ("imbib/collection", "publication", 4, 0),
            ("manuscript-collection", "manuscript", 2, 0),
            ("figure-collection", "figure", 2, 0),
        ],
        "one line per legacy binding, in MIGRATED_BINDINGS order"
    );
    assert!(dry.membership_edges_untouched);

    assert!(
        !collection_migration::is_migrated(&kernel).unwrap(),
        "a dry run does not set the marker"
    );
    assert_eq!(
        collection_migration::migration_status(&kernel).unwrap(),
        status,
        "nor rewrite a single row"
    );
    assert_eq!(
        snapshot(
            &imbib,
            &seeded.libraries,
            &seeded.publications,
            &seeded.manuscripts
        ),
        baseline,
        "and every export still answers exactly as it did"
    );

    // ── 3. migrate(dry_run: false) — the same plan, applied. ──
    let real = collection_migration::migrate_collections(&kernel, false).expect("migrate");
    assert_eq!(
        (real.found(), real.rewritten()),
        (dry.found(), dry.rewritten()),
        "the dry run's counts were the real run's counts"
    );
    assert_eq!(
        real.bindings
            .iter()
            .map(|b| (b.schema_ref, b.found, b.rewritten))
            .collect::<Vec<_>>(),
        dry.bindings
            .iter()
            .map(|b| (b.schema_ref, b.found, b.rewritten))
            .collect::<Vec<_>>(),
        "line for line"
    );
    assert!(collection_migration::is_migrated(&kernel).unwrap());
    assert_eq!(
        snapshot(
            &imbib,
            &seeded.libraries,
            &seeded.publications,
            &seeded.manuscripts
        ),
        baseline,
        "and the exports are invariant across the real run too — this is the \
         F3 claim, made against the drill rather than against a bare migrate"
    );

    // A second run is idempotent and legible about it.
    let again = collection_migration::migrate_collections(&kernel, false).expect("re-migrate");
    assert_eq!(again.found(), 0);
    assert_eq!(
        again
            .bindings
            .iter()
            .map(|b| b.skipped_already_generic)
            .collect::<Vec<_>>(),
        vec![4, 2, 2],
        "zero rewritten, and it says WHY: they are already generic"
    );

    // ── 4. rollback() — a rewind. ──
    let back = collection_migration::rollback_collections(&kernel).expect("rollback");
    assert_eq!(back.restored(), 8);
    assert_eq!(
        back.native_generic_untouched, 0,
        "nothing was created post-flip"
    );
    assert!(!collection_migration::is_migrated(&kernel).unwrap());
    assert_eq!(
        collection_migration::migration_status(&kernel).unwrap(),
        status,
        "the store is byte-for-byte where migration_status found it"
    );
    assert_eq!(
        snapshot(
            &imbib,
            &seeded.libraries,
            &seeded.publications,
            &seeded.manuscripts
        ),
        baseline,
        "and the exports never noticed any of it"
    );
}

/// The imprint re-migration probe, at the level Rust can prove it.
///
/// `ManuscriptMigrationRunner.shouldReRunDueToEmptyStore()` (Swift, imprint)
/// asks one question — "has the migration's output vanished?" — and its answer
/// decides whether imprint re-imports the ENTIRE Core Data project hierarchy.
/// It used to ask it as `queryBySchema(schemaRef: "manuscript-collection")`, so
/// post-flip a fully populated store answered "yes, vanished" and every
/// workspace and folder the user had appeared twice. It now asks
/// `ManuscriptStoreAdapter.listCollections()`, which is
/// `CollectionStoreAdapter.tree(.manuscript)` → `SharedStore.collection_tree`
/// → `collection_ops::list_tree(MANUSCRIPT_COLLECTION)`.
///
/// The runner needs a Core Data stack and a `@MainActor` app context, so it has
/// no headless XCTest. This is the trace, pinned at its load-bearing joint: the
/// exact query the probe now runs, answering non-empty across the flip, next to
/// the exact query it used to run, answering empty. Both halves matter — the
/// second is what makes this a regression test rather than a tautology.
#[test]
fn the_imprint_re_migration_probe_is_marker_aware() {
    let (_dir, path) = temp_db();
    let imbib = ImbibStore::open(path.clone()).expect("open ImbibStore");
    let shared = SharedStore::open(path.clone()).expect("open SharedStore");

    shared
        .collection_create(
            SharedCollectionBinding::Manuscript,
            "Workspace".into(),
            None,
            None,
            Some(0),
        )
        .expect("the migration's output");
    let _ = &imbib;

    let kernel = migrate(&path);

    // The probe's query, post-flip. Non-empty ⇒ `shouldReRunDueToEmptyStore`
    // returns false ⇒ no re-migration ⇒ no duplicated folders.
    assert!(
        !collection_ops::list_tree(&kernel, &MANUSCRIPT_COLLECTION)
            .unwrap()
            .is_empty(),
        "the kernel tree the probe reads still sees the migration's output"
    );

    // The query it replaced, post-flip. Empty ⇒ the old probe would have
    // re-run the whole Core Data import.
    let legacy = kernel
        .query(&impress_core::query::ItemQuery {
            schema: Some("manuscript-collection".into()),
            ..Default::default()
        })
        .unwrap();
    assert!(
        legacy.is_empty(),
        "and the schema-literal query it replaced is exactly as blind as the \
         audit said — this is the failure the probe no longer has"
    );
}
