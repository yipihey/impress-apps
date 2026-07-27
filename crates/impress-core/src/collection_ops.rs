//! The collection kernel (ADR-0022 D1/D2).
//!
//! One implementation of the collection verb set — `list_tree`, `create`,
//! `rename`, `reparent`, `reorder`, `delete`, `add_members`,
//! `remove_members`, `member_counts` — parameterized by a
//! [`CollectionSchemaBinding`] so it can front the schemas that already exist
//! (`imbib/collection`, `manuscript-collection`, `figure-collection`) as well
//! as the generic `collection@1.0.0` schema. D2 unifies the API first; the
//! data migration onto one schema is a separate work package.
//!
//! This lives in impress-core — next to `manuscript_ops` — so both FFI
//! surfaces (`impress-store-ffi::SharedStore` and `imbib-core::ImbibStore`)
//! and the future `#[impress_service]` trait share one implementation
//! instead of drifting. The reparent cycle check in particular used to live
//! only in Swift; it is Rust's now.
//!
//! Every UUID that crosses this API is normalized to lowercase: ids are
//! parsed into `Uuid` on the way in and rendered with `to_string()` on the
//! way out. Payload parent refs are matched by string equality downstream
//! (the imbib "manuscript UUID strings crossing the FFI must be lowercase"
//! invariant), so this layer is where the normalization happens.

use std::collections::BTreeMap;

use chrono::Utc;
use uuid::Uuid;

use crate::item::{Item, ItemId, Priority, Value, Visibility};
use crate::query::{ItemQuery, Predicate, SortDescriptor};
use crate::reference::{EdgeType, TypedReference};
use crate::schemas::collection::{COLLECTION_SCHEMA, KIND_SCOPE_ANY};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{FieldMutation, ItemStore, StoreError};

/// Hard ceiling on parent-chain walks. A tree deeper than this is a data bug
/// (or a pre-existing cycle written before the check moved into Rust), and
/// either way must not spin forever.
const MAX_TREE_DEPTH: usize = 256;

/// Where a binding keeps the collection *tree* parent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParentField {
    /// A payload string field holding the parent collection's UUID.
    ///
    /// The tree parent is NEVER the envelope `item.parent`: for imbib and
    /// imprint collections that field is the owning LIBRARY, which is what
    /// `list_collections` filters on. c902a22f returned it as the tree parent
    /// and flattened the whole sidebar (see the invariant in
    /// `apps/imbib/CLAUDE.md`).
    Payload(&'static str),
    /// The envelope `item.parent` chain. implore's figure folders have no
    /// payload parent field — folders nest and figures are filed through
    /// `set_parent` (`ImploreStoreAdapter`, `FigureStoreReader`).
    Envelope,
}

/// How a binding records membership.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Membership {
    /// A `Contains` edge from the collection to the member (imbib, imprint,
    /// generic). Deleting the collection drops the edges by FK cascade.
    ContainsEdge,
    /// The member's envelope `item.parent` points at the collection (figure
    /// folders). Deleting the collection unfiles its members (FK SET NULL).
    EnvelopeParent,
}

/// Descriptor binding the kernel to one concrete collection schema.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CollectionSchemaBinding {
    /// Exact `schema_ref` stored on collection items (queries match it with
    /// string equality, so this is the stored form, not the display form).
    pub schema_ref: &'static str,
    pub parent_field: ParentField,
    pub membership: Membership,
    /// Payload field naming the record kind the collection organises, for
    /// schemas that have one. Only `collection@1.0.0` does today.
    pub kind_scope_field: Option<&'static str>,
}

/// imbib publication collections (`imbib/collection`): payload `parent_id`
/// tree, `Contains` membership, envelope parent = owning library.
pub const IMBIB_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "imbib/collection",
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: None,
};

