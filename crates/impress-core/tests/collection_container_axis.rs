//! ADR-0022 C2: the collection kernel's optional axes, end-to-end.
//!
//! The fine-grained unit tests for these axes live next to the code, in
//! `collection_ops`'s own `#[cfg(test)]` module. This file is the INTEGRATION
//! half, and it exists for two reasons that are both about the flip:
//!
//! 1. It runs the axes against a real on-disk store across
//!    `collection_migration::migrate_collections`, which is the property the
//!    whole C2 design rests on — **the container axis is the one axis WP G7
//!    cannot disturb.** The migration rewrites `schema_ref` and the payload and
//!    never touches the envelope, so a container read or write is byte-identical
//!    on both sides of `collections.unified`. That is what makes
//!    `list_tree_in` a safe replacement for imbib-core's
//!    `list_collections(library_id)`, which goes blind at the flip
//!    (`imbib-core/tests/collection_migration_legacy_readers.rs`).
//!
//! 2. It is a separate compilation target, so it keeps proving the kernel while
//!    the `impress-core` lib-test target is red for reasons that have nothing to
//!    do with collections.
//!
//! Every assertion below pairs the binding that DECLARES an axis with one that
//! declines it. "The axis works" is only half the contract; the half that
//! protects imprint and implore is "a binding without the axis behaves exactly
//! as it did before the axis existed".

#![cfg(feature = "sqlite")]

use impress_core::collection_migration;
use impress_core::collection_ops::{
    self, ContainerField, FIGURE_COLLECTION, GENERIC_COLLECTION, IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
};
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;

fn temp_store() -> (tempfile::TempDir, SqliteItemStore) {
    let dir = tempfile::tempdir().expect("tempdir");
    let store =
        SqliteItemStore::open(&dir.path().join("impress.sqlite")).expect("open sqlite store");
    (dir, store)
}

/// A stand-in owning container. The kernel only ever writes its id onto the
/// envelope, so any real item will do — this is shaped like an imbib library.
fn make_library(store: &SqliteItemStore, name: &str) -> String {
    make_item(store, "imbib/library", name)
}

fn make_item(store: &SqliteItemStore, schema: &str, name: &str) -> String {
    let now = chrono::Utc::now();
    let mut payload = std::collections::BTreeMap::new();
    payload.insert("name".to_string(), Value::String(name.to_string()));
    let item = Item {
        id: uuid::Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "collection-container-axis-test".to_string(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    };
    store.insert(item).expect("insert library").to_string()
}

fn names(rows: &[collection_ops::CollectionRow]) -> Vec<&str> {
    rows.iter().map(|r| r.name.as_str()).collect()
}

/// The declaration table itself, so a future binding cannot quietly acquire an
/// axis. Exactly one shipped binding is per-container.
#[test]
fn only_imbib_declares_a_container_axis() {
    assert_eq!(
        IMBIB_COLLECTION.container_field,
        Some(ContainerField::Envelope),
        "publication collections are per-library — that is axis 1"
    );
    for binding in [MANUSCRIPT_COLLECTION, FIGURE_COLLECTION, GENERIC_COLLECTION] {
        assert_eq!(
            binding.container_field, None,
            "{}: these folders are global; container arguments must be ignored",
            binding.schema_ref
        );
    }
}

/// The load-bearing property: a container-scoped read answers identically
/// before and after the WP G7 flip, because the migration does not touch the
/// envelope. This is the evidence behind the C2 audit verdict that
/// `list_tree_in` is the migration-safe replacement for
/// `ImbibStore::list_collections`.
#[test]
fn the_container_axis_is_invariant_across_the_unified_flip() {
    let (_dir, store) = temp_store();
    let main = make_library(&store, "Main");
    let other = make_library(&store, "Other");

    let reading = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Reading",
        None,
        None,
        Some(0),
        Some(&main),
    )
    .expect("create root in container");
    let nested = collection_ops::create(
        &store,
        &IMBIB_COLLECTION,
        "Nested",
        Some(&reading.id),
        None,
        Some(1),
    )
    .expect("create child inherits container");
    collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Elsewhere",
        None,
        None,
        Some(0),
        Some(&other),
    )
    .expect("create in the other container");

    // The child inherited its parent's library without being told.
    assert_eq!(nested.container_id.as_deref(), Some(main.as_str()));
    assert_eq!(
        nested.parent_id.as_deref(),
        Some(reading.id.as_str()),
        "container and tree parent are DIFFERENT fields — conflating them is c902a22f"
    );

    // A member, so the count the tree rows carry is exercised across the flip
    // too — `member_count` is imbib-core `list_collections`' number (outgoing
    // Contains edges), which the drop-in replacement must keep reporting.
    let paper = make_item(&store, "imbib/bibliography-entry", "A paper");
    collection_ops::add_members(&store, &IMBIB_COLLECTION, &reading.id, &[paper])
        .expect("file a member");

    let before = collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&main))
        .expect("scoped read before the flip");
    assert_eq!(names(&before), vec!["Reading", "Nested"]);
    assert_eq!(
        before.iter().map(|r| r.member_count).collect::<Vec<_>>(),
        vec![1, 0],
        "tree rows carry the Contains-edge member count"
    );

    // ── The flip ──
    let report = collection_migration::migrate_collections(&store, false).expect("migrate");
    assert_eq!(report.rewritten(), 3, "all three publication collections");
    assert!(collection_migration::is_migrated(&store).unwrap());

    let after = collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&main))
        .expect("scoped read after the flip");
    assert_eq!(
        after, before,
        "container-scoped reads are BYTE-IDENTICAL across the flip: the \
         migration rewrites schema_ref and payload and never the envelope"
    );
    assert_eq!(
        names(&collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&other)).unwrap()),
        vec!["Elsewhere"],
        "and the other container is still cleanly separated"
    );
}

