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
//!
//! # Undo contract (ADR-0022 G2)
//!
//! Every mutating verb returns what an undo stack needs to invert it, so a
//! caller can register an exact inverse without re-reading the store first
//! (which races, and which is what the Swift adapters used to do by hand):
//!
//! | verb             | returns                   | undo by calling                                   |
//! |------------------|---------------------------|---------------------------------------------------|
//! | `create`         | [`CollectionRow`]         | `delete(row.id)`                                  |
//! | `rename`         | [`CollectionMutation`]    | `rename(id, prior.name())`                        |
//! | `reorder`        | [`CollectionMutation`]    | `reorder(id, prior.sort_order())`                 |
//! | `reparent`       | [`CollectionMutation`]    | `reparent(id, prior.parent_id())` (`None` = root) |
//! | `delete`         | [`DeletedCollection`]     | `restore(snapshot)`                               |
//! | `restore`        | [`CollectionRow`]         | `delete(row.id)`                                  |
//! | `add_members`    | changed ids               | `remove_members(collection, changed)`             |
//! | `remove_members` | changed ids               | `add_members(collection, changed)`                |
//!
//! The membership verbs return only the ids they actually changed — never the
//! ids the caller asked for — so the inverse cannot re-file an item that was
//! already a member (or unfile one that never was).
//!
//! # Dual mode (ADR-0022 WP G7)
//!
//! Once [`crate::collection_migration`] has converged the store's data onto
//! `collection@1.0.0`, the three legacy bindings no longer have rows of their
//! own schema to find. Every verb therefore starts by RESOLVING its binding
//! against the store's `collections.unified` marker
//! ([`CollectionSchemaBinding::resolved`]):
//!
//! | binding | marker off → query | marker on → query | membership (both) |
//! |---|---|---|---|
//! | `IMBIB_COLLECTION` | `schema_ref = imbib/collection`, tree = payload `parent_id` | `schema_ref = collection` + `kind_scope = publication`, tree = payload `parent_id` | `Contains` edge |
//! | `MANUSCRIPT_COLLECTION` | `schema_ref = manuscript-collection`, tree = payload `parent_collection_ref` | `schema_ref = collection` + `kind_scope = manuscript`, tree = payload `parent_id` | `Contains` edge |
//! | `FIGURE_COLLECTION` | `schema_ref = figure-collection`, tree = envelope `item.parent` | `schema_ref = collection` + `kind_scope = figure`, tree = payload `parent_id` | envelope `item.parent` |
//! | `GENERIC_COLLECTION` | `schema_ref = collection`, tree = payload `parent_id` | unchanged (it is the destination) | `Contains` edge |
//!
//! Two invariants make the flip invisible to callers:
//!
//! - **Membership never moves.** A migrated figure folder still collects its
//!   figures through `item.parent`, because the migration did not change ids
//!   and did not touch the envelope. `Contains` edges likewise survive as-is.
//! - **`CollectionRow.kind_scope` stays `None` for the legacy bindings.** Their
//!   scope is a constant the binding already knows; surfacing it post-flip
//!   would change the row shape every FFI caller sees for no information gain.
//!   Only `GENERIC_COLLECTION`, whose scope is genuinely per-row, reports it.
//!
//! With the marker off, every path below is byte-identical to its pre-G7 self.

use std::collections::BTreeMap;

use chrono::Utc;
use uuid::Uuid;

use crate::collection_migration;
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

/// What a binding writes to a collection row's envelope `item.parent`.
///
/// Separate from [`ParentField`] because the two answer different questions:
/// `ParentField` says where the TREE parent is READ from, this says what the
/// envelope is FOR. They coincide only for figure folders — and after WP G7's
/// migration even those read their tree parent from the payload while their
/// envelope keeps pointing at the folder above, which is what keeps
/// envelope-filed figure membership working.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvelopeParent {
    /// The OWNING LIBRARY. A new row inherits its parent collection's envelope
    /// parent, so it stays visible to the legacy `HasParent` library listings.
    OwningLibrary,
    /// The TREE PARENT itself (figure folders). The kernel keeps the envelope
    /// in step with the tree parent whichever field the tree parent is read
    /// from.
    TreeParent,
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
    /// What this binding's rows carry on the envelope `item.parent`.
    pub envelope_parent: EnvelopeParent,
    /// The payload `kind_scope` this binding's rows carry once the store has
    /// converged on `collection@1.0.0` (ADR-0022 WP G7). `None` for the
    /// generic binding, which is unscoped: it is the destination, and it sees
    /// every collection row whatever its scope.
    pub unified_kind_scope: Option<&'static str>,
}

/// imbib publication collections (`imbib/collection`): payload `parent_id`
/// tree, `Contains` membership, envelope parent = owning library.
pub const IMBIB_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "imbib/collection",
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: None,
    envelope_parent: EnvelopeParent::OwningLibrary,
    unified_kind_scope: Some("publication"),
};

/// imprint manuscript folders (`manuscript-collection@1.0.0`, stored bare as
/// `manuscript-collection`): payload `parent_collection_ref` tree.
pub const MANUSCRIPT_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "manuscript-collection",
    parent_field: ParentField::Payload("parent_collection_ref"),
    membership: Membership::ContainsEdge,
    kind_scope_field: None,
    envelope_parent: EnvelopeParent::OwningLibrary,
    unified_kind_scope: Some("manuscript"),
};

/// implore figure folders (`figure-collection@1.0.0`). The odd one out: the
/// schema has no parent field at all, so both nesting and membership run
/// through the envelope parent.
pub const FIGURE_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "figure-collection",
    parent_field: ParentField::Envelope,
    membership: Membership::EnvelopeParent,
    kind_scope_field: None,
    envelope_parent: EnvelopeParent::TreeParent,
    unified_kind_scope: Some("figure"),
};

/// The generic `collection@1.0.0` kernel schema (ADR-0022 D1).
pub const GENERIC_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: COLLECTION_SCHEMA,
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: Some("kind_scope"),
    envelope_parent: EnvelopeParent::OwningLibrary,
    unified_kind_scope: None,
};

/// Every binding the kernel fronts, in stable order.
pub const ALL_BINDINGS: [CollectionSchemaBinding; 4] = [
    IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
    FIGURE_COLLECTION,
    GENERIC_COLLECTION,
];

/// A binding after the store's `collections.unified` marker has been consulted
/// — the shape every verb below actually works against.
///
/// Built by [`CollectionSchemaBinding::resolved`]; obtained from a live store
/// by [`resolve`]. Marker OFF resolves to the static binding verbatim, which is
/// why the pre-migration behaviour is byte-identical to its pre-G7 self.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolvedBinding {
    /// The `schema_ref` to query and to write.
    pub schema_ref: &'static str,
    /// Where the tree parent is read from and written to.
    pub parent_field: ParentField,
    /// Unchanged by the flip, always.
    pub membership: Membership,
    /// The payload field whose value [`CollectionRow::kind_scope`] reports.
    /// `Some` only for the generic binding, whose scope is genuinely per-row.
    pub kind_scope_field: Option<&'static str>,
    /// The payload `kind_scope` this binding is PINNED to: a filter on every
    /// read, a forced value on every write. `None` = unscoped (marker off, or
    /// the generic binding).
    pub kind_scope: Option<&'static str>,
    /// What to write to the envelope `item.parent`.
    pub envelope_parent: EnvelopeParent,
    /// The marker's state when this was resolved. Reported for diagnostics;
    /// no verb branches on it directly.
    pub unified: bool,
}