/// imprint manuscript folders (`manuscript-collection@1.0.0`, stored bare as
/// `manuscript-collection`): payload `parent_collection_ref` tree.
pub const MANUSCRIPT_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "manuscript-collection",
    parent_field: ParentField::Payload("parent_collection_ref"),
    membership: Membership::ContainsEdge,
    kind_scope_field: None,
};

/// implore figure folders (`figure-collection@1.0.0`). The odd one out: the
/// schema has no parent field at all, so both nesting and membership run
/// through the envelope parent.
pub const FIGURE_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "figure-collection",
    parent_field: ParentField::Envelope,
    membership: Membership::EnvelopeParent,
    kind_scope_field: None,
};

/// The generic `collection@1.0.0` kernel schema (ADR-0022 D1).
pub const GENERIC_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: COLLECTION_SCHEMA,
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: Some("kind_scope"),
};

/// Every binding the kernel fronts, in stable order.
pub const ALL_BINDINGS: [CollectionSchemaBinding; 4] = [
    IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
    FIGURE_COLLECTION,
    GENERIC_COLLECTION,
];

/// One flat collection row. Callers assemble the tree from `parent_id`
/// (`None` = root) — the kernel deliberately returns a flat list so sidebars
/// can group, filter and sort it their own way.
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionRow {
    /// Lowercase UUID string.
    pub id: String,
    pub name: String,
    /// Lowercase UUID string of the tree parent, or `None` for a root.
    pub parent_id: Option<String>,
    pub sort_order: i64,
    /// Record-kind scope, for bindings whose schema carries one.
    pub kind_scope: Option<String>,
}

// ─── Reads ───────────────────────────────────────────────────────────────────