/// ADR-0022 F2, export 1 and 4: the REVERSE-membership read. imbib-core's
/// `list_collections_for_publication` and the `.collections` projection of
/// `get_publication_detail` both asked "which collections hold this paper?" by
/// querying `schema_ref = "imbib/collection"`, so both returned EMPTY at the
/// flip. `collections_containing` is the one verb that replaces both, and this
/// is the property that makes it a drop-in: membership is `Contains` EDGES,
/// which the migration provably never touches, so the answer — rows, order and
/// member counts — cannot move when the schema underneath does.
#[test]
fn collections_containing_is_invariant_across_the_unified_flip() {
    let (_dir, store) = temp_store();
    let main = make_library(&store, "Main");

    let reading = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Reading",
        None,
        None,
        Some(0),
        Some(&main),
    )
    .unwrap();
    let starred = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Starred",
        None,
        None,
        Some(1),
        Some(&main),
    )
    .unwrap();
    // A collection the paper is NOT in, to prove the predicate discriminates.
    collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Unrelated",
        None,
        None,
        Some(2),
        Some(&main),
    )
    .unwrap();

    let paper = make_item(&store, "imbib/bibliography-entry", "A paper");
    let other = make_item(&store, "imbib/bibliography-entry", "Another paper");
    for collection in [&reading.id, &starred.id] {
        collection_ops::add_members(
            &store,
            &IMBIB_COLLECTION,
            collection,
            std::slice::from_ref(&paper),
        )
        .unwrap();
    }
    // A second member of "Reading" only, so the two rows carry DIFFERENT
    // member counts and a count that silently collapsed to 0 would show.
    collection_ops::add_members(&store, &IMBIB_COLLECTION, &reading.id, &[other]).unwrap();

    let before = collection_ops::collections_containing(&store, &IMBIB_COLLECTION, &paper).unwrap();
    assert_eq!(
        names(&before),
        vec!["Reading", "Starred"],
        "sort_order order"
    );
    assert_eq!(
        before.iter().map(|r| r.member_count).collect::<Vec<_>>(),
        vec![2, 1],
        "each row carries its OWN member count, not the queried paper's"
    );
    let before_ids =
        collection_ops::collections_containing_ids(&store, &IMBIB_COLLECTION, &paper).unwrap();
    assert_eq!(
        before_ids,
        before.iter().map(|r| r.id.clone()).collect::<Vec<_>>(),
        "the id projection is the same query, same order"
    );

    // ── The flip ──
    collection_migration::migrate_collections(&store, false).expect("migrate");
    assert!(collection_migration::is_migrated(&store).unwrap());

    let after = collection_ops::collections_containing(&store, &IMBIB_COLLECTION, &paper).unwrap();
    assert_eq!(
        after, before,
        "reverse-membership reads are BYTE-IDENTICAL across the flip — this is \
         what makes the kernel verb a drop-in for list_collections_for_publication"
    );
    assert_eq!(
        collection_ops::collections_containing_ids(&store, &IMBIB_COLLECTION, &paper).unwrap(),
        before_ids,
        "and so is get_publication_detail's .collections projection"
    );

    // The negative half: an id nobody holds, and an id that is not there at all.
    assert!(
        collection_ops::collections_containing(&store, &IMBIB_COLLECTION, &main)
            .unwrap()
            .is_empty()
    );
    assert!(collection_ops::collections_containing(
        &store,
        &IMBIB_COLLECTION,
        &uuid::Uuid::new_v4().to_string()
    )
    .unwrap()
    .is_empty());
}