impl CollectionSchemaBinding {
    /// Resolve this binding for a store whose convergence marker is `unified`.
    ///
    /// Pure, so the resolution table in the module docs is testable without a
    /// database.
    pub fn resolved(&self, unified: bool) -> ResolvedBinding {
        match (unified, self.unified_kind_scope) {
            // Converged: the legacy schema has no rows of its own left. Query
            // the generic schema, scoped to this binding's kind, through the
            // canonical payload tree field. Membership is untouched.
            (true, Some(kind_scope)) => ResolvedBinding {
                schema_ref: COLLECTION_SCHEMA,
                parent_field: ParentField::Payload("parent_id"),
                membership: self.membership,
                kind_scope_field: self.kind_scope_field,
                kind_scope: Some(kind_scope),
                envelope_parent: self.envelope_parent,
                unified: true,
            },
            _ => ResolvedBinding {
                schema_ref: self.schema_ref,
                parent_field: self.parent_field,
                membership: self.membership,
                kind_scope_field: self.kind_scope_field,
                kind_scope: None,
                envelope_parent: self.envelope_parent,
                unified,
            },
        }
    }
}

/// Resolve a binding against a live store's `collections.unified` marker.
///
/// One indexed `store_metadata` read; every verb does this once, at the top.
pub fn resolve(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
) -> Result<ResolvedBinding, StoreError> {
    Ok(binding.resolved(collection_migration::is_migrated(store)?))
}

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

/// The value the mutated field held BEFORE a single-field structural verb ran.
///
/// One variant per verb rather than three optional fields, because
/// `reparent`'s prior value is legitimately `None` (the collection was a root)
/// and "absent" must not be confusable with "was a root".
#[derive(Debug, Clone, PartialEq)]
pub enum CollectionPrior {
    /// Prior `name`, from [`rename`].
    Name(String),
    /// Prior `sort_order`, from [`reorder`].
    SortOrder(i64),
    /// Prior tree parent, from [`reparent`]. `None` = it was a root.
    Parent(Option<String>),
}

impl CollectionPrior {
    /// The prior name, if this came from [`rename`].
    pub fn name(&self) -> Option<&str> {
        match self {
            CollectionPrior::Name(name) => Some(name),
            _ => None,
        }
    }

    /// The prior sort order, if this came from [`reorder`].
    pub fn sort_order(&self) -> Option<i64> {
        match self {
            CollectionPrior::SortOrder(order) => Some(*order),
            _ => None,
        }
    }

    /// The prior tree parent, if this came from [`reparent`]. The outer
    /// `Option` is "wrong variant", the inner one is "was a root".
    pub fn parent_id(&self) -> Option<Option<&str>> {
        match self {
            CollectionPrior::Parent(parent) => Some(parent.as_deref()),
            _ => None,
        }
    }
}

/// The result of a single-field structural verb: the row as it now stands,
/// plus the prior value needed to undo it. See the module-level undo contract.
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionMutation {
    /// The collection AFTER the change.
    pub row: CollectionRow,
    /// The value the changed field held BEFORE.
    pub prior: CollectionPrior,
}

/// Everything needed to put a deleted collection back exactly as it was —
/// same id, same place in the tree, same members, same children.
///
/// Produced by [`delete`], consumed by [`restore`]. Deliberately structured
/// (rather than an opaque serialized item) so the Swift undo stack can hold it
/// in a value type and read it in the debugger.
#[derive(Debug, Clone, PartialEq)]
pub struct DeletedCollection {
    /// The collection as it was, including its original id.
    pub row: CollectionRow,
    /// The envelope `item.parent` the row carried — the OWNING LIBRARY for
    /// payload-tree bindings, and the same thing as `row.parent_id` for
    /// envelope bindings. Restored verbatim so the row reappears in the
    /// legacy `HasParent` library listings.
    pub envelope_parent_id: Option<String>,
    /// Members whose membership the delete dropped: `Contains` targets (FK
    /// CASCADE) or envelope-filed child items that were unfiled (FK SET NULL).
    /// Never includes sub-collections — those are tree nodes.
    pub member_ids: Vec<String>,
    /// Direct child collections of this binding that were left dangling: for
    /// envelope bindings their `item.parent` was cleared by the FK, for
    /// payload bindings their parent ref now points at a row that is gone.
    /// [`restore`] re-attaches all of them.
    pub child_collection_ids: Vec<String>,
}

// ─── Reads ───────────────────────────────────────────────────────────────────

/// All collections of the bound schema, ordered by `sort_order`.
pub fn list_tree(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
) -> Result<Vec<CollectionRow>, StoreError> {
    let b = resolve(store, binding)?;
    list_tree_resolved(store, &b)
}