/// All collections of the bound schema, ordered by `sort_order`.
pub fn list_tree(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
) -> Result<Vec<CollectionRow>, StoreError> {
    let q = ItemQuery {
        schema: Some(binding.schema_ref.into()),
        sort: vec![SortDescriptor {
            field: "payload.sort_order".into(),
            ascending: true,
        }],
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    Ok(store
        .query(&q)?
        .iter()
        .map(|item| row_of(binding, item))
        .collect())
}

/// The items belonging to a collection, in creation order (newest first).
/// Heterogeneous by construction: a `kind_scope: "any"` collection returns
/// members of every schema.
pub fn list_members(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_id: &str,
) -> Result<Vec<Item>, StoreError> {
    let id = parse_id(collection_id)?;
    load_collection(store, binding, id)?;
    store.query(&member_query(binding, id))
}

/// Member count per collection, aligned with `collection_ids`. Unknown ids
/// count 0 rather than erroring, so a stale sidebar cannot break a refresh.
pub fn member_counts(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_ids: &[String],
) -> Result<Vec<u32>, StoreError> {
    let mut counts = Vec::with_capacity(collection_ids.len());
    for raw in collection_ids {
        let id = parse_id(raw)?;
        counts.push(match binding.membership {
            // Sub-collections nest through the parent field, never through a
            // Contains edge, so every outgoing Contains edge is a member.
            Membership::ContainsEdge => match store.get(id)? {
                Some(item) if item.schema == binding.schema_ref => {
                    item.references
                        .iter()
                        .filter(|r| r.edge_type == EdgeType::Contains)
                        .count() as u32
                }
                _ => 0,
            },
            Membership::EnvelopeParent => store.count(&member_query(binding, id))? as u32,
        });
    }
    Ok(counts)
}

// ─── Structure ───────────────────────────────────────────────────────────────

/// Create a collection under `parent` (`None` = root).
///
/// `kind_scope` is written only for bindings whose schema has the field; the
/// generic binding defaults it to `"any"`. For payload-tree bindings the new
/// item inherits the parent collection's envelope parent — the owning library
/// — so a kernel-created collection lands in the same library its parent is
/// filed under and stays visible to the legacy `HasParent` listings.
pub fn create(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    name: &str,
    parent: Option<&str>,
    kind_scope: Option<&str>,
) -> Result<CollectionRow, StoreError> {
    let parent_id = parent.map(parse_id).transpose()?;
    let parent_item = match parent_id {
        Some(pid) => Some(load_collection(store, binding, pid)?),
        None => None,
    };

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("name".into(), Value::String(name.to_string()));
    payload.insert("sort_order".into(), Value::Int(0));
    if let Some(field) = binding.kind_scope_field {
        payload.insert(
            field.into(),
            Value::String(kind_scope.unwrap_or(KIND_SCOPE_ANY).to_string()),
        );
    }
    if let (ParentField::Payload(field), Some(pid)) = (binding.parent_field, parent_id) {
        payload.insert(field.into(), Value::String(pid.to_string()));
    }

    let mut item = new_item(store, binding.schema_ref, payload);
    item.parent = match binding.parent_field {
        ParentField::Payload(_) => parent_item.as_ref().and_then(|p| p.parent),
        ParentField::Envelope => parent_id,
    };

    store.insert(item.clone())?;
    Ok(row_of(binding, &item))
}

/// Rename a collection.
pub fn rename(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    name: &str,
) -> Result<CollectionRow, StoreError> {
    let id = parse_id(id)?;
    load_collection(store, binding, id)?;
    store.update(
        id,
        vec![FieldMutation::SetPayload(
            "name".into(),
            Value::String(name.to_string()),
        )],
    )?;
    reload_row(store, binding, id)
}

/// Move a collection under `new_parent` (`None` = make it a root).
///
/// Rejects self-parenting and any move that would put a collection under one
/// of its own descendants. This check used to live in the Swift sidebar view
/// model, where every caller had to remember it; it is the kernel's now.
pub fn reparent(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    new_parent: Option<&str>,
) -> Result<CollectionRow, StoreError> {
    let id = parse_id(id)?;
    load_collection(store, binding, id)?;
    let new_parent_id = new_parent.map(parse_id).transpose()?;

    if let Some(target) = new_parent_id {
        if target == id {
            return Err(StoreError::Validation(format!(
                "collection {id} cannot be its own parent"
            )));
        }
        let target_item = load_collection(store, binding, target)?;
        let mut cursor = tree_parent(binding, &target_item);
        let mut hops = 0usize;
        while let Some(ancestor) = cursor {
            if ancestor == id {
                return Err(StoreError::Validation(format!(
                    "reparenting {id} under {target} would create a cycle"
                )));
            }
            hops += 1;
            if hops > MAX_TREE_DEPTH {
                return Err(StoreError::Validation(format!(
                    "collection ancestry of {target} exceeds {MAX_TREE_DEPTH} levels"
                )));
            }
            cursor = match store.get(ancestor)? {
                Some(item) => tree_parent(binding, &item),
                None => None,
            };
        }
    }

    let mutation = match (binding.parent_field, new_parent_id) {
        (ParentField::Payload(field), Some(target)) => {
            FieldMutation::SetPayload(field.into(), Value::String(target.to_string()))
        }
        (ParentField::Payload(field), None) => FieldMutation::RemovePayload(field.into()),
        (ParentField::Envelope, target) => FieldMutation::SetParent(target),
    };
    store.update(id, vec![mutation])?;
    reload_row(store, binding, id)
}

/// Set a collection's position among its siblings.
pub fn reorder(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    sort_order: i64,
) -> Result<CollectionRow, StoreError> {
    let id = parse_id(id)?;
    load_collection(store, binding, id)?;
    store.update(
        id,
        vec![FieldMutation::SetPayload(
            "sort_order".into(),
            Value::Int(sort_order),
        )],
    )?;
    reload_row(store, binding, id)
}

/// Delete a collection. Members are never deleted — only the membership goes
/// away: `Contains` edges vanish with the row (FK CASCADE) and envelope-filed
/// members are unfiled (FK SET NULL). Not idempotent: deleting a missing
/// collection returns `NotFound`, matching `delete_collection` in imbib-core.
pub fn delete(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
) -> Result<(), StoreError> {
    let id = parse_id(id)?;
    load_collection(store, binding, id)?;
    store.delete(id)
}

// ─── Membership ──────────────────────────────────────────────────────────────

/// Add items to a collection. Idempotent per member; returns the number of
/// members touched.
pub fn add_members(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_id: &str,
    item_ids: &[String],
) -> Result<u32, StoreError> {
    let collection = parse_id(collection_id)?;
    load_collection(store, binding, collection)?;
    let mut applied = 0u32;
    for raw in item_ids {
        let member = parse_id(raw)?;
        match binding.membership {
            Membership::ContainsEdge => store.update(
                collection,
                vec![FieldMutation::AddReference(TypedReference {
                    target: member,
                    edge_type: EdgeType::Contains,
                    metadata: None,
                })],
            )?,
            Membership::EnvelopeParent => {
                store.update(member, vec![FieldMutation::SetParent(Some(collection))])?
            }
        }
        applied += 1;
    }
    Ok(applied)
}

/// Remove items from a collection. Returns the number of members actually
/// removed; envelope-filed items that live in a different collection are left
/// alone rather than unfiled.
pub fn remove_members(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_id: &str,
    item_ids: &[String],
) -> Result<u32, StoreError> {
    let collection = parse_id(collection_id)?;
    load_collection(store, binding, collection)?;
    let mut applied = 0u32;
    for raw in item_ids {
        let member = parse_id(raw)?;
        match binding.membership {
            Membership::ContainsEdge => {
                store.update(
                    collection,
                    vec![FieldMutation::RemoveReference(member, EdgeType::Contains)],
                )?;
                applied += 1;
            }
            Membership::EnvelopeParent => {
                let filed_here = store
                    .get(member)?
                    .map(|item| item.parent == Some(collection))
                    .unwrap_or(false);
                if filed_here {
                    store.update(member, vec![FieldMutation::SetParent(None)])?;
                    applied += 1;
                }
            }
        }
    }
    Ok(applied)
}

// ─── Internals ───────────────────────────────────────────────────────────────

fn parse_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id).map_err(|_| StoreError::Validation(format!("invalid UUID: {id}")))
}