/// The other membership mechanic, answered by the same verb. Figure folders
/// collect their figures through the ENVELOPE (`item.parent`), so "which
/// folders contain this figure" is the member's own parent — at most one — and
/// a caller must not have to know which mechanic its binding uses.
#[test]
fn collections_containing_answers_envelope_membership_too() {
    use impress_core::store::FieldMutation;

    let (_dir, store) = temp_store();
    let folder = collection_ops::create(&store, &FIGURE_COLLECTION, "Plots", None, None, None)
        .expect("create figure folder");
    let figure = make_item(&store, "figure", "Figure 1");
    let loose = make_item(&store, "figure", "Figure 2");

    store
        .update(
            uuid::Uuid::parse_str(&figure).unwrap(),
            vec![FieldMutation::SetParent(Some(
                uuid::Uuid::parse_str(&folder.id).unwrap(),
            ))],
        )
        .unwrap();

    let holders = collection_ops::collections_containing(&store, &FIGURE_COLLECTION, &figure)
        .expect("envelope membership");
    assert_eq!(names(&holders), vec!["Plots"]);
    assert_eq!(holders[0].member_count, 1);
    assert!(
        collection_ops::collections_containing(&store, &FIGURE_COLLECTION, &loose)
            .unwrap()
            .is_empty(),
        "an unfiled figure is in no folder — not in the library it hangs off"
    );
}

/// ADR-0022 F2, export 3: the WRITE shape. imbib-core's `create_collection`
/// delegates to `create_in_with_payload`, and this is the property that makes
/// that safe to flip under: a collection created BEFORE the flip and then
/// migrated, and a collection created AFTER the flip, must be the same row —
/// otherwise the store acquires two spellings of one kind and the next reader
/// picks one.
///
/// The comparison is deliberately at TWO levels. The row level is what every
/// caller sees. The payload level is what the migration and the kernel see, and
/// it is where a divergence would hide: a missing `kind_scope` would make the
/// new row invisible to its own binding, and a missing `sort_order` would sort
/// it against NULL.
#[test]
fn a_created_collection_is_indistinguishable_from_a_migrated_one() {
    use impress_core::item::Value;

    let (_dir, store) = temp_store();
    let main = make_library(&store, "Main");

    // Exactly the arguments `ImbibStore::create_collection` passes, smart flag
    // included — the field the migration CONSUMES rather than shunts into
    // `legacy`, so it has to match.
    let extras: [(&str, Value); 2] = [
        ("is_smart", Value::Bool(true)),
        ("smart_query", Value::String("starred:true".into())),
    ];
    let created_before = collection_ops::create_in_with_payload(
        &store,
        &IMBIB_COLLECTION,
        "Starred",
        None,
        None,
        None,
        Some(&main),
        &extras,
    )
    .expect("create pre-flip");

    // ── The flip ──
    collection_migration::migrate_collections(&store, false).expect("migrate");

    let created_after = collection_ops::create_in_with_payload(
        &store,
        &IMBIB_COLLECTION,
        "Starred",
        None,
        None,
        None,
        Some(&main),
        &extras,
    )
    .expect("create post-flip");

    let migrated = collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&main))
        .unwrap()
        .into_iter()
        .find(|r| r.id == created_before.id)
        .expect("the pre-flip row survived the migration and is still visible");

    // Row level: identical in every field except the id.
    assert_eq!(
        collection_ops::CollectionRow {
            id: migrated.id.clone(),
            ..created_after.clone()
        },
        migrated,
        "created-then-migrated and created-post-flip are the same row"
    );
    assert!(migrated.is_smart, "and the smart flag survived both routes");

    // Payload level: the canonical fields the kernel and the migration read.
    let payload_of = |id: &str| {
        store
            .get(uuid::Uuid::parse_str(id).unwrap())
            .unwrap()
            .unwrap()
    };
    let old = payload_of(&created_before.id);
    let new = payload_of(&created_after.id);
    assert_eq!(old.schema, new.schema, "both are collection@1.0.0 now");
    assert_eq!(
        old.parent, new.parent,
        "both filed under the same owning library"
    );
    for field in ["name", "kind_scope", "sort_order", "is_smart"] {
        assert_eq!(
            old.payload.get(field),
            new.payload.get(field),
            "canonical field '{field}' must be written identically by the \
             migration and by a native create"
        );
    }
    assert_eq!(
        old.payload.get("kind_scope"),
        Some(&Value::String("publication".into())),
        "and it is the publication scope, which is what makes the row visible \
         to IMBIB_COLLECTION at all"
    );

    // The ONE intended difference: provenance. A migrated row carries the
    // legacy schema and payload so `rollback_collections` can rewind it; a
    // natively created one has nothing to rewind to, which is precisely what
    // `RollbackReport.native_generic_untouched` counts.
    assert!(old.payload.contains_key("legacy_schema_ref"));
    assert!(!new.payload.contains_key("legacy_schema_ref"));
    let report = collection_migration::rollback_collections(&store).expect("rollback");
    assert_eq!(report.restored(), 1, "only the migrated row rewinds");
    assert_eq!(
        report.native_generic_untouched, 1,
        "the post-flip creation is left exactly where it is — a rollback is a \
         rewind of the migration, not a deletion of work done after it"
    );
}