fn list_tree_resolved(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
) -> Result<Vec<CollectionRow>, StoreError> {
    let q = ItemQuery {
        schema: Some(b.schema_ref.into()),
        predicates: scope_predicates(b),
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
        .map(|item| row_of(b, item))
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
    let b = resolve(store, binding)?;
    let id = parse_id(collection_id)?;
    load_collection(store, &b, id)?;
    store.query(&member_query(&b, id))
}

/// Member count per collection, aligned with `collection_ids`. Unknown ids
/// count 0 rather than erroring, so a stale sidebar cannot break a refresh.
pub fn member_counts(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_ids: &[String],
) -> Result<Vec<u32>, StoreError> {
    let b = resolve(store, binding)?;
    let mut counts = Vec::with_capacity(collection_ids.len());
    for raw in collection_ids {
        let id = parse_id(raw)?;
        counts.push(match b.membership {
            // Sub-collections nest through the parent field, never through a
            // Contains edge, so every outgoing Contains edge is a member.
            Membership::ContainsEdge => match store.get(id)? {
                Some(item) if is_bound(&b, &item) => item
                    .references
                    .iter()
                    .filter(|r| r.edge_type == EdgeType::Contains)
                    .count() as u32,
                _ => 0,
            },
            Membership::EnvelopeParent => store.count(&member_query(&b, id))? as u32,
        });
    }
    Ok(counts)
}

// ─── Structure ───────────────────────────────────────────────────────────────

/// Create a collection under `parent` (`None` = root).
///
/// `kind_scope` is written only for bindings whose schema has the field; the
/// generic binding defaults it to `"any"`. `sort_order` positions the new row
/// among its siblings: `None` keeps the historical behaviour (`0`, i.e. sort
/// by whatever the caller's tie-break is), `Some(n)` writes `n` — pass the
/// current sibling count to append to the end, which is what implore's figure
/// folders want and used to emulate with a second `reorder` call.
///
/// For payload-tree bindings the new item inherits the parent collection's
/// envelope parent — the owning library — so a kernel-created collection lands
/// in the same library its parent is filed under and stays visible to the
/// legacy `HasParent` listings.
///
/// Once the store has converged (WP G7) a legacy binding writes generic-schema
/// rows carrying its own `kind_scope`, and the caller's `kind_scope` argument
/// is ignored: a figure folder is a figure folder whatever an agent asks for.
///
/// **Undo:** `delete(row.id)`.
pub fn create(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    name: &str,
    parent: Option<&str>,
    kind_scope: Option<&str>,
    sort_order: Option<i64>,
) -> Result<CollectionRow, StoreError> {
    let b = resolve(store, binding)?;
    let parent_id = parent.map(parse_id).transpose()?;
    let parent_item = match parent_id {
        Some(pid) => Some(load_collection(store, &b, pid)?),
        None => None,
    };

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("name".into(), Value::String(name.to_string()));
    payload.insert("sort_order".into(), Value::Int(sort_order.unwrap_or(0)));
    write_kind_scope(&b, &mut payload, kind_scope);
    if let (ParentField::Payload(field), Some(pid)) = (b.parent_field, parent_id) {
        payload.insert(field.into(), Value::String(pid.to_string()));
    }

    let mut item = new_item(store, b.schema_ref, payload);
    item.parent = match b.envelope_parent {
        EnvelopeParent::OwningLibrary => parent_item.as_ref().and_then(|p| p.parent),
        // Figure folders keep nesting through the envelope even once their
        // tree parent also lives in the payload, so envelope-filed membership
        // (`item.parent` of a figure → this folder) keeps working unchanged.
        EnvelopeParent::TreeParent => parent_id,
    };

    store.insert(item.clone())?;
    Ok(row_of(&b, &item))
}

/// Rename a collection.
///
/// **Undo:** `rename(id, mutation.prior.name())`.
pub fn rename(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    name: &str,
) -> Result<CollectionMutation, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(id)?;
    let before = load_collection(store, &b, id)?;
    let prior = CollectionPrior::Name(string_field(&before, "name").unwrap_or_default());
    store.update(
        id,
        vec![FieldMutation::SetPayload(
            "name".into(),
            Value::String(name.to_string()),
        )],
    )?;
    Ok(CollectionMutation {
        row: reload_row(store, &b, id)?,
        prior,
    })
}

/// Move a collection under `new_parent` (`None` = make it a root).
///
/// Rejects self-parenting and any move that would put a collection under one
/// of its own descendants. This check used to live in the Swift sidebar view
/// model, where every caller had to remember it; it is the kernel's now.
///
/// **Undo:** `reparent(id, mutation.prior.parent_id())` — the prior value is
/// `Some(None)` when the collection was a root, which a bare `Option<String>`
/// could not express.
pub fn reparent(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    new_parent: Option<&str>,
) -> Result<CollectionMutation, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(id)?;
    let before = load_collection(store, &b, id)?;
    let prior = CollectionPrior::Parent(tree_parent(&b, &before).map(|p| p.to_string()));
    let new_parent_id = new_parent.map(parse_id).transpose()?;

    if let Some(target) = new_parent_id {
        if target == id {
            return Err(StoreError::Validation(format!(
                "collection {id} cannot be its own parent"
            )));
        }
        let target_item = load_collection(store, &b, target)?;
        let mut cursor = tree_parent(&b, &target_item);
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
                Some(item) => tree_parent(&b, &item),
                None => None,
            };
        }
    }

    let mut mutations = vec![match (b.parent_field, new_parent_id) {
        (ParentField::Payload(field), Some(target)) => {
            FieldMutation::SetPayload(field.into(), Value::String(target.to_string()))
        }
        (ParentField::Payload(field), None) => FieldMutation::RemovePayload(field.into()),
        (ParentField::Envelope, target) => FieldMutation::SetParent(target),
    }];
    // Converged figure folders read their tree parent from the payload but
    // still nest on the envelope; the two must not drift apart, or a move
    // would leave the folder's figures filed under the OLD parent's subtree.
    if mirrors_tree_parent_onto_envelope(&b) {
        mutations.push(FieldMutation::SetParent(new_parent_id));
    }
    store.update(id, mutations)?;
    Ok(CollectionMutation {
        row: reload_row(store, &b, id)?,
        prior,
    })
}

/// Set a collection's position among its siblings.
///
/// **Undo:** `reorder(id, mutation.prior.sort_order())`.
pub fn reorder(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    sort_order: i64,
) -> Result<CollectionMutation, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(id)?;
    let before = load_collection(store, &b, id)?;
    let prior = CollectionPrior::SortOrder(int_field(&before, "sort_order").unwrap_or(0));
    store.update(
        id,
        vec![FieldMutation::SetPayload(
            "sort_order".into(),
            Value::Int(sort_order),
        )],
    )?;
    Ok(CollectionMutation {
        row: reload_row(store, &b, id)?,
        prior,
    })
}

/// Delete a collection. Members are never deleted — only the membership goes
/// away: `Contains` edges vanish with the row (FK CASCADE) and envelope-filed
/// members are unfiled (FK SET NULL). Not idempotent: deleting a missing
/// collection returns `NotFound`, matching `delete_collection` in imbib-core.
///
/// Returns the snapshot the delete consumed. **Undo:** `restore(snapshot)`,
/// which puts the row back under its original id with its members and child
/// collections re-attached.
pub fn delete(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
) -> Result<DeletedCollection, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(id)?;
    let item = load_collection(store, &b, id)?;
    let row = row_of(&b, &item);

    // Membership the delete is about to drop. `member_query` already excludes
    // sub-collections for envelope bindings; Contains edges never point at
    // sub-collections in the first place (nesting runs through the parent).
    let member_ids: Vec<String> = match b.membership {
        Membership::ContainsEdge => item
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::Contains)
            .map(|r| r.target.to_string())
            .collect(),
        Membership::EnvelopeParent => store
            .query(&member_query(&b, id))?
            .iter()
            .map(|i| i.id.to_string())
            .collect(),
    };

    // Direct children, whose parent pointer the delete invalidates (cleared by
    // the FK for envelope bindings, left dangling for payload bindings).
    let parent_ref = row.id.as_str();
    let child_collection_ids: Vec<String> = list_tree_resolved(store, &b)?
        .into_iter()
        .filter(|r| r.parent_id.as_deref() == Some(parent_ref))
        .map(|r| r.id)
        .collect();

    store.delete(id)?;

    Ok(DeletedCollection {
        row,
        envelope_parent_id: item.parent.map(|p| p.to_string()),
        member_ids,
        child_collection_ids,
    })
}