/// Fetch an item and assert it is a collection of the bound schema.
fn load_collection(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: ItemId,
) -> Result<Item, StoreError> {
    let item = store.get(id)?.ok_or(StoreError::NotFound(id))?;
    if item.schema != binding.schema_ref {
        return Err(StoreError::Validation(format!(
            "item {id} has schema '{}', expected '{}'",
            item.schema, binding.schema_ref
        )));
    }
    Ok(item)
}

fn reload_row(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: ItemId,
) -> Result<CollectionRow, StoreError> {
    let item = load_collection(store, binding, id)?;
    Ok(row_of(binding, &item))
}

fn row_of(binding: &CollectionSchemaBinding, item: &Item) -> CollectionRow {
    CollectionRow {
        id: item.id.to_string(),
        name: string_field(item, "name").unwrap_or_default(),
        parent_id: tree_parent(binding, item).map(|p| p.to_string()),
        sort_order: int_field(item, "sort_order").unwrap_or(0),
        kind_scope: binding
            .kind_scope_field
            .and_then(|field| string_field(item, field)),
    }
}

/// The collection's tree parent — payload ref or envelope parent per the
/// binding. Payload refs are parsed rather than compared as raw strings, so a
/// legacy uppercase ref still resolves and comes back lowercase.
fn tree_parent(binding: &CollectionSchemaBinding, item: &Item) -> Option<ItemId> {
    match binding.parent_field {
        ParentField::Payload(field) => string_field(item, field)
            .filter(|s| !s.is_empty())
            .and_then(|s| Uuid::parse_str(&s).ok()),
        ParentField::Envelope => item.parent,
    }
}