/// The cross-container move imbib performs as two hand-written Swift writes
/// (payload `parent_id` plus `reparentItem`), as one kernel verb — and its
/// documented inverse, applied verbatim.
#[test]
fn cross_container_reparent_is_atomic_and_inverts_exactly() {
    let (_dir, store) = temp_store();
    let main = make_library(&store, "Main");
    let other = make_library(&store, "Other");

    let moving = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Moving",
        None,
        None,
        None,
        Some(&main),
    )
    .unwrap();
    let target = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Target",
        None,
        None,
        None,
        Some(&other),
    )
    .unwrap();

    let moved = collection_ops::reparent_in(
        &store,
        &IMBIB_COLLECTION,
        &moving.id,
        Some(&target.id),
        Some(&other),
    )
    .expect("cross-container reparent");

    assert_eq!(moved.row.parent_id.as_deref(), Some(target.id.as_str()));
    assert_eq!(moved.row.container_id.as_deref(), Some(other.as_str()));
    assert_eq!(
        moved.prior,
        collection_ops::CollectionPrior::ParentInContainer {
            parent: None,
            container: Some(main.clone()),
        },
        "the prior carries BOTH fields, so the inverse needs no re-read"
    );

    // The inverse exactly as the undo contract documents it.
    let back = collection_ops::reparent_in(
        &store,
        &IMBIB_COLLECTION,
        &moving.id,
        moved.prior.parent_id().unwrap(),
        moved.prior.container_id().unwrap(),
    )
    .expect("undo");
    assert_eq!(back.row.parent_id, None, "back to a root");
    assert_eq!(
        back.row.container_id.as_deref(),
        Some(main.as_str()),
        "and back in its original library"
    );
    assert_eq!(
        collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&main))
            .unwrap()
            .len(),
        1,
        "the scoped read agrees with the undone move"
    );
}

/// A same-container move must stay a ONE-field write with a prior that says so,
/// or undoing it would begin writing an envelope the forward move never
/// touched. This is the frozen imbib behaviour: the legacy path skipped its
/// `reparentItem` call entirely when the library did not change.
#[test]
fn same_container_reparent_leaves_the_container_alone() {
    let (_dir, store) = temp_store();
    let main = make_library(&store, "Main");
    let a = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "A",
        None,
        None,
        None,
        Some(&main),
    )
    .unwrap();
    let b = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "B",
        None,
        None,
        None,
        Some(&main),
    )
    .unwrap();

    let moved = collection_ops::reparent(&store, &IMBIB_COLLECTION, &b.id, Some(&a.id)).unwrap();
    assert_eq!(
        moved.prior,
        collection_ops::CollectionPrior::Parent(None),
        "the plain prior — 'the container did not move'"
    );
    assert_eq!(
        moved.prior.container_id(),
        None,
        "so the inverse will leave the container alone"
    );
    assert_eq!(moved.row.container_id.as_deref(), Some(main.as_str()));
}