/// Put a deleted collection back, exactly as [`delete`] found it.
///
/// Recreates the row under its ORIGINAL id (the store takes explicit ids —
/// items carry theirs), re-files its members and re-attaches the child
/// collections whose parent pointer the delete invalidated. Only the envelope
/// timestamps are new; nothing else about the row changes, so an undone delete
/// leaves `list_tree` and membership byte-identical.
///
/// Tolerant where undo has to be: member and child ids that no longer exist
/// (deleted in between) are skipped rather than failing the restore. Restoring
/// over a live id is an error — that is a double-undo, not a repair.
///
/// **Undo:** `delete(row.id)`.
pub fn restore(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    snapshot: &DeletedCollection,
) -> Result<CollectionRow, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(&snapshot.row.id)?;
    if store.get(id)?.is_some() {
        return Err(StoreError::Validation(format!(
            "cannot restore collection {id}: an item with that id already exists"
        )));
    }

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("name".into(), Value::String(snapshot.row.name.clone()));
    payload.insert("sort_order".into(), Value::Int(snapshot.row.sort_order));
    write_kind_scope(&b, &mut payload, snapshot.row.kind_scope.as_deref());
    if let (ParentField::Payload(field), Some(parent)) =
        (b.parent_field, snapshot.row.parent_id.as_deref())
    {
        payload.insert(field.into(), Value::String(parse_id(parent)?.to_string()));
    }

    let mut item = new_item(store, b.schema_ref, payload);
    item.id = id;
    item.parent = snapshot
        .envelope_parent_id
        .as_deref()
        .map(parse_id)
        .transpose()?;
    store.insert(item)?;

    // Re-file the members the delete unfiled / whose edges it cascaded away.
    for raw in &snapshot.member_ids {
        let member = parse_id(raw)?;
        if store.get(member)?.is_none() {
            continue;
        }
        match b.membership {
            Membership::ContainsEdge => store.update(
                id,
                vec![FieldMutation::AddReference(TypedReference {
                    target: member,
                    edge_type: EdgeType::Contains,
                    metadata: None,
                })],
            )?,
            Membership::EnvelopeParent => {
                store.update(member, vec![FieldMutation::SetParent(Some(id))])?
            }
        }
    }

    // Re-attach the children. For payload bindings their ref still names this
    // id and the write is a no-op; for envelope bindings the FK nulled it. A
    // converged figure folder needs BOTH: its payload ref survived the delete,
    // its envelope did not.
    for raw in &snapshot.child_collection_ids {
        let child = parse_id(raw)?;
        match store.get(child)? {
            Some(item) if is_bound(&b, &item) => {}
            _ => continue,
        }
        let mut mutations = vec![match b.parent_field {
            ParentField::Payload(field) => {
                FieldMutation::SetPayload(field.into(), Value::String(id.to_string()))
            }
            ParentField::Envelope => FieldMutation::SetParent(Some(id)),
        }];
        if mirrors_tree_parent_onto_envelope(&b) {
            mutations.push(FieldMutation::SetParent(Some(id)));
        }
        store.update(child, mutations)?;
    }

    reload_row(store, &b, id)
}

// ─── Membership ──────────────────────────────────────────────────────────────

/// Add items to a collection. Idempotent per member.
///
/// Returns the ids that ACTUALLY became members, in the order given —
/// re-adding an existing member reports nothing, so the caller can register an
/// inverse that removes only what this call added.
///
/// **Undo:** `remove_members(collection_id, changed)`.
pub fn add_members(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_id: &str,
    item_ids: &[String],
) -> Result<Vec<String>, StoreError> {
    let b = resolve(store, binding)?;
    let collection = parse_id(collection_id)?;
    let item = load_collection(store, &b, collection)?;
    let mut members = contains_members(&item);
    let mut changed = Vec::new();
    for raw in item_ids {
        let member = parse_id(raw)?;
        match b.membership {
            Membership::ContainsEdge => {
                if members.contains(&member) {
                    continue;
                }
                store.update(
                    collection,
                    vec![FieldMutation::AddReference(TypedReference {
                        target: member,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    })],
                )?;
                members.push(member);
            }
            Membership::EnvelopeParent => {
                let filed_here = store
                    .get(member)?
                    .map(|i| i.parent == Some(collection))
                    .unwrap_or(false);
                if filed_here {
                    continue;
                }
                store.update(member, vec![FieldMutation::SetParent(Some(collection))])?;
            }
        }
        changed.push(member.to_string());
    }
    Ok(changed)
}

/// Remove items from a collection without touching the items themselves.
///
/// Returns the ids that were ACTUALLY removed, in the order given: ids that
/// were not members are skipped, and envelope-filed items that live in a
/// different collection are left alone rather than unfiled.
///
/// **Undo:** `add_members(collection_id, changed)`.
pub fn remove_members(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    collection_id: &str,
    item_ids: &[String],
) -> Result<Vec<String>, StoreError> {
    let b = resolve(store, binding)?;
    let collection = parse_id(collection_id)?;
    let item = load_collection(store, &b, collection)?;
    let members = contains_members(&item);
    let mut changed = Vec::new();
    for raw in item_ids {
        let member = parse_id(raw)?;
        match b.membership {
            Membership::ContainsEdge => {
                if !members.contains(&member) {
                    continue;
                }
                store.update(
                    collection,
                    vec![FieldMutation::RemoveReference(member, EdgeType::Contains)],
                )?;
            }
            Membership::EnvelopeParent => {
                let filed_here = store
                    .get(member)?
                    .map(|item| item.parent == Some(collection))
                    .unwrap_or(false);
                if !filed_here {
                    continue;
                }
                store.update(member, vec![FieldMutation::SetParent(None)])?;
            }
        }
        changed.push(member.to_string());
    }
    Ok(changed)
}

// ─── Internals ───────────────────────────────────────────────────────────────

fn parse_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id).map_err(|_| StoreError::Validation(format!("invalid UUID: {id}")))
}

/// The `kind_scope` predicate a converged legacy binding needs, and nothing at
/// all for an unscoped one. Empty pre-migration, so the query the store sees is
/// literally the pre-G7 query.
fn scope_predicates(b: &ResolvedBinding) -> Vec<Predicate> {
    match b.kind_scope {
        Some(scope) => vec![Predicate::Eq(
            "payload.kind_scope".into(),
            Value::String(scope.to_string()),
        )],
        None => vec![],
    }
}

/// Does this item belong to the resolved binding — right schema, and (once
/// converged) right `kind_scope`?
fn is_bound(b: &ResolvedBinding, item: &Item) -> bool {
    if item.schema != b.schema_ref {
        return false;
    }
    match b.kind_scope {
        Some(scope) => string_field(item, "kind_scope").as_deref() == Some(scope),
        None => true,
    }
}

/// Must a tree-parent write be mirrored onto the envelope?
///
/// Only for a CONVERGED figure binding: its tree parent moved into the payload
/// while its membership stayed on the envelope, so both have to move together.
/// Pre-migration the single `SetParent` already IS the tree write, and mirroring
/// would emit it twice.
fn mirrors_tree_parent_onto_envelope(b: &ResolvedBinding) -> bool {
    b.envelope_parent == EnvelopeParent::TreeParent
        && matches!(b.parent_field, ParentField::Payload(_))
}

/// Write the `kind_scope` payload field.
///
/// A converged legacy binding FORCES its own scope (the caller does not get to
/// turn a figure folder into a publication folder). The generic binding takes
/// the caller's value, defaulting to `"any"`. An unconverged legacy binding has
/// no such field and writes nothing.
fn write_kind_scope(
    b: &ResolvedBinding,
    payload: &mut BTreeMap<String, Value>,
    requested: Option<&str>,
) {
    if let Some(scope) = b.kind_scope {
        payload.insert("kind_scope".into(), Value::String(scope.to_string()));
    } else if let Some(field) = b.kind_scope_field {
        payload.insert(
            field.into(),
            Value::String(requested.unwrap_or(KIND_SCOPE_ANY).to_string()),
        );
    }
}