/// Query selecting a collection's members.
fn member_query(binding: &CollectionSchemaBinding, collection: ItemId) -> ItemQuery {
    let predicates = match binding.membership {
        Membership::ContainsEdge => vec![Predicate::ReferencedBy(EdgeType::Contains, collection)],
        // Envelope children include nested sub-collections; those are tree
        // nodes, not members.
        Membership::EnvelopeParent => vec![
            Predicate::HasParent(collection),
            Predicate::Neq(
                "schema_ref".into(),
                Value::String(binding.schema_ref.to_string()),
            ),
        ],
    };
    ItemQuery {
        predicates,
        sort: vec![SortDescriptor {
            field: "created".into(),
            ascending: false,
        }],
        ..Default::default()
    }
}

fn new_item(store: &SqliteItemStore, schema: &str, payload: BTreeMap<String, Value>) -> Item {
    let now = Utc::now();
    Item {
        id: Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: store.default_author.clone(),
        author_kind: store.default_author_kind,
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
    }
}

fn string_field(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn int_field(item: &Item, field: &str) -> Option<i64> {
    match item.payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::ActorKind;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    /// A non-collection item of an arbitrary schema, for membership tests.
    fn make_item(store: &SqliteItemStore, schema: &str, title: &str) -> String {
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        let item = new_item(store, schema, payload);
        let id = store.insert(item).expect("insert item");
        id.to_string()
    }

    fn names(rows: &[CollectionRow]) -> Vec<&str> {
        rows.iter().map(|r| r.name.as_str()).collect()
    }

    fn row(rows: &[CollectionRow], id: &str) -> CollectionRow {
        rows.iter()
            .find(|r| r.id == id)
            .cloned()
            .unwrap_or_else(|| panic!("row {id} not listed"))
    }

    // ─── Cycle check ─────────────────────────────────────────────────────

    #[test]
    fn reparent_rejects_self_parent() {
        let store = open();
        let a = create(&store, &GENERIC_COLLECTION, "A", None, None).unwrap();
        let err = reparent(&store, &GENERIC_COLLECTION, &a.id, Some(&a.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("own parent")),
            "self-parent must be rejected, got {err:?}"
        );
    }

    #[test]
    fn reparent_rejects_direct_child() {
        let store = open();
        let parent = create(&store, &GENERIC_COLLECTION, "Parent", None, None).unwrap();
        let child = create(&store, &GENERIC_COLLECTION, "Child", Some(&parent.id), None).unwrap();

        let err = reparent(&store, &GENERIC_COLLECTION, &parent.id, Some(&child.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("cycle")),
            "moving a parent under its own child must be rejected, got {err:?}"
        );
        // The tree is untouched by the rejected move.
        let rows = list_tree(&store, &GENERIC_COLLECTION).unwrap();
        assert_eq!(row(&rows, &parent.id).parent_id, None);
        assert_eq!(row(&rows, &child.id).parent_id, Some(parent.id.clone()));
    }

    #[test]
    fn reparent_rejects_deep_descendant() {
        let store = open();
        let a = create(&store, &GENERIC_COLLECTION, "A", None, None).unwrap();
        let b = create(&store, &GENERIC_COLLECTION, "B", Some(&a.id), None).unwrap();
        let c = create(&store, &GENERIC_COLLECTION, "C", Some(&b.id), None).unwrap();
        let d = create(&store, &GENERIC_COLLECTION, "D", Some(&c.id), None).unwrap();

        let err = reparent(&store, &GENERIC_COLLECTION, &a.id, Some(&d.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("cycle")),
            "moving a root under its grandchild's child must be rejected, got {err:?}"
        );
        // A sibling move that is NOT a cycle still works.
        let e = create(&store, &GENERIC_COLLECTION, "E", None, None).unwrap();
        let moved = reparent(&store, &GENERIC_COLLECTION, &e.id, Some(&d.id)).unwrap();
        assert_eq!(moved.parent_id, Some(d.id));
    }

    #[test]
    fn reparent_cycle_check_walks_envelope_chain_for_figures() {
        let store = open();
        let parent = create(&store, &FIGURE_COLLECTION, "Plots", None, None).unwrap();
        let child = create(&store, &FIGURE_COLLECTION, "Panels", Some(&parent.id), None).unwrap();
        assert_eq!(child.parent_id, Some(parent.id.clone()));

        let err = reparent(&store, &FIGURE_COLLECTION, &parent.id, Some(&child.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("cycle")),
            "figure folders nest via the envelope parent; cycles must still be rejected"
        );
    }

    // ─── Round trips ─────────────────────────────────────────────────────

    #[test]
    fn generic_binding_round_trip() {
        let store = open();
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, Some("any")).unwrap();
        let child = create(
            &store,
            &GENERIC_COLLECTION,
            "Child",
            Some(&root.id),
            Some("publication"),
        )
        .unwrap();

        assert_eq!(root.kind_scope.as_deref(), Some("any"));
        assert_eq!(child.kind_scope.as_deref(), Some("publication"));
        assert_eq!(child.parent_id, Some(root.id.clone()));
        assert_eq!(root.sort_order, 0);

        let renamed = rename(&store, &GENERIC_COLLECTION, &child.id, "Renamed").unwrap();
        assert_eq!(renamed.name, "Renamed");

        let reordered = reorder(&store, &GENERIC_COLLECTION, &child.id, 7).unwrap();
        assert_eq!(reordered.sort_order, 7);

        let unparented = reparent(&store, &GENERIC_COLLECTION, &child.id, None).unwrap();
        assert_eq!(unparented.parent_id, None);
        let reparented = reparent(&store, &GENERIC_COLLECTION, &child.id, Some(&root.id)).unwrap();
        assert_eq!(reparented.parent_id, Some(root.id.clone()));

        let rows = list_tree(&store, &GENERIC_COLLECTION).unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(
            names(&rows),
            vec!["Root", "Renamed"],
            "sorted by sort_order"
        );

        delete(&store, &GENERIC_COLLECTION, &child.id).unwrap();
        let rows = list_tree(&store, &GENERIC_COLLECTION).unwrap();
        assert_eq!(names(&rows), vec!["Root"]);
        assert!(matches!(
            delete(&store, &GENERIC_COLLECTION, &child.id),
            Err(StoreError::NotFound(_))
        ));
    }

    #[test]
    fn manuscript_binding_round_trip() {
        let store = open();
        let workspace = create(&store, &MANUSCRIPT_COLLECTION, "Workspace", None, None).unwrap();
        let folder = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Drafts",
            Some(&workspace.id),
            None,
        )
        .unwrap();

        // The tree edge is the payload ref this schema already uses.
        let item = store.get(parse_id(&folder.id).unwrap()).unwrap().unwrap();
        assert_eq!(
            item.payload.get("parent_collection_ref"),
            Some(&Value::String(workspace.id.clone()))
        );
        assert_eq!(item.parent, None, "envelope parent is not the tree edge");
        assert!(folder.kind_scope.is_none());

        rename(&store, &MANUSCRIPT_COLLECTION, &folder.id, "Submitted").unwrap();
        reorder(&store, &MANUSCRIPT_COLLECTION, &folder.id, 3).unwrap();
        let rows = list_tree(&store, &MANUSCRIPT_COLLECTION).unwrap();
        let updated = row(&rows, &folder.id);
        assert_eq!(updated.name, "Submitted");
        assert_eq!(updated.sort_order, 3);
        assert_eq!(updated.parent_id, Some(workspace.id.clone()));

        let ms = make_item(&store, "manuscript", "A Paper");
        assert_eq!(
            add_members(&store, &MANUSCRIPT_COLLECTION, &folder.id, &[ms.clone()]).unwrap(),
            1
        );
        assert_eq!(
            member_counts(&store, &MANUSCRIPT_COLLECTION, &[folder.id.clone()]).unwrap(),
            vec![1]
        );

        delete(&store, &MANUSCRIPT_COLLECTION, &folder.id).unwrap();
        assert_eq!(list_tree(&store, &MANUSCRIPT_COLLECTION).unwrap().len(), 1);
        assert!(
            store.get(parse_id(&ms).unwrap()).unwrap().is_some(),
            "deleting a collection must not delete its members"
        );
    }

    #[test]
    fn create_inherits_owning_library_from_parent_collection() {
        let store = open();
        let library = make_item(&store, "imbib/library", "Main");
        let library_id = parse_id(&library).unwrap();

        let root = create(&store, &IMBIB_COLLECTION, "Reading", None, None).unwrap();
        store
            .update(
                parse_id(&root.id).unwrap(),
                vec![FieldMutation::SetParent(Some(library_id))],
            )
            .unwrap();

        let child = create(&store, &IMBIB_COLLECTION, "Queue", Some(&root.id), None).unwrap();
        let item = store.get(parse_id(&child.id).unwrap()).unwrap().unwrap();
        assert_eq!(
            item.parent,
            Some(library_id),
            "envelope parent stays the owning library"
        );
        assert_eq!(
            child.parent_id,
            Some(root.id),
            "tree parent is the payload ref, never the library"
        );
    }

    // ─── Membership ──────────────────────────────────────────────────────

    #[test]
    fn mixed_kind_membership_over_any_scope() {
        let store = open();
        let mixed = create(
            &store,
            &GENERIC_COLLECTION,
            "Grant renewal",
            None,
            Some("any"),
        )
        .unwrap();
        let other = create(&store, &GENERIC_COLLECTION, "Empty", None, None).unwrap();

        let manuscript = make_item(&store, "manuscript", "Draft II");
        let figure = make_item(&store, "figure", "Rotation curve");

        let added = add_members(
            &store,
            &GENERIC_COLLECTION,
            &mixed.id,
            &[manuscript.clone(), figure.clone()],
        )
        .unwrap();
        assert_eq!(added, 2);

        assert_eq!(
            member_counts(
                &store,
                &GENERIC_COLLECTION,
                &[mixed.id.clone(), other.id.clone()]
            )
            .unwrap(),
            vec![2, 0],
            "counts are aligned with the requested ids"
        );

        let members = list_members(&store, &GENERIC_COLLECTION, &mixed.id).unwrap();
        let mut schemas: Vec<&str> = members.iter().map(|i| i.schema.as_str()).collect();
        schemas.sort_unstable();
        assert_eq!(
            schemas,
            vec!["figure", "manuscript"],
            "one collection, two record kinds"
        );

        // Idempotent add, then partial removal.
        assert_eq!(
            add_members(&store, &GENERIC_COLLECTION, &mixed.id, &[figure.clone()]).unwrap(),
            1
        );
        assert_eq!(
            member_counts(&store, &GENERIC_COLLECTION, &[mixed.id.clone()]).unwrap(),
            vec![2],
            "re-adding an existing member must not duplicate it"
        );

        remove_members(&store, &GENERIC_COLLECTION, &mixed.id, &[figure]).unwrap();
        let members = list_members(&store, &GENERIC_COLLECTION, &mixed.id).unwrap();
        assert_eq!(members.len(), 1);
        assert_eq!(members[0].id.to_string(), manuscript);
    }

    #[test]
    fn figure_membership_uses_envelope_parent() {
        let store = open();
        let folder = create(&store, &FIGURE_COLLECTION, "Paper figures", None, None).unwrap();
        let nested = create(
            &store,
            &FIGURE_COLLECTION,
            "Supplement",
            Some(&folder.id),
            None,
        )
        .unwrap();
        let figure = make_item(&store, "figure", "Panel A");

        add_members(&store, &FIGURE_COLLECTION, &folder.id, &[figure.clone()]).unwrap();
        let filed = store.get(parse_id(&figure).unwrap()).unwrap().unwrap();
        assert_eq!(filed.parent, Some(parse_id(&folder.id).unwrap()));
        assert_eq!(
            member_counts(&store, &FIGURE_COLLECTION, &[folder.id.clone()]).unwrap(),
            vec![1],
            "the nested folder is a tree node, not a member"
        );
        assert!(nested.parent_id.is_some());

        // Removing a figure filed elsewhere is a no-op, not an unfile.
        assert_eq!(
            remove_members(&store, &FIGURE_COLLECTION, &nested.id, &[figure.clone()]).unwrap(),
            0
        );
        assert_eq!(
            remove_members(&store, &FIGURE_COLLECTION, &folder.id, &[figure.clone()]).unwrap(),
            1
        );
        let unfiled = store.get(parse_id(&figure).unwrap()).unwrap().unwrap();
        assert_eq!(unfiled.parent, None);
    }

    // ─── Binding hygiene ─────────────────────────────────────────────────

    #[test]
    fn bindings_reject_items_of_another_schema() {
        let store = open();
        let generic = create(&store, &GENERIC_COLLECTION, "Mixed", None, None).unwrap();
        let err = rename(&store, &MANUSCRIPT_COLLECTION, &generic.id, "Nope");
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("manuscript-collection")),
            "a binding must not mutate another schema's collections, got {err:?}"
        );
        assert!(list_tree(&store, &MANUSCRIPT_COLLECTION)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn ids_are_normalized_to_lowercase() {
        let store = open();
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, None).unwrap();
        let upper = root.id.to_uppercase();

        let child = create(&store, &GENERIC_COLLECTION, "Child", Some(&upper), None).unwrap();
        assert_eq!(
            child.parent_id,
            Some(root.id.clone()),
            "an uppercase parent id comes back lowercase"
        );
        let item = store.get(parse_id(&child.id).unwrap()).unwrap().unwrap();
        assert_eq!(
            item.payload.get("parent_id"),
            Some(&Value::String(root.id.clone())),
            "payload refs are stored lowercase (string-equality matching)"
        );

        // A ref that was written uppercase by a legacy caller still resolves.
        store
            .update(
                parse_id(&child.id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "parent_id".into(),
                    Value::String(upper),
                )],
            )
            .unwrap();
        let rows = list_tree(&store, &GENERIC_COLLECTION).unwrap();
        assert_eq!(row(&rows, &child.id).parent_id, Some(root.id));
    }

    #[test]
    fn all_bindings_have_distinct_schema_refs() {
        let mut refs: Vec<&str> = ALL_BINDINGS.iter().map(|b| b.schema_ref).collect();
        refs.sort_unstable();
        let unique = refs.len();
        refs.dedup();
        assert_eq!(refs.len(), unique, "bindings must not share a schema_ref");
    }

    #[test]
    fn create_rejects_unknown_parent() {
        let store = open();
        let missing = Uuid::new_v4().to_string();
        assert!(matches!(
            create(&store, &GENERIC_COLLECTION, "Orphan", Some(&missing), None),
            Err(StoreError::NotFound(_))
        ));
        assert!(matches!(
            create(
                &store,
                &GENERIC_COLLECTION,
                "Orphan",
                Some("not-a-uuid"),
                None
            ),
            Err(StoreError::Validation(_))
        ));
    }

    #[test]
    fn author_matches_store_default() {
        let store = open();
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, None).unwrap();
        let item = store.get(parse_id(&root.id).unwrap()).unwrap().unwrap();
        assert_eq!(item.author, store.default_author);
        assert!(matches!(
            item.author_kind,
            ActorKind::System | ActorKind::Human | ActorKind::Agent
        ));
    }
}