/// imprint's and implore's half of the contract: the container-taking verbs are
/// no-ops for a binding with no container axis, down to the stored envelope.
#[test]
fn container_verbs_are_inert_for_bindings_without_the_axis() {
    let (_dir, store) = temp_store();
    let library = make_library(&store, "Main");

    for binding in [MANUSCRIPT_COLLECTION, GENERIC_COLLECTION] {
        let row =
            collection_ops::create_in(&store, &binding, "Folder", None, None, None, Some(&library))
                .unwrap();
        assert_eq!(
            row.container_id, None,
            "{}: reports no container",
            binding.schema_ref
        );
        let stored = store
            .get(uuid::Uuid::parse_str(&row.id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(
            stored.parent, None,
            "{}: and wrote no envelope parent — pre-C2 behaviour verbatim",
            binding.schema_ref
        );
    }

    // A manuscript folder is not hidden by a container it never had.
    collection_ops::create(&store, &MANUSCRIPT_COLLECTION, "Drafts", None, None, None).unwrap();
    assert!(
        names(
            &collection_ops::list_tree_in(&store, &MANUSCRIPT_COLLECTION, Some(&library)).unwrap()
        )
        .contains(&"Drafts"),
        "list_tree_in ignores the container for a binding without one"
    );
}

/// Axis 2: the per-row read-only predicate. The kernel never WRITES the flag —
/// it has no predicate language (ADR-0022 risk register) — it only reports it,
/// so a sidebar can gate Rename / New Subcollection on the row rather than on a
/// second read of a legacy row shape.
#[test]
fn is_smart_is_reported_per_row_and_only_where_the_schema_declares_it() {
    use impress_core::store::FieldMutation;

    let (_dir, store) = temp_store();
    let library = make_library(&store, "Main");

    let manual = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Manual",
        None,
        None,
        None,
        Some(&library),
    )
    .unwrap();
    assert!(!manual.is_smart, "the kernel never writes the flag itself");

    // Written the way imbib-core's `create_collection(is_smart: true)` does.
    store
        .update(
            uuid::Uuid::parse_str(&manual.id).unwrap(),
            vec![FieldMutation::SetPayload(
                "is_smart".into(),
                Value::Bool(true),
            )],
        )
        .unwrap();
    let listed = collection_ops::list_tree_in(&store, &IMBIB_COLLECTION, Some(&library)).unwrap();
    assert!(
        listed.iter().find(|r| r.id == manual.id).unwrap().is_smart,
        "and reports it once it is there"
    );

    // A binding whose schema has no such field reports false even with a stray
    // payload key: the axis is the BINDING's declaration, not the row's.
    let folder =
        collection_ops::create(&store, &FIGURE_COLLECTION, "Figures", None, None, None).unwrap();
    store
        .update(
            uuid::Uuid::parse_str(&folder.id).unwrap(),
            vec![FieldMutation::SetPayload(
                "is_smart".into(),
                Value::Bool(true),
            )],
        )
        .unwrap();
    assert!(
        !collection_ops::list_tree(&store, &FIGURE_COLLECTION)
            .unwrap()
            .iter()
            .find(|r| r.id == folder.id)
            .unwrap()
            .is_smart,
        "figure-collection declares no smart_field"
    );
}

/// Undoing the delete of a SMART collection must not demote it to a manual one.
/// The flag was invisible to `restore` until C2 gave `CollectionRow` an
/// `is_smart`, so the row came back with the wrong glyph and the full menu.
#[test]
fn restoring_a_smart_collection_keeps_it_smart() {
    use impress_core::store::FieldMutation;

    let (_dir, store) = temp_store();
    let library = make_library(&store, "Main");
    let smart = collection_ops::create_in(
        &store,
        &IMBIB_COLLECTION,
        "Recent",
        None,
        None,
        None,
        Some(&library),
    )
    .unwrap();
    store
        .update(
            uuid::Uuid::parse_str(&smart.id).unwrap(),
            vec![FieldMutation::SetPayload(
                "is_smart".into(),
                Value::Bool(true),
            )],
        )
        .unwrap();

    let snapshot = collection_ops::delete(&store, &IMBIB_COLLECTION, &smart.id).unwrap();
    assert!(snapshot.row.is_smart, "the snapshot carries the flag");

    let restored = collection_ops::restore(&store, &IMBIB_COLLECTION, &snapshot).unwrap();
    assert!(restored.is_smart, "restored smart");
    assert_eq!(
        restored.container_id.as_deref(),
        Some(library.as_str()),
        "and back in its original library"
    );
}
