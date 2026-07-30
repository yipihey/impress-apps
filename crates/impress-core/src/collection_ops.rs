//! The collection kernel (ADR-0022 D1/D2).
//!
//! One implementation of the collection verb set — `list_tree`,
//! `collections_containing`, `create`, `rename`, `reparent`, `reorder`,
//! `delete`, `add_members`, `remove_members`, `member_counts` — parameterized by a
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
//! | `create_in`      | [`CollectionRow`]         | `delete(row.id)`                                  |
//! | `create_in_with_payload` | [`CollectionRow`] | `delete(row.id)`                                  |
//! | `rename`         | [`CollectionMutation`]    | `rename(id, prior.name())`                        |
//! | `reorder`        | [`CollectionMutation`]    | `reorder(id, prior.sort_order())`                 |
//! | `reparent`       | [`CollectionMutation`]    | `reparent(id, prior.parent_id())` (`None` = root) |
//! | `reparent_in`    | [`CollectionMutation`]    | `reparent_in(id, prior.parent_id(), prior.container_id())` |
//! | `delete`         | [`DeletedCollection`]     | `restore(snapshot)`                               |
//! | `restore`        | [`CollectionRow`]         | `delete(row.id)`                                  |
//! | `add_members`    | changed ids               | `remove_members(collection, changed)`             |
//! | `remove_members` | changed ids               | `add_members(collection, changed)`                |
//!
//! The membership verbs return only the ids they actually changed — never the
//! ids the caller asked for — so the inverse cannot re-file an item that was
//! already a member (or unfile one that never was).
//!
//! # The optional axes (ADR-0022 C2)
//!
//! Three axes are `Option`al on [`CollectionSchemaBinding`] because exactly one
//! shipped binding needs each, and a binding that declines one behaves precisely
//! as it did before the axis existed:
//!
//! | axis | declared by | what it buys | `None` means |
//! |---|---|---|---|
//! | [`ContainerField`] (`container_field`) | `IMBIB_COLLECTION` | per-container creation ([`create_in`]), per-container listing ([`list_tree_in`]), atomic cross-container reparent ([`reparent_in`]), and a `container_id` on every row | collections are global; every container argument is ignored |
//! | `smart_field` | `IMBIB_COLLECTION`, `MANUSCRIPT_COLLECTION`, `GENERIC_COLLECTION` | [`CollectionRow::is_smart`], the per-row read-only predicate a sidebar gates Rename / New Subcollection on | rows report `is_smart: false` |
//! | `kind_scope_field` (pre-existing) | `GENERIC_COLLECTION` | per-row record-kind scope | the binding's scope is a constant it already knows |
//!
//! The container axis is the one axis the WP G7 flip provably cannot disturb:
//! the migration rewrites `schema_ref` and the payload and never touches the
//! envelope, so a container read or write is byte-identical on both sides.
//! That is what makes [`list_tree_in`] a drop-in for imbib-core's
//! `list_collections(library_id)`, which is blind after the flip.
//!
//! **Not an axis: "ensure container membership".** The wave-3 routing survey
//! listed `ImbibStore::add_to_collection` as also ensuring the publication is a
//! member of the collection's library, which would have made membership a
//! two-write verb for one binding. It does not — the export is thirty lines of
//! `AddReference(Contains)` and nothing else (`imbib-core/unified/store_api.rs`),
//! and the claim came from a Swift call-site COMMENT, not from the code. So
//! [`add_members`] is already faithful for publication collections and no hook
//! was added: a seam nothing needs is a seam that rots.
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

/// Where a binding records a collection's OWNING CONTAINER (ADR-0022 C2).
///
/// The container is what a collection belongs **to**; the tree parent
/// ([`ParentField`]) is what it nests **under**. imbib is the binding that
/// forced this to be declared: a publication collection carries
/// (collectionID, libraryID), drop acceptance requires the SAME library, a
/// cross-library reparent is TWO writes, and creation is per-library — none of
/// which the kernel could say before.
///
/// A binding with `None` has no container axis at all: manuscript folders and
/// figure folders are global, and every container-taking verb below degrades to
/// its historical, container-free behaviour for them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContainerField {
    /// The envelope `item.parent`. For imbib publication collections that field
    /// IS the owning library — which is precisely what `list_collections`
    /// filters on (`HasParent`) and what the c902a22f postmortem is about: the
    /// envelope is the CONTAINER, never the tree parent.
    ///
    /// Migration-invariant on purpose. WP G7 rewrites `schema_ref` and the
    /// payload and does not touch the envelope, so container reads and writes
    /// are byte-identical on both sides of the `collections.unified` flip.
    Envelope,
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
    /// Where this binding records the OWNING CONTAINER, or `None` for a binding
    /// whose collections are global (manuscript folders, figure folders).
    pub container_field: Option<ContainerField>,
    /// Payload bool field marking a row as a SMART (query-defined) collection,
    /// for schemas that have one. Read-only here: the kernel never writes it and
    /// has no predicate language (ADR-0022 risk register). It exists so the
    /// per-row read-only predicate a sidebar needs — imbib gates Rename and New
    /// Subcollection on it, leaving Delete — is sourced from the payload instead
    /// of from a second Swift read of a legacy row shape.
    pub smart_field: Option<&'static str>,
}