/// Fetch an item and assert it is a collection of the bound schema (and, once
/// converged, of the binding's `kind_scope`).
fn load_collection(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    id: ItemId,
) -> Result<Item, StoreError> {
    let item = store.get(id)?.ok_or(StoreError::NotFound(id))?;
    if !is_bound(b, &item) {
        return Err(StoreError::Validation(format!(
            "item {id} has schema '{}'{}, expected '{}'{}",
            item.schema,
            describe_scope(string_field(&item, "kind_scope").as_deref()),
            b.schema_ref,
            describe_scope(b.kind_scope),
        )));
    }
    Ok(item)
}

fn describe_scope(scope: Option<&str>) -> String {
    scope
        .map(|s| format!(" kind_scope '{s}'"))
        .unwrap_or_default()
}

/// The collection's current `Contains` targets. Empty for envelope bindings,
/// which record membership on the member instead.
fn contains_members(collection: &Item) -> Vec<ItemId> {
    collection
        .references
        .iter()
        .filter(|r| r.edge_type == EdgeType::Contains)
        .map(|r| r.target)
        .collect()
}

fn reload_row(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    id: ItemId,
) -> Result<CollectionRow, StoreError> {
    let item = load_collection(store, b, id)?;
    Ok(row_of(b, &item))
}

fn row_of(b: &ResolvedBinding, item: &Item) -> CollectionRow {
    CollectionRow {
        id: item.id.to_string(),
        name: string_field(item, "name").unwrap_or_default(),
        parent_id: tree_parent(b, item).map(|p| p.to_string()),
        sort_order: int_field(item, "sort_order").unwrap_or(0),
        // Deliberately the STATIC field, not the resolved scope: a converged
        // legacy binding keeps reporting `None` so the row shape every FFI
        // caller sees does not change under them at the flip.
        kind_scope: b
            .kind_scope_field
            .and_then(|field| string_field(item, field)),
    }
}

/// The collection's tree parent — payload ref or envelope parent per the
/// binding. Payload refs are parsed rather than compared as raw strings, so a
/// legacy uppercase ref still resolves and comes back lowercase.
fn tree_parent(b: &ResolvedBinding, item: &Item) -> Option<ItemId> {
    match b.parent_field {
        ParentField::Payload(field) => string_field(item, field)
            .filter(|s| !s.is_empty())
            .and_then(|s| Uuid::parse_str(&s).ok()),
        ParentField::Envelope => item.parent,
    }
}