/// imbib publication collections (`imbib/collection`): payload `parent_id`
/// tree, `Contains` membership, envelope parent = owning library.
///
/// The one binding with all three optional axes populated: it is per-library
/// (`container_field`), it has smart rows (`smart_field`), and its tree parent
/// is a payload ref while its envelope is the library.
pub const IMBIB_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: "imbib/collection",
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: None,
    envelope_parent: EnvelopeParent::OwningLibrary,
    unified_kind_scope: Some("publication"),
    container_field: Some(ContainerField::Envelope),
    smart_field: Some("is_smart"),
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
    // No container axis: imprint's folders are global, not per-library. Every
    // container-taking verb therefore behaves exactly as it did before C2.
    container_field: None,
    // `manuscript-collection` declares `is_smart` (imbib-core `schemas.rs`), and
    // the sidebar already renders the badged glyph off it. Reporting it costs
    // nothing and no verb branches on it.
    smart_field: Some("is_smart"),
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
    // The envelope is already spoken for — it IS the tree parent — so a figure
    // folder could not carry a container even if implore wanted one.
    container_field: None,
    // `figure-collection` has no such field (`FigureCollectionPayload` is
    // name + sort_order), so rows report `is_smart: false`.
    smart_field: None,
};

/// The generic `collection@1.0.0` kernel schema (ADR-0022 D1).
pub const GENERIC_COLLECTION: CollectionSchemaBinding = CollectionSchemaBinding {
    schema_ref: COLLECTION_SCHEMA,
    parent_field: ParentField::Payload("parent_id"),
    membership: Membership::ContainsEdge,
    kind_scope_field: Some("kind_scope"),
    envelope_parent: EnvelopeParent::OwningLibrary,
    unified_kind_scope: None,
    // The generic binding is the DESTINATION and must see every collection row
    // whatever container it sits in, exactly as it is unscoped by `kind_scope`.
    // A container-scoped generic read is the caller's filter, not the binding's.
    container_field: None,
    // `collection@1.0.0` schema'd `is_smart` from the start (D1), inert.
    smart_field: Some("is_smart"),
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
    /// Unchanged by the flip, always: WP G7 rewrites the schema and the payload
    /// and leaves the envelope alone, so the container axis is the one axis that
    /// is provably identical on both sides.
    pub container_field: Option<ContainerField>,
    /// Unchanged by the flip: `collection@1.0.0` spells its smart flag
    /// `is_smart` too, which is the name every legacy binding that has one uses.
    pub smart_field: Option<&'static str>,
    /// The marker's state when this was resolved. Reported for diagnostics;
    /// no verb branches on it directly.
    pub unified: bool,
}

impl ResolvedBinding {
    /// Does `item` belong to this binding — right schema, and (once converged)
    /// right `kind_scope`?
    ///
    /// The public half of the kernel's internal membership test, for callers
    /// that own a schema GUARD rather than a query: imbib-core's
    /// `rename_collection` keeps writing through
    /// `SqliteItemStore::update_with_undo` — its operation-log rows are what
    /// the history panel reads, which the kernel's `CollectionMutation` is not
    /// — so it cannot delegate to [`rename`]. But its
    /// `item.schema == "imbib/collection"` guard is exactly what turns into an
    /// unconditional `NotFound` at the flip. Resolving the binding once and
    /// asking it this question is the whole fix, and it does not fork
    /// [`resolve`].
    pub fn matches(&self, item: &Item) -> bool {
        is_bound(self, item)
    }