/// Query selecting a collection's members.
fn member_query(b: &ResolvedBinding, collection: ItemId) -> ItemQuery {
    let predicates = match b.membership {
        Membership::ContainsEdge => vec![Predicate::ReferencedBy(EdgeType::Contains, collection)],
        // Envelope children include nested sub-collections; those are tree
        // nodes, not members. Post-convergence the excluded schema is the
        // generic one, which still catches every sub-folder — and now also
        // any native generic collection that happens to be filed here.
        Membership::EnvelopeParent => vec![
            Predicate::HasParent(collection),
            Predicate::Neq("schema_ref".into(), Value::String(b.schema_ref.to_string())),
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
        let a = create(&store, &GENERIC_COLLECTION, "A", None, None, None).unwrap();
        let err = reparent(&store, &GENERIC_COLLECTION, &a.id, Some(&a.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("own parent")),
            "self-parent must be rejected, got {err:?}"
        );
    }

    #[test]
    fn reparent_rejects_direct_child() {
        let store = open();
        let parent = create(&store, &GENERIC_COLLECTION, "Parent", None, None, None).unwrap();
        let child = create(
            &store,
            &GENERIC_COLLECTION,
            "Child",
            Some(&parent.id),
            None,
            None,
        )
        .unwrap();

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
        let a = create(&store, &GENERIC_COLLECTION, "A", None, None, None).unwrap();
        let b = create(&store, &GENERIC_COLLECTION, "B", Some(&a.id), None, None).unwrap();
        let c = create(&store, &GENERIC_COLLECTION, "C", Some(&b.id), None, None).unwrap();
        let d = create(&store, &GENERIC_COLLECTION, "D", Some(&c.id), None, None).unwrap();

        let err = reparent(&store, &GENERIC_COLLECTION, &a.id, Some(&d.id));
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("cycle")),
            "moving a root under its grandchild's child must be rejected, got {err:?}"
        );
        // A sibling move that is NOT a cycle still works.
        let e = create(&store, &GENERIC_COLLECTION, "E", None, None, None).unwrap();
        let moved = reparent(&store, &GENERIC_COLLECTION, &e.id, Some(&d.id)).unwrap();
        assert_eq!(moved.row.parent_id, Some(d.id));
    }

    #[test]
    fn reparent_cycle_check_walks_envelope_chain_for_figures() {
        let store = open();
        let parent = create(&store, &FIGURE_COLLECTION, "Plots", None, None, None).unwrap();
        let child = create(
            &store,
            &FIGURE_COLLECTION,
            "Panels",
            Some(&parent.id),
            None,
            None,
        )
        .unwrap();
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
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, Some("any"), None).unwrap();
        let child = create(
            &store,
            &GENERIC_COLLECTION,
            "Child",
            Some(&root.id),
            Some("publication"),
            None,
        )
        .unwrap();

        assert_eq!(root.kind_scope.as_deref(), Some("any"));
        assert_eq!(child.kind_scope.as_deref(), Some("publication"));
        assert_eq!(child.parent_id, Some(root.id.clone()));
        assert_eq!(root.sort_order, 0);

        let renamed = rename(&store, &GENERIC_COLLECTION, &child.id, "Renamed").unwrap();
        assert_eq!(renamed.row.name, "Renamed");
        assert_eq!(renamed.prior.name(), Some("Child"));

        let reordered = reorder(&store, &GENERIC_COLLECTION, &child.id, 7).unwrap();
        assert_eq!(reordered.row.sort_order, 7);
        assert_eq!(reordered.prior.sort_order(), Some(0));

        let unparented = reparent(&store, &GENERIC_COLLECTION, &child.id, None).unwrap();
        assert_eq!(unparented.row.parent_id, None);
        assert_eq!(
            unparented.prior.parent_id(),
            Some(Some(root.id.as_str())),
            "the prior parent is what undo moves it back to"
        );
        let reparented = reparent(&store, &GENERIC_COLLECTION, &child.id, Some(&root.id)).unwrap();
        assert_eq!(reparented.row.parent_id, Some(root.id.clone()));
        assert_eq!(
            reparented.prior.parent_id(),
            Some(None),
            "'was a root' is distinguishable from 'no prior value'"
        );

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
        let workspace = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Workspace",
            None,
            None,
            None,
        )
        .unwrap();
        let folder = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Drafts",
            Some(&workspace.id),
            None,
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
            add_members(
                &store,
                &MANUSCRIPT_COLLECTION,
                &folder.id,
                std::slice::from_ref(&ms)
            )
            .unwrap(),
            vec![ms.clone()]
        );
        assert_eq!(
            member_counts(
                &store,
                &MANUSCRIPT_COLLECTION,
                std::slice::from_ref(&folder.id)
            )
            .unwrap(),
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

        let root = create(&store, &IMBIB_COLLECTION, "Reading", None, None, None).unwrap();
        store
            .update(
                parse_id(&root.id).unwrap(),
                vec![FieldMutation::SetParent(Some(library_id))],
            )
            .unwrap();

        let child = create(
            &store,
            &IMBIB_COLLECTION,
            "Queue",
            Some(&root.id),
            None,
            None,
        )
        .unwrap();
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
            None,
        )
        .unwrap();
        let other = create(&store, &GENERIC_COLLECTION, "Empty", None, None, None).unwrap();

        let manuscript = make_item(&store, "manuscript", "Draft II");
        let figure = make_item(&store, "figure", "Rotation curve");

        let added = add_members(
            &store,
            &GENERIC_COLLECTION,
            &mixed.id,
            &[manuscript.clone(), figure.clone()],
        )
        .unwrap();
        assert_eq!(added, vec![manuscript.clone(), figure.clone()]);

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
        assert!(
            add_members(
                &store,
                &GENERIC_COLLECTION,
                &mixed.id,
                std::slice::from_ref(&figure)
            )
            .unwrap()
            .is_empty(),
            "an already-filed member reports no change, so undo removes nothing"
        );
        assert_eq!(
            member_counts(&store, &GENERIC_COLLECTION, std::slice::from_ref(&mixed.id)).unwrap(),
            vec![2],
            "re-adding an existing member must not duplicate it"
        );

        // Removing a non-member is likewise a no-op the caller can see.
        let stranger = make_item(&store, "figure", "Never filed");
        assert!(
            remove_members(&store, &GENERIC_COLLECTION, &mixed.id, &[stranger])
                .unwrap()
                .is_empty(),
            "removing a non-member reports no change"
        );

        assert_eq!(
            remove_members(
                &store,
                &GENERIC_COLLECTION,
                &mixed.id,
                std::slice::from_ref(&figure)
            )
            .unwrap(),
            vec![figure]
        );
        let members = list_members(&store, &GENERIC_COLLECTION, &mixed.id).unwrap();
        assert_eq!(members.len(), 1);
        assert_eq!(members[0].id.to_string(), manuscript);
    }

    #[test]
    fn figure_membership_uses_envelope_parent() {
        let store = open();
        let folder = create(
            &store,
            &FIGURE_COLLECTION,
            "Paper figures",
            None,
            None,
            None,
        )
        .unwrap();
        let nested = create(
            &store,
            &FIGURE_COLLECTION,
            "Supplement",
            Some(&folder.id),
            None,
            None,
        )
        .unwrap();
        let figure = make_item(&store, "figure", "Panel A");

        add_members(
            &store,
            &FIGURE_COLLECTION,
            &folder.id,
            std::slice::from_ref(&figure),
        )
        .unwrap();
        let filed = store.get(parse_id(&figure).unwrap()).unwrap().unwrap();
        assert_eq!(filed.parent, Some(parse_id(&folder.id).unwrap()));
        assert_eq!(
            member_counts(&store, &FIGURE_COLLECTION, std::slice::from_ref(&folder.id)).unwrap(),
            vec![1],
            "the nested folder is a tree node, not a member"
        );
        assert!(nested.parent_id.is_some());

        // Removing a figure filed elsewhere is a no-op, not an unfile.
        assert!(remove_members(
            &store,
            &FIGURE_COLLECTION,
            &nested.id,
            std::slice::from_ref(&figure)
        )
        .unwrap()
        .is_empty());
        assert_eq!(
            remove_members(
                &store,
                &FIGURE_COLLECTION,
                &folder.id,
                std::slice::from_ref(&figure)
            )
            .unwrap(),
            vec![figure.clone()]
        );
        let unfiled = store.get(parse_id(&figure).unwrap()).unwrap().unwrap();
        assert_eq!(unfiled.parent, None);
    }

    // ─── Binding hygiene ─────────────────────────────────────────────────

    #[test]
    fn bindings_reject_items_of_another_schema() {
        let store = open();
        let generic = create(&store, &GENERIC_COLLECTION, "Mixed", None, None, None).unwrap();
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
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, None, None).unwrap();
        let upper = root.id.to_uppercase();

        let child = create(
            &store,
            &GENERIC_COLLECTION,
            "Child",
            Some(&upper),
            None,
            None,
        )
        .unwrap();
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
            create(
                &store,
                &GENERIC_COLLECTION,
                "Orphan",
                Some(&missing),
                None,
                None
            ),
            Err(StoreError::NotFound(_))
        ));
        assert!(matches!(
            create(
                &store,
                &GENERIC_COLLECTION,
                "Orphan",
                Some("not-a-uuid"),
                None,
                None
            ),
            Err(StoreError::Validation(_))
        ));
    }

    // ─── sort_order at create time ───────────────────────────────────────

    #[test]
    fn create_writes_the_requested_sort_order() {
        let store = open();
        let first = create(&store, &FIGURE_COLLECTION, "First", None, None, None).unwrap();
        assert_eq!(first.sort_order, 0, "None keeps the historical default");

        // What implore's figure folders want: append to the end, in one call
        // instead of create-then-reorder.
        let second = create(&store, &FIGURE_COLLECTION, "Second", None, None, Some(1)).unwrap();
        let third = create(&store, &FIGURE_COLLECTION, "Third", None, None, Some(2)).unwrap();
        assert_eq!(second.sort_order, 1);
        assert_eq!(third.sort_order, 2);
        assert_eq!(
            names(&list_tree(&store, &FIGURE_COLLECTION).unwrap()),
            vec!["First", "Second", "Third"],
            "list_tree orders by the sort_order create wrote"
        );

        // Negative and beyond-the-end values are the caller's business.
        let pinned = create(&store, &FIGURE_COLLECTION, "Pinned", None, None, Some(-1)).unwrap();
        assert_eq!(pinned.sort_order, -1);
        assert_eq!(
            names(&list_tree(&store, &FIGURE_COLLECTION).unwrap())[0],
            "Pinned"
        );
    }

    // ─── Undoable delete ─────────────────────────────────────────────────

    /// `list_tree` sorted by id, so a before/after comparison does not depend
    /// on how equal `sort_order`s happen to tie-break.
    fn tree_by_id(
        store: &SqliteItemStore,
        binding: &CollectionSchemaBinding,
    ) -> Vec<CollectionRow> {
        let mut rows = list_tree(store, binding).unwrap();
        rows.sort_by(|a, b| a.id.cmp(&b.id));
        rows
    }

    fn member_ids(
        store: &SqliteItemStore,
        binding: &CollectionSchemaBinding,
        collection: &str,
    ) -> Vec<String> {
        let mut ids: Vec<String> = list_members(store, binding, collection)
            .unwrap()
            .iter()
            .map(|i| i.id.to_string())
            .collect();
        ids.sort();
        ids
    }

    #[test]
    fn delete_restore_round_trips_a_contains_binding() {
        let store = open();
        let library = make_item(&store, "imbib/library", "Main");
        let library_id = parse_id(&library).unwrap();

        let workspace = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Workspace",
            None,
            None,
            None,
        )
        .unwrap();
        store
            .update(
                parse_id(&workspace.id).unwrap(),
                vec![FieldMutation::SetParent(Some(library_id))],
            )
            .unwrap();
        let folder = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Drafts",
            Some(&workspace.id),
            None,
            Some(3),
        )
        .unwrap();
        let nested = create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Submitted",
            Some(&folder.id),
            None,
            None,
        )
        .unwrap();
        let a = make_item(&store, "manuscript", "Paper A");
        let b = make_item(&store, "manuscript", "Paper B");
        add_members(
            &store,
            &MANUSCRIPT_COLLECTION,
            &folder.id,
            &[a.clone(), b.clone()],
        )
        .unwrap();

        let before_tree = tree_by_id(&store, &MANUSCRIPT_COLLECTION);
        let before_members = member_ids(&store, &MANUSCRIPT_COLLECTION, &folder.id);

        let snapshot = delete(&store, &MANUSCRIPT_COLLECTION, &folder.id).unwrap();
        assert_eq!(snapshot.row, folder);
        assert_eq!(
            snapshot.envelope_parent_id,
            Some(library_id.to_string()),
            "the owning library must survive the round trip"
        );
        let mut snapshot_members = snapshot.member_ids.clone();
        snapshot_members.sort();
        assert_eq!(snapshot_members, before_members);
        assert_eq!(snapshot.child_collection_ids, vec![nested.id.clone()]);
        assert_eq!(list_tree(&store, &MANUSCRIPT_COLLECTION).unwrap().len(), 2);

        let restored = restore(&store, &MANUSCRIPT_COLLECTION, &snapshot).unwrap();
        assert_eq!(restored, folder, "restored under its ORIGINAL id");
        assert_eq!(
            tree_by_id(&store, &MANUSCRIPT_COLLECTION),
            before_tree,
            "an undone delete leaves the tree byte-identical"
        );
        assert_eq!(
            member_ids(&store, &MANUSCRIPT_COLLECTION, &folder.id),
            before_members
        );
        let item = store.get(parse_id(&folder.id).unwrap()).unwrap().unwrap();
        assert_eq!(item.parent, Some(library_id));
        assert_eq!(
            member_counts(
                &store,
                &MANUSCRIPT_COLLECTION,
                std::slice::from_ref(&folder.id)
            )
            .unwrap(),
            vec![2]
        );

        // Restoring twice is a double-undo, not a repair.
        assert!(matches!(
            restore(&store, &MANUSCRIPT_COLLECTION, &snapshot),
            Err(StoreError::Validation(ref m)) if m.contains("already exists")
        ));
    }

    #[test]
    fn delete_restore_round_trips_the_envelope_binding() {
        let store = open();
        let folder = create(
            &store,
            &FIGURE_COLLECTION,
            "Paper figures",
            None,
            None,
            None,
        )
        .unwrap();
        let nested = create(
            &store,
            &FIGURE_COLLECTION,
            "Supplement",
            Some(&folder.id),
            None,
            Some(2),
        )
        .unwrap();
        let panel = make_item(&store, "figure", "Panel A");
        let curve = make_item(&store, "figure", "Rotation curve");
        add_members(
            &store,
            &FIGURE_COLLECTION,
            &folder.id,
            &[panel.clone(), curve.clone()],
        )
        .unwrap();

        let before_tree = tree_by_id(&store, &FIGURE_COLLECTION);
        let before_members = member_ids(&store, &FIGURE_COLLECTION, &folder.id);

        let snapshot = delete(&store, &FIGURE_COLLECTION, &folder.id).unwrap();
        let mut snapshot_members = snapshot.member_ids.clone();
        snapshot_members.sort();
        assert_eq!(
            snapshot_members, before_members,
            "the unfiled figures are the snapshot's members"
        );
        assert_eq!(snapshot.child_collection_ids, vec![nested.id.clone()]);

        // The FK really did unfile everything: figures and the sub-folder.
        assert_eq!(
            store
                .get(parse_id(&panel).unwrap())
                .unwrap()
                .unwrap()
                .parent,
            None
        );
        assert_eq!(
            row(&list_tree(&store, &FIGURE_COLLECTION).unwrap(), &nested.id).parent_id,
            None
        );

        let restored = restore(&store, &FIGURE_COLLECTION, &snapshot).unwrap();
        assert_eq!(restored, folder);
        assert_eq!(
            tree_by_id(&store, &FIGURE_COLLECTION),
            before_tree,
            "the sub-folder is re-attached to the restored parent"
        );
        assert_eq!(
            member_ids(&store, &FIGURE_COLLECTION, &folder.id),
            before_members,
            "the figures are re-filed, and the sub-folder is still not a member"
        );
        assert_eq!(
            member_counts(&store, &FIGURE_COLLECTION, std::slice::from_ref(&folder.id)).unwrap(),
            vec![2]
        );
    }

    #[test]
    fn restore_skips_members_that_are_gone() {
        let store = open();
        let folder = create(&store, &GENERIC_COLLECTION, "Reading", None, None, None).unwrap();
        let kept = make_item(&store, "manuscript", "Kept");
        let doomed = make_item(&store, "manuscript", "Doomed");
        add_members(
            &store,
            &GENERIC_COLLECTION,
            &folder.id,
            &[kept.clone(), doomed.clone()],
        )
        .unwrap();

        let snapshot = delete(&store, &GENERIC_COLLECTION, &folder.id).unwrap();
        store.delete(parse_id(&doomed).unwrap()).unwrap();

        // Undo must still work when the world moved on underneath it.
        restore(&store, &GENERIC_COLLECTION, &snapshot).unwrap();
        assert_eq!(
            member_ids(&store, &GENERIC_COLLECTION, &folder.id),
            vec![kept]
        );
    }

    // ─── The D9 gate ─────────────────────────────────────────────────────

    /// **ADR-0022 D9 gate: the store half of "impress is proven, not shipped".**
    ///
    /// The impress app does not exist, and will not for a while. What has to
    /// exist NOW is the property it is built on: one collection holding records
    /// of several kinds at once, surviving the whole verb set. Before the
    /// kernel, this was impossible by construction — four schema-specific
    /// hierarchies, each of which could only hold its own kind (D1's opening
    /// premise). This test is the assertion that it is possible, and that no
    /// verb quietly forgets a kind on the way through.
    ///
    /// Three schemas on purpose (`AppShellConfiguration.impress` binds all of
    /// them to sections): a publication, a manuscript and a figure — three
    /// different apps' record kinds in one folder. Two of them are kinds whose
    /// OWN collection binding stores membership differently
    /// (`figure-collection` files members through the envelope parent), so a
    /// generic collection holding a figure is exactly the case a per-kind
    /// implementation could not express.
    #[test]
    fn impress_gate_mixed_kind_collection_round_trip() {
        let store = open();

        let shelf = create(
            &store,
            &GENERIC_COLLECTION,
            "Cluster paper",
            None,
            Some(KIND_SCOPE_ANY),
            None,
        )
        .unwrap();
        let sibling = create(&store, &GENERIC_COLLECTION, "Unrelated", None, None, None).unwrap();
        assert_eq!(shelf.kind_scope.as_deref(), Some("any"));

        // One member per record kind, each with the schema its own app writes.
        let publication = make_item(&store, "imbib/bibliography-entry", "Bardeen et al. 1986");
        let manuscript = make_item(&store, "manuscript", "Draft II");
        let figure = make_item(&store, "figure", "Rotation curve");

        let added = add_members(
            &store,
            &GENERIC_COLLECTION,
            &shelf.id,
            &[publication.clone(), manuscript.clone(), figure.clone()],
        )
        .unwrap();
        assert_eq!(
            added,
            vec![publication.clone(), manuscript.clone(), figure.clone()],
            "every kind is filed; none is skipped for being the wrong kind"
        );

        // ─ list_members returns ALL THREE kinds ─
        let members = list_members(&store, &GENERIC_COLLECTION, &shelf.id).unwrap();
        let mut schemas: Vec<&str> = members.iter().map(|i| i.schema.as_str()).collect();
        schemas.sort_unstable();
        assert_eq!(
            schemas,
            vec!["figure", "imbib/bibliography-entry", "manuscript"],
            "a kind_scope=any collection is heterogeneous by construction"
        );

        // ─ member_counts, aligned with the ids asked for ─
        assert_eq!(
            member_counts(
                &store,
                &GENERIC_COLLECTION,
                &[shelf.id.clone(), sibling.id.clone()]
            )
            .unwrap(),
            vec![3, 0],
            "counts must not depend on the members' kinds"
        );

        // ─ rename round trip, through the prior value undo would use ─
        let renamed = rename(
            &store,
            &GENERIC_COLLECTION,
            &shelf.id,
            "Cluster paper (final)",
        )
        .unwrap();
        assert_eq!(renamed.row.name, "Cluster paper (final)");
        assert_eq!(renamed.prior.name(), Some("Cluster paper"));
        let undone = rename(
            &store,
            &GENERIC_COLLECTION,
            &shelf.id,
            renamed.prior.name().unwrap(),
        )
        .unwrap();
        assert_eq!(
            undone.row, shelf,
            "an undone rename restores the row exactly"
        );

        // ─ reparent round trip: the mixed collection is an ordinary tree node ─
        let project = create(&store, &GENERIC_COLLECTION, "2026", None, None, None).unwrap();
        let moved = reparent(&store, &GENERIC_COLLECTION, &shelf.id, Some(&project.id)).unwrap();
        assert_eq!(moved.row.parent_id, Some(project.id.clone()));
        assert_eq!(
            moved.prior.parent_id(),
            Some(None),
            "'was a root' is what undo needs, and is not 'no prior value'"
        );
        assert_eq!(
            member_ids(&store, &GENERIC_COLLECTION, &shelf.id).len(),
            3,
            "moving a collection must not disturb its membership"
        );
        let back = reparent(&store, &GENERIC_COLLECTION, &shelf.id, None).unwrap();
        assert_eq!(back.row, shelf, "the tree is exactly where it started");

        // ─ delete → restore brings the MIXED membership back intact ─
        let before_members = member_ids(&store, &GENERIC_COLLECTION, &shelf.id);
        let before_tree = tree_by_id(&store, &GENERIC_COLLECTION);

        let snapshot = delete(&store, &GENERIC_COLLECTION, &shelf.id).unwrap();
        assert_eq!(snapshot.row, shelf);
        assert_eq!(
            snapshot.row.kind_scope.as_deref(),
            Some("any"),
            "the scope is part of the snapshot, or the restored collection stops being mixed"
        );
        let mut snapshot_members = snapshot.member_ids.clone();
        snapshot_members.sort();
        assert_eq!(snapshot_members, before_members);
        // Members outlive the collection — only the membership went away.
        for member in [&publication, &manuscript, &figure] {
            assert!(
                store.get(parse_id(member).unwrap()).unwrap().is_some(),
                "deleting a collection must never delete a member ({member})"
            );
        }

        let restored = restore(&store, &GENERIC_COLLECTION, &snapshot).unwrap();
        assert_eq!(
            restored, shelf,
            "restored under its ORIGINAL id, scope included"
        );
        assert_eq!(
            tree_by_id(&store, &GENERIC_COLLECTION),
            before_tree,
            "an undone delete leaves the tree byte-identical"
        );
        assert_eq!(
            member_ids(&store, &GENERIC_COLLECTION, &shelf.id),
            before_members,
            "all three kinds are re-filed"
        );

        let members = list_members(&store, &GENERIC_COLLECTION, &shelf.id).unwrap();
        let mut schemas: Vec<&str> = members.iter().map(|i| i.schema.as_str()).collect();
        schemas.sort_unstable();
        assert_eq!(
            schemas,
            vec!["figure", "imbib/bibliography-entry", "manuscript"],
            "the restored collection is still mixed, not merely non-empty"
        );
        assert_eq!(
            member_counts(&store, &GENERIC_COLLECTION, std::slice::from_ref(&shelf.id)).unwrap(),
            vec![3]
        );
    }

    /// The G7 dual-mode switch must be INERT until somebody flips it. Every
    /// other test in this module runs against an unmarked store and would
    /// notice a behaviour change; this one states the invariant out loud, and
    /// pins the exact resolution an unmarked store produces.
    #[test]
    fn an_unmarked_store_resolves_every_binding_to_its_legacy_self() {
        let store = open();
        assert!(!crate::collection_migration::is_migrated(&store).unwrap());
        for binding in ALL_BINDINGS {
            let resolved = resolve(&store, &binding).unwrap();
            assert!(!resolved.unified, "{}", binding.schema_ref);
            assert_eq!(resolved.schema_ref, binding.schema_ref);
            assert_eq!(resolved.parent_field, binding.parent_field);
            assert_eq!(resolved.membership, binding.membership);
            assert_eq!(resolved.kind_scope_field, binding.kind_scope_field);
            assert_eq!(
                resolved.kind_scope, None,
                "{}: no scope filter is applied before the flip",
                binding.schema_ref
            );
            assert!(
                !mirrors_tree_parent_onto_envelope(&resolved),
                "{}: no extra envelope write before the flip",
                binding.schema_ref
            );
            assert!(
                scope_predicates(&resolved).is_empty(),
                "{}: the query is literally the pre-G7 query",
                binding.schema_ref
            );
        }
    }

    #[test]
    fn author_matches_store_default() {
        let store = open();
        let root = create(&store, &GENERIC_COLLECTION, "Root", None, None, None).unwrap();
        let item = store.get(parse_id(&root.id).unwrap()).unwrap().unwrap();
        assert_eq!(item.author, store.default_author);
        assert!(matches!(
            item.author_kind,
            ActorKind::System | ActorKind::Human | ActorKind::Agent
        ));
    }
}