    /// The predicates that narrow a query on [`Self::schema_ref`] to this
    /// binding's rows. Empty with the marker off — the query the store sees is
    /// then literally the pre-G7 query — and one `kind_scope` equality once
    /// converged.
    ///
    /// Exposed for the same reason as [`Self::matches`]: a caller outside this
    /// module that must build its own `ItemQuery` can be marker-correct with
    /// `b.schema_ref` plus this, instead of re-deriving the resolution table.
    pub fn scope_predicates(&self) -> Vec<Predicate> {
        scope_predicates(self)
    }
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
                container_field: self.container_field,
                smart_field: self.smart_field,
                unified: true,
            },
            _ => ResolvedBinding {
                schema_ref: self.schema_ref,
                parent_field: self.parent_field,
                membership: self.membership,
                kind_scope_field: self.kind_scope_field,
                kind_scope: None,
                envelope_parent: self.envelope_parent,
                container_field: self.container_field,
                smart_field: self.smart_field,
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
    /// Lowercase UUID string of the OWNING CONTAINER (imbib: the library), or
    /// `None` for a binding with no container axis. Never the tree parent —
    /// that is `parent_id`, and conflating the two is the c902a22f regression.
    pub container_id: Option<String>,
    /// Is this a smart (query-defined) collection? `false` for every binding
    /// whose schema has no such field. The kernel has no predicate language, so
    /// this is a REPORTED fact a caller may gate its own verbs on — which is
    /// what imbib's sidebar does (smart rows offer Delete only).
    pub is_smart: bool,
    /// How many members the collection holds — [`member_counts`]'s number,
    /// carried on the row so a tree read is a drop-in for imbib-core's
    /// `list_collections` (whose `publication_count` is exactly the outgoing
    /// `Contains`-edge count, unfiltered by member schema). For an
    /// envelope-membership binding this is the filed-children count instead.
    pub member_count: i64,
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
    /// Prior tree parent AND prior owning container, from [`reparent_in`] when
    /// the move crossed containers. A separate variant rather than a wider
    /// `Parent`, so every existing caller's `Parent` match keeps compiling and
    /// keeps meaning exactly what it meant: a same-container move.
    ParentInContainer {
        /// The tree parent before the move. `None` = it was a root.
        parent: Option<String>,
        /// The owning container before the move. `None` = it had none.
        container: Option<String>,
    },
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

    /// The prior tree parent, if this came from [`reparent`] or [`reparent_in`].
    /// The outer `Option` is "wrong variant", the inner one is "was a root".
    pub fn parent_id(&self) -> Option<Option<&str>> {
        match self {
            CollectionPrior::Parent(parent) => Some(parent.as_deref()),
            CollectionPrior::ParentInContainer { parent, .. } => Some(parent.as_deref()),
            _ => None,
        }
    }

    /// The prior owning container, if this came from a [`reparent_in`] that
    /// crossed containers. `None` for every other variant — including
    /// [`CollectionPrior::Parent`], whose whole point is that the container did
    /// not move and must not be rewritten by the inverse.
    pub fn container_id(&self) -> Option<Option<&str>> {
        match self {
            CollectionPrior::ParentInContainer { container, .. } => Some(container.as_deref()),
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
    list_tree_resolved(store, &b, None)
}

/// The collections of one OWNING CONTAINER, ordered by `sort_order`.
///
/// `container` is ignored by a binding with no container axis, which then
/// answers exactly as [`list_tree`] does — so a caller may pass the container it
/// has without asking whether the binding cares.
///
/// This is the migration-safe replacement for imbib-core's
/// `list_collections(library_id)`: that export hard-codes
/// `schema_ref = "imbib/collection"` and returns nothing once WP G7 has run,
/// while this resolves the binding against the `collections.unified` marker and
/// filters on the envelope, which the migration does not touch.
pub fn list_tree_in(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    container: Option<&str>,
) -> Result<Vec<CollectionRow>, StoreError> {
    let b = resolve(store, binding)?;
    let container = container.map(parse_id).transpose()?;
    list_tree_resolved(store, &b, container)
}

fn list_tree_resolved(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    container: Option<ItemId>,
) -> Result<Vec<CollectionRow>, StoreError> {
    let mut predicates = scope_predicates(b);
    if let (Some(ContainerField::Envelope), Some(container)) = (b.container_field, container) {
        predicates.push(Predicate::HasParent(container));
    }
    let q = ItemQuery {
        schema: Some(b.schema_ref.into()),
        predicates,
        sort: vec![SortDescriptor {
            field: "payload.sort_order".into(),
            ascending: true,
        }],
        include_tags: false,
        // References are the ContainsEdge member count (`row_of`); collection
        // trees are small, so loading them here is cheaper than a count query
        // per row and keeps the read one round trip.
        include_references: true,
        ..Default::default()
    };
    store
        .query(&q)?
        .iter()
        .map(|item| row_of(store, b, item))
        .collect()
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

/// The collections that CONTAIN `member` — the inverse of [`list_members`],
/// ordered by `sort_order` like every other tree read.
///
/// This is the migration-safe replacement for imbib-core's
/// `list_collections_for_publication`, which hard-codes
/// `schema_ref = "imbib/collection"` and returns nothing once WP G7 has run.
/// It is one verb rather than a per-kind query because the inverse-membership
/// question is not publication-specific: the binding is what makes "which
/// manuscript folders hold this manuscript" the same call with a different
/// argument, which is exactly how `get_manuscript_detail` was fixed — one line,
/// no second predicate.
///
/// Both membership mechanics are answered, so a caller need not know which one
/// its binding uses: a `Contains` binding runs the reverse-edge predicate, and
/// an envelope binding (figure folders) reports the member's own `item.parent`
/// when that parent is a collection of this binding — at most one row, which
/// is the truth for a filing-based membership.
///
/// A member id that does not exist yields an empty list rather than an error:
/// "no collections contain a thing that is not there" is the answer every
/// caller wants, and it matches [`member_counts`]'s tolerance of stale ids.
pub fn collections_containing(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    member_id: &str,
) -> Result<Vec<CollectionRow>, StoreError> {
    let b = resolve(store, binding)?;
    let member = parse_id(member_id)?;
    containing_items(store, &b, member, true)?
        .iter()
        .map(|item| row_of(store, &b, item))
        .collect()
}

/// [`collections_containing`], projected to ids.
///
/// The same query, without the per-row member count — which means without
/// loading every containing collection's `Contains` edges. imbib-core's
/// `get_publication_detail` wants exactly this (it reports collection IDS on a
/// detail pane that opens on every selection change), and paying for a
/// thousand-row reference load per open to throw the count away would be a new
/// cost the blind query never had.
pub fn collections_containing_ids(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    member_id: &str,
) -> Result<Vec<String>, StoreError> {
    let b = resolve(store, binding)?;
    let member = parse_id(member_id)?;
    Ok(containing_items(store, &b, member, false)?
        .iter()
        .map(|item| item.id.to_string())
        .collect())
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
        counts.push(match store.get(id)? {
            Some(item) if is_bound(&b, &item) => member_count_of(store, &b, &item)?,
            _ => 0,
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
    create_in(store, binding, name, parent, kind_scope, sort_order, None)
}

/// Create a collection in an explicit OWNING CONTAINER (ADR-0022 C2).
///
/// `container` is what makes per-library creation expressible: imbib's "New
/// Collection" on a library row creates a ROOT collection whose owning library
/// is that row, and there is no parent collection to inherit the library from.
/// The historical inherit-from-parent rule is what `None` still means, so
/// [`create`] is this function with `None` and every pre-C2 caller is unchanged.
///
/// A binding with no container axis ignores `container` outright rather than
/// writing an envelope parent its tree semantics would then misread.
///
/// **Undo:** `delete(row.id)`.
#[allow(clippy::too_many_arguments)]
pub fn create_in(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    name: &str,
    parent: Option<&str>,
    kind_scope: Option<&str>,
    sort_order: Option<i64>,
    container: Option<&str>,
) -> Result<CollectionRow, StoreError> {
    create_in_with_payload(
        store,
        binding,
        name,
        parent,
        kind_scope,
        sort_order,
        container,
        &[],
    )
}

/// [`create_in`] plus payload fields the kernel does not interpret.
///
/// The kernel owns the STRUCTURAL write shape — `schema_ref`, `name`,
/// `sort_order`, `kind_scope`, the tree parent, the envelope — because that
/// shape is what [`crate::collection_migration`] has to be able to produce and
/// consume. An app layered on top may still have payload of its own on the same
/// row: imbib's `create_collection` takes `is_smart` and `smart_query`, and
/// dropping them at the flip would silently demote every smart collection a
/// user creates.
///
/// `extra` is written FIRST, so a structural field can never be shadowed by it:
/// a caller cannot smuggle a `parent_id` past the binding's tree semantics.
/// One insert, so a create is still one operation in the store's op log — the
/// alternative (create, then patch) would put a second entry in the undo
/// history panel for what the user did once.
///
/// **Undo:** `delete(row.id)`.
#[allow(clippy::too_many_arguments)]
pub fn create_in_with_payload(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    name: &str,
    parent: Option<&str>,
    kind_scope: Option<&str>,
    sort_order: Option<i64>,
    container: Option<&str>,
    extra: &[(&str, Value)],
) -> Result<CollectionRow, StoreError> {
    let b = resolve(store, binding)?;
    let parent_id = parent.map(parse_id).transpose()?;
    let container_id = match b.container_field {
        Some(ContainerField::Envelope) => container.map(parse_id).transpose()?,
        None => None,
    };
    let parent_item = match parent_id {
        Some(pid) => Some(load_collection(store, &b, pid)?),
        None => None,
    };

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    for (key, value) in extra {
        payload.insert((*key).to_string(), value.clone());
    }
    payload.insert("name".into(), Value::String(name.to_string()));
    payload.insert("sort_order".into(), Value::Int(sort_order.unwrap_or(0)));
    write_kind_scope(&b, &mut payload, kind_scope);
    if let (ParentField::Payload(field), Some(pid)) = (b.parent_field, parent_id) {
        payload.insert(field.into(), Value::String(pid.to_string()));
    }

    let mut item = new_item(store, b.schema_ref, payload);
    item.parent = match b.envelope_parent {
        // An EXPLICIT container wins over the inherit: a root collection has no
        // parent to inherit from, and a sub-collection created with a stated
        // library must land in that library rather than in its parent's.
        EnvelopeParent::OwningLibrary => {
            container_id.or_else(|| parent_item.as_ref().and_then(|p| p.parent))
        }
        // Figure folders keep nesting through the envelope even once their
        // tree parent also lives in the payload, so envelope-filed membership
        // (`item.parent` of a figure → this folder) keeps working unchanged.
        EnvelopeParent::TreeParent => parent_id,
    };

    store.insert(item.clone())?;
    row_of(store, &b, &item)
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
    reparent_in(store, binding, id, new_parent, None)
}

/// Move a collection under `new_parent` AND into `new_container` (ADR-0022 C2).
///
/// `new_container: None` means "leave the owning container alone", which is what
/// [`reparent`] passes and what a same-library move wants: the legacy Swift path
/// skipped its `reparentItem` write entirely when the library did not change, and
/// so does this — one write, not two.
///
/// `new_container: Some(c)` is the CROSS-container move imbib performs as two
/// writes today (payload `parent_id` plus `reparentItem`). Both land in one
/// `store.update`, which is also what makes the pair atomic and the inverse
/// exact.
///
/// A binding with no container axis ignores `new_container`.
///
/// **Undo:** `reparent_in(id, prior.parent_id(), prior.container_id())`. When
/// the container did not move the prior is a plain
/// [`CollectionPrior::Parent`] and `container_id()` is `None`, so the inverse
/// leaves the container alone — undoing a same-library move must not start
/// writing an envelope the forward move never touched.
pub fn reparent_in(
    store: &SqliteItemStore,
    binding: &CollectionSchemaBinding,
    id: &str,
    new_parent: Option<&str>,
    new_container: Option<&str>,
) -> Result<CollectionMutation, StoreError> {
    let b = resolve(store, binding)?;
    let id = parse_id(id)?;
    let before = load_collection(store, &b, id)?;
    let new_container_id = match b.container_field {
        Some(ContainerField::Envelope) => new_container.map(parse_id).transpose()?,
        None => None,
    };
    let prior_parent = tree_parent(&b, &before).map(|p| p.to_string());
    let prior = match new_container_id {
        Some(_) => CollectionPrior::ParentInContainer {
            parent: prior_parent,
            container: container_of(&b, &before).map(|c| c.to_string()),
        },
        None => CollectionPrior::Parent(prior_parent),
    };
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
    // The second half of a cross-container move. Mutually exclusive with the
    // mirror above by construction: a binding whose envelope IS the tree parent
    // has no container axis, so `new_container_id` is always `None` there.
    if let Some(container) = new_container_id {
        mutations.push(FieldMutation::SetParent(Some(container)));
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
    let row = row_of(store, &b, &item)?;

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
    let child_collection_ids: Vec<String> = list_tree_resolved(store, &b, None)?
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
    // A restored SMART collection must come back smart. The flag was invisible
    // to this function before C2 gave `CollectionRow` an `is_smart`, so undoing
    // the delete of a smart publication collection silently demoted it to a
    // manual one — the row reappeared with the wrong glyph and the full menu.
    // Written only when the binding HAS the field, so a figure folder's payload
    // is byte-identical to what it was.
    if let Some(field) = b.smart_field {
        if snapshot.row.is_smart {
            payload.insert(field.into(), Value::Bool(true));
        }
    }
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
    row_of(store, b, &item)
}

fn row_of(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    item: &Item,
) -> Result<CollectionRow, StoreError> {
    Ok(CollectionRow {
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
        container_id: container_of(b, item).map(|c| c.to_string()),
        is_smart: b
            .smart_field
            .and_then(|field| bool_field(item, field))
            .unwrap_or(false),
        member_count: i64::from(member_count_of(store, b, item)?),
    })
}

/// One collection's member count, from an item already in hand. The
/// `ContainsEdge` arm needs the item loaded WITH references (`store.get` does;
/// a query must say `include_references: true`) and costs no store round trip;
/// the envelope arm is a count query, which is what [`member_counts`] has
/// always done for it.
fn member_count_of(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    item: &Item,
) -> Result<u32, StoreError> {
    Ok(match b.membership {
        // Sub-collections nest through the parent field, never through a
        // Contains edge, so every outgoing Contains edge is a member.
        Membership::ContainsEdge => item
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::Contains)
            .count() as u32,
        Membership::EnvelopeParent => store.count(&member_query(b, item.id))? as u32,
    })
}

/// The collection's owning container, or `None` for a binding with no container
/// axis. Deliberately a separate reader from [`tree_parent`] even though both
/// can name the envelope: they answer different questions, and the one time they
/// were conflated (c902a22f) every collection's parent became its library and
/// the sidebar tree flattened.
fn container_of(b: &ResolvedBinding, item: &Item) -> Option<ItemId> {
    match b.container_field {
        Some(ContainerField::Envelope) => item.parent,
        None => None,
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

/// The bound collections that contain `member`. The single implementation
/// behind [`collections_containing`] and [`collections_containing_ids`], so the
/// inverse-membership predicate is written once.
///
/// `with_references` decides whether the rows come back carrying their
/// `Contains` edges: [`row_of`] needs them for `member_count`, the id
/// projection does not, and for a collection holding thousands of papers that
/// is the difference between one cheap query and a bulk reference load.
fn containing_items(
    store: &SqliteItemStore,
    b: &ResolvedBinding,
    member: ItemId,
    with_references: bool,
) -> Result<Vec<Item>, StoreError> {
    match b.membership {
        Membership::ContainsEdge => {
            let mut predicates = scope_predicates(b);
            predicates.push(Predicate::HasReference(EdgeType::Contains, member));
            store.query(&ItemQuery {
                schema: Some(b.schema_ref.into()),
                predicates,
                sort: vec![SortDescriptor {
                    field: "payload.sort_order".into(),
                    ascending: true,
                }],
                include_tags: false,
                include_references: with_references,
                ..Default::default()
            })
        }
        // Filing-based membership: the member names its own collection, so the
        // answer is its envelope parent — if that parent is a collection of
        // this binding at all, which is what excludes a figure filed directly
        // under a library.
        Membership::EnvelopeParent => {
            let parent = match store.get(member)? {
                Some(item) => item.parent,
                None => return Ok(vec![]),
            };
            Ok(match parent {
                Some(pid) => store
                    .get(pid)?
                    .filter(|item| is_bound(b, item))
                    .map(|item| vec![item])
                    .unwrap_or_default(),
                None => vec![],
            })
        }
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

fn bool_field(item: &Item, field: &str) -> Option<bool> {
    match item.payload.get(field) {
        Some(Value::Bool(b)) => Some(*b),
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
        // Structurally the create-time row; `member_count` truthfully reports
        // the two members added since (it is a live read, not part of the
        // structural identity the round trip must preserve).
        assert_eq!(
            snapshot.row,
            CollectionRow {
                member_count: 2,
                ..folder.clone()
            }
        );
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
        assert_eq!(
            restored,
            CollectionRow {
                member_count: 2,
                ..folder.clone()
            },
            "restored under its ORIGINAL id, with its two members re-filed"
        );
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
        // Restore re-files both figures, so the truthful count is 2; every
        // structural field must match the create-time row exactly.
        assert_eq!(
            restored,
            CollectionRow {
                member_count: 2,
                ..folder.clone()
            }
        );
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
            undone.row,
            CollectionRow {
                member_count: 3,
                ..shelf.clone()
            },
            "an undone rename restores the row exactly (count reflects the \
             three members added after creation — a live read, not identity)"
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
        assert_eq!(
            back.row,
            CollectionRow {
                member_count: 3,
                ..shelf.clone()
            },
            "the tree is exactly where it started (count is a live read)"
        );

        // ─ delete → restore brings the MIXED membership back intact ─
        let before_members = member_ids(&store, &GENERIC_COLLECTION, &shelf.id);
        let before_tree = tree_by_id(&store, &GENERIC_COLLECTION);

        let snapshot = delete(&store, &GENERIC_COLLECTION, &shelf.id).unwrap();
        assert_eq!(
            snapshot.row,
            CollectionRow {
                member_count: 3,
                ..shelf.clone()
            }
        );
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
            restored,
            CollectionRow {
                member_count: 3,
                ..shelf.clone()
            },
            "restored under its ORIGINAL id, scope included, members re-filed"
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

    // ─── The optional axes (ADR-0022 C2) ─────────────────────────────────
    //
    // Every test below pairs the binding that DECLARES the axis with one that
    // declines it, because the contract is not just "the axis works" — it is
    // "the axis is invisible to a binding that has none". The manuscript and
    // figure bindings are the oracle for that half (wave-3's imprint parity
    // tests run through these same seams).

    /// A stand-in owning container: any item will do, the kernel only ever
    /// writes its id to the envelope.
    fn make_container(store: &SqliteItemStore, name: &str) -> String {
        make_item(store, "imbib/library", name)
    }

    #[test]
    fn only_the_imbib_binding_declares_a_container_axis() {
        assert_eq!(
            IMBIB_COLLECTION.container_field,
            Some(ContainerField::Envelope)
        );
        for binding in [MANUSCRIPT_COLLECTION, FIGURE_COLLECTION, GENERIC_COLLECTION] {
            assert_eq!(
                binding.container_field, None,
                "{}: folders are global; a container argument must be ignored",
                binding.schema_ref
            );
        }
    }

    #[test]
    fn create_in_files_a_root_collection_under_its_container() {
        let store = open();
        let library = make_container(&store, "Main");
        let row = create_in(
            &store,
            &IMBIB_COLLECTION,
            "Reading",
            None,
            None,
            None,
            Some(&library),
        )
        .unwrap();

        assert_eq!(row.container_id.as_deref(), Some(library.as_str()));
        assert_eq!(
            row.parent_id, None,
            "the container is NOT the tree parent — that conflation is c902a22f"
        );
        let item = store.get(parse_id(&row.id).unwrap()).unwrap().unwrap();
        assert_eq!(item.parent.map(|p| p.to_string()), Some(library));
    }

    #[test]
    fn create_in_inherits_the_container_when_none_is_named() {
        let store = open();
        let library = make_container(&store, "Main");
        let parent = create_in(
            &store,
            &IMBIB_COLLECTION,
            "Parent",
            None,
            None,
            None,
            Some(&library),
        )
        .unwrap();
        // `create` is `create_in(.., None)`: the historical inherit-from-parent
        // rule, unchanged.
        let child = create(
            &store,
            &IMBIB_COLLECTION,
            "Child",
            Some(&parent.id),
            None,
            None,
        )
        .unwrap();
        assert_eq!(child.container_id.as_deref(), Some(library.as_str()));
        assert_eq!(child.parent_id.as_deref(), Some(parent.id.as_str()));
    }

    #[test]
    fn create_in_is_ignored_by_a_binding_with_no_container_axis() {
        let store = open();
        let library = make_container(&store, "Main");
        for binding in [MANUSCRIPT_COLLECTION, GENERIC_COLLECTION] {
            let row =
                create_in(&store, &binding, "Folder", None, None, None, Some(&library)).unwrap();
            assert_eq!(
                row.container_id, None,
                "{}: reports no container",
                binding.schema_ref
            );
            let item = store.get(parse_id(&row.id).unwrap()).unwrap().unwrap();
            assert_eq!(
                item.parent, None,
                "{}: and writes no envelope parent — behaviour is pre-C2 verbatim",
                binding.schema_ref
            );
        }
    }

    #[test]
    fn list_tree_in_scopes_to_one_container_and_list_tree_still_sees_all() {
        let store = open();
        let main = make_container(&store, "Main");
        let other = make_container(&store, "Other");
        create_in(
            &store,
            &IMBIB_COLLECTION,
            "A",
            None,
            None,
            Some(0),
            Some(&main),
        )
        .unwrap();
        create_in(
            &store,
            &IMBIB_COLLECTION,
            "B",
            None,
            None,
            Some(1),
            Some(&main),
        )
        .unwrap();
        create_in(
            &store,
            &IMBIB_COLLECTION,
            "Z",
            None,
            None,
            Some(0),
            Some(&other),
        )
        .unwrap();

        assert_eq!(
            names(&list_tree_in(&store, &IMBIB_COLLECTION, Some(&main)).unwrap()),
            vec!["A", "B"]
        );
        assert_eq!(
            names(&list_tree_in(&store, &IMBIB_COLLECTION, Some(&other)).unwrap()),
            vec!["Z"]
        );
        // Unscoped reads are untouched, and `list_tree` IS the unscoped read.
        assert_eq!(
            list_tree(&store, &IMBIB_COLLECTION).unwrap().len(),
            3,
            "list_tree is container-blind, as it always was"
        );
        assert_eq!(
            list_tree_in(&store, &IMBIB_COLLECTION, None).unwrap().len(),
            3
        );
    }

    #[test]
    fn list_tree_in_ignores_the_container_for_a_binding_without_one() {
        let store = open();
        let library = make_container(&store, "Main");
        create(&store, &MANUSCRIPT_COLLECTION, "Drafts", None, None, None).unwrap();
        assert_eq!(
            names(&list_tree_in(&store, &MANUSCRIPT_COLLECTION, Some(&library)).unwrap()),
            vec!["Drafts"],
            "a manuscript folder is not hidden by a container it never had"
        );
    }

    #[test]
    fn reparent_in_moves_tree_and_container_together_and_inverts_exactly() {
        let store = open();
        let main = make_container(&store, "Main");
        let other = make_container(&store, "Other");
        let source = create_in(
            &store,
            &IMBIB_COLLECTION,
            "Src",
            None,
            None,
            None,
            Some(&main),
        )
        .unwrap();
        let target = create_in(
            &store,
            &IMBIB_COLLECTION,
            "Dst",
            None,
            None,
            None,
            Some(&other),
        )
        .unwrap();

        let moved = reparent_in(
            &store,
            &IMBIB_COLLECTION,
            &source.id,
            Some(&target.id),
            Some(&other),
        )
        .unwrap();
        assert_eq!(moved.row.parent_id.as_deref(), Some(target.id.as_str()));
        assert_eq!(moved.row.container_id.as_deref(), Some(other.as_str()));
        assert_eq!(
            moved.prior,
            CollectionPrior::ParentInContainer {
                parent: None,
                container: Some(main.clone()),
            }
        );

        // The documented inverse, verbatim.
        let back = reparent_in(
            &store,
            &IMBIB_COLLECTION,
            &source.id,
            moved.prior.parent_id().unwrap(),
            moved.prior.container_id().unwrap(),
        )
        .unwrap();
        assert_eq!(back.row.parent_id, None);
        assert_eq!(back.row.container_id.as_deref(), Some(main.as_str()));
    }

    #[test]
    fn a_same_container_reparent_leaves_the_container_alone() {
        let store = open();
        let main = make_container(&store, "Main");
        let a = create_in(
            &store,
            &IMBIB_COLLECTION,
            "A",
            None,
            None,
            None,
            Some(&main),
        )
        .unwrap();
        let b = create_in(
            &store,
            &IMBIB_COLLECTION,
            "B",
            None,
            None,
            None,
            Some(&main),
        )
        .unwrap();

        // `reparent` is `reparent_in(.., None)`: one write, and a prior that
        // says "container untouched" so the inverse cannot start writing one.
        let moved = reparent(&store, &IMBIB_COLLECTION, &b.id, Some(&a.id)).unwrap();
        assert_eq!(moved.prior, CollectionPrior::Parent(None));
        assert_eq!(moved.prior.container_id(), None);
        assert_eq!(moved.row.container_id.as_deref(), Some(main.as_str()));
    }

    #[test]
    fn reparent_in_is_ignored_by_a_binding_with_no_container_axis() {
        let store = open();
        let library = make_container(&store, "Main");
        let parent = create(&store, &MANUSCRIPT_COLLECTION, "P", None, None, None).unwrap();
        let child = create(&store, &MANUSCRIPT_COLLECTION, "C", None, None, None).unwrap();
        let moved = reparent_in(
            &store,
            &MANUSCRIPT_COLLECTION,
            &child.id,
            Some(&parent.id),
            Some(&library),
        )
        .unwrap();
        assert_eq!(
            moved.prior,
            CollectionPrior::Parent(None),
            "no container axis ⇒ the plain prior, so imprint's undo is unchanged"
        );
        let item = store.get(parse_id(&child.id).unwrap()).unwrap().unwrap();
        assert_eq!(item.parent, None, "and no envelope write happened at all");
    }

    #[test]
    fn is_smart_is_reported_per_row_and_only_where_the_schema_has_the_field() {
        let store = open();
        let library = make_container(&store, "Main");
        let manual = create_in(
            &store,
            &IMBIB_COLLECTION,
            "Manual",
            None,
            None,
            None,
            Some(&library),
        )
        .unwrap();
        assert!(!manual.is_smart, "the kernel never writes the flag");

        // Written the way imbib-core's `create_collection(is_smart: true)` does.
        store
            .update(
                parse_id(&manual.id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "is_smart".into(),
                    Value::Bool(true),
                )],
            )
            .unwrap();
        let listed = row(&list_tree(&store, &IMBIB_COLLECTION).unwrap(), &manual.id);
        assert!(listed.is_smart);

        // A binding whose schema has no such field reports false even if a
        // stray payload key exists — the axis is the BINDING's declaration.
        let folder = create(&store, &FIGURE_COLLECTION, "Figures", None, None, None).unwrap();
        store
            .update(
                parse_id(&folder.id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "is_smart".into(),
                    Value::Bool(true),
                )],
            )
            .unwrap();
        assert!(
            !row(&list_tree(&store, &FIGURE_COLLECTION).unwrap(), &folder.id).is_smart,
            "figure-collection declares no smart_field"
        );
    }

    #[test]
    fn restore_puts_a_smart_collection_back_smart() {
        let store = open();
        let library = make_container(&store, "Main");
        let smart = create_in(
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
                parse_id(&smart.id).unwrap(),
                vec![FieldMutation::SetPayload(
                    "is_smart".into(),
                    Value::Bool(true),
                )],
            )
            .unwrap();

        let snapshot = delete(&store, &IMBIB_COLLECTION, &smart.id).unwrap();
        assert!(snapshot.row.is_smart, "the snapshot carries the flag");
        let restored = restore(&store, &IMBIB_COLLECTION, &snapshot).unwrap();
        assert!(
            restored.is_smart,
            "undoing the delete of a smart collection must not demote it"
        );
        assert_eq!(restored.container_id.as_deref(), Some(library.as_str()));
    }

    #[test]
    fn the_container_axis_survives_the_unified_flip_untouched() {
        let store = open();
        let library = make_container(&store, "Main");
        let root = create_in(
            &store,
            &IMBIB_COLLECTION,
            "A",
            None,
            None,
            None,
            Some(&library),
        )
        .unwrap();
        let child = create(&store, &IMBIB_COLLECTION, "B", Some(&root.id), None, None).unwrap();

        crate::collection_migration::migrate_collections(&store, false).unwrap();
        assert!(crate::collection_migration::is_migrated(&store).unwrap());

        // The migration rewrites schema_ref and payload and never touches the
        // envelope, so the container filter answers identically after the flip.
        // This is the property that makes `list_tree_in` a safe replacement for
        // imbib-core's `list_collections(library_id)`.
        let rows = list_tree_in(&store, &IMBIB_COLLECTION, Some(&library)).unwrap();
        assert_eq!(names(&rows), vec!["A", "B"]);
        assert_eq!(
            row(&rows, &root.id).container_id.as_deref(),
            Some(library.as_str())
        );
        assert_eq!(
            row(&rows, &child.id).parent_id.as_deref(),
            Some(root.id.as_str())
        );
        assert!(
            list_tree_in(&store, &IMBIB_COLLECTION, Some(&child.id))
                .unwrap()
                .is_empty(),
            "and a wrong container still selects nothing"
        );
    }
}
