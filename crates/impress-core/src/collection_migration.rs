//! Collection schema convergence (ADR-0022 D1/D2, WP G7).
//!
//! The flagged, reversible data migration that rewrites the three legacy
//! collection schemas onto `collection@1.0.0`. D2 unified the *API* first
//! ([`crate::collection_ops`]); this is the second half — the *data* — and it
//! rewrites trees users live in, so every property below is a contract, not an
//! aspiration.
//!
//! # The contract
//!
//! 1. **Default OFF.** Nothing here runs on open. The marker
//!    ([`MARKER_KEY`] in `store_metadata`) is absent until a human invokes
//!    [`migrate_collections`] through the deliberate entry points
//!    (`CollectionService::migrate`, its MCP tool, its CLI subcommand).
//! 2. **Dry-run is first-class.** `migrate_collections(store, true)` performs
//!    ZERO writes and reports exactly the counts the real run will report. It
//!    is the same code path — the plan is computed once and only *applied*
//!    when `dry_run` is false — so a green dry-run is evidence about the real
//!    run, not about a parallel implementation of it.
//! 3. **Ids never change.** A migrated collection keeps its `ItemId`. Every
//!    reference into it — `Contains` edges, envelope-filed children, Swift
//!    selection state, undo snapshots — keeps working because there is nothing
//!    to re-point.
//! 4. **Byte-faithful rollback.** Before rewriting, each row's ORIGINAL
//!    payload JSON is stored verbatim (the exact `payload` column text) under
//!    [`LEGACY_PAYLOAD_KEY`], and its original `schema_ref` under
//!    [`LEGACY_SCHEMA_REF_KEY`]. [`rollback_collections`] writes those two
//!    values straight back, so the round trip is byte-equal at the column
//!    level, not merely semantically equivalent.
//!    **Rollback is a rewind, not a merge.** The verbatim payload is frozen at
//!    migration time, so a rename/reorder/reparent performed WHILE migrated is
//!    discarded by the rollback along with the migration itself — the row comes
//!    back exactly as the migration found it. That is the price of byte
//!    fidelity, and it is the right price for a rollback drill (you want the
//!    old state, not a three-way merge nobody can audit). It does mean
//!    `rollback` is a same-session escape hatch, not an "undo six months
//!    later" button; [`migration_status`] is how you check which you are in.
//!    Rows CREATED after the migration carry no provenance and are untouched,
//!    so nothing is ever lost — only post-migration edits to pre-migration
//!    rows are rewound.
//! 5. **Membership is NOT rewritten.** `Contains` edges stay `Contains` edges
//!    (imbib, imprint); figure membership stays the envelope parent
//!    (`item.parent` of the figure → the folder's id, which did not change).
//!    The migration touches `items.schema_ref` and `items.payload` and nothing
//!    else: not `item_references`, not `items.parent_id`, not `created` /
//!    `modified` / `logical_clock`. `membership_edges_untouched` on the report
//!    is a constant `true` that documents this and that the tests assert
//!    against real edge counts.
//! 6. **Idempotent.** A second [`migrate_collections`] rewrites zero rows
//!    (there are no legacy rows left to find). migrate → rollback → migrate
//!    round-trips to a byte-identical payload for every row.
//! 7. **Atomic.** All rewrites plus the marker write commit in ONE
//!    transaction. A store is never half-converged.
//!
//! # The payload rewrite
//!
//! | legacy schema | tree parent read from | becomes `kind_scope` |
//! |---|---|---|
//! | `imbib/collection` | payload `parent_id` | `publication` |
//! | `manuscript-collection` | payload `parent_collection_ref` | `manuscript` |
//! | `figure-collection` | envelope `item.parent` | `figure` |
//!
//! The new payload is
//! `{name, kind_scope, parent_id?, sort_order, is_smart, legacy?,
//!   legacy_schema_ref, legacy_payload}`:
//!
//! - `parent_id` is omitted entirely for a root, exactly as
//!   [`crate::collection_ops::create`] writes it, so a migrated root and a
//!   natively-created root are indistinguishable.
//! - `legacy` collects every payload key the canonical fields did not consume
//!   (`smart_query`, `is_collapsed`, anything an app wrote and nobody
//!   registered), so nothing is invisible after the flip.
//! - `legacy_payload` / `legacy_schema_ref` are the rollback source of truth.
//!   Rows created NATIVELY as `collection@1.0.0` carry neither and are left
//!   strictly alone by both directions.
//!
//! The envelope is deliberately untouched: `item.parent` stays the owning
//! library for imbib/imprint collections and stays the tree parent for figure
//! folders (which is also why figure membership keeps working — the children
//! still point at an id that still exists).
//!
//! `modified` is NOT bumped. A schema convergence is not a user edit; bumping
//! it would make rollback non-byte-faithful, flood the sync outbox, and
//! reorder every "recently modified" surface in the suite for no reason.
//!
//! # What the flag turns on
//!
//! [`crate::collection_ops`] reads the marker and resolves each legacy binding
//! to `(schema_ref = "collection", payload kind_scope = its kind)` while
//! keeping its membership axis unchanged. The kernel therefore reads correctly
//! on BOTH sides of the flip through the same binding constants. See
//! `CollectionSchemaBinding::resolved`.
//!
//! # What the flag does NOT turn on
//!
//! imbib-core's legacy readers (`ImbibStore::list_collections`,
//! `list_manuscript_collections`, `list_collections_for_publication`, …) query
//! the legacy `schema_ref` literals directly and will return EMPTY after
//! migration. That is expected and is the reason the flag stays off until the
//! remaining Swift callers of those exports are audited and moved onto the
//! `collection_*` kernel FFI. `crates/imbib-core/tests/collection_migration_legacy_readers.rs`
//! asserts this effect on purpose so it can never be discovered in production.

use std::collections::BTreeMap;

use rusqlite::{params, Connection, OptionalExtension};
use uuid::Uuid;

use crate::collection_ops::{
    CollectionSchemaBinding, ParentField, FIGURE_COLLECTION, IMBIB_COLLECTION,
    MANUSCRIPT_COLLECTION,
};
use crate::item::Value;
use crate::schemas::collection::{COLLECTION_SCHEMA, KIND_SCOPE_ANY};
use crate::sqlite_store::SqliteItemStore;
use crate::store::StoreError;

/// `store_metadata` key holding the convergence flag. Present with
/// [`MARKER_VALUE`] means the store's collections are `collection@1.0.0`.
pub const MARKER_KEY: &str = "collections.unified";

/// The only value [`MARKER_KEY`] is ever written with.
pub const MARKER_VALUE: &str = "1";

/// Payload key carrying a migrated row's ORIGINAL `schema_ref`.
pub const LEGACY_SCHEMA_REF_KEY: &str = "legacy_schema_ref";

/// Payload key carrying a migrated row's ORIGINAL payload JSON, verbatim.
pub const LEGACY_PAYLOAD_KEY: &str = "legacy_payload";

/// Payload key collecting legacy payload keys the canonical fields did not
/// consume.
pub const LEGACY_EXTRAS_KEY: &str = "legacy";

/// The three legacy bindings this migration converges, in stable order. The
/// generic binding is deliberately absent: it is the destination.
pub const MIGRATED_BINDINGS: [CollectionSchemaBinding; 3] =
    [IMBIB_COLLECTION, MANUSCRIPT_COLLECTION, FIGURE_COLLECTION];

// ─── Report types ────────────────────────────────────────────────────────────

/// Rows still stored under one legacy `schema_ref`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyRowCount {
    /// The legacy `schema_ref` (`imbib/collection`, …).
    pub schema_ref: &'static str,
    /// The `kind_scope` these rows take on once migrated.
    pub kind_scope: &'static str,
    /// How many rows still carry the legacy `schema_ref`.
    pub rows: u64,
}

/// Generic `collection@1.0.0` rows sharing a `kind_scope`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KindScopeCount {
    /// Payload `kind_scope`, or `"any"` when the payload has none.
    pub kind_scope: String,
    /// Rows with this scope.
    pub rows: u64,
    /// How many of them carry migration provenance ([`LEGACY_SCHEMA_REF_KEY`]).
    /// `rows - migrated` were created natively as `collection@1.0.0`.
    pub migrated: u64,
}

/// What [`migration_status`] answers: is this store converged, and what is
/// actually in it?
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationStatus {
    /// The [`MARKER_KEY`] flag.
    pub migrated: bool,
    /// Per legacy binding, in [`MIGRATED_BINDINGS`] order.
    pub legacy: Vec<LegacyRowCount>,
    /// Generic rows grouped by `kind_scope`, ascending.
    pub generic: Vec<KindScopeCount>,
}

impl MigrationStatus {
    /// Total rows still stored under a legacy `schema_ref`.
    pub fn legacy_total(&self) -> u64 {
        self.legacy.iter().map(|c| c.rows).sum()
    }

    /// Total `collection@1.0.0` rows.
    pub fn generic_total(&self) -> u64 {
        self.generic.iter().map(|c| c.rows).sum()
    }
}

/// One legacy binding's share of a migration run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BindingMigration {
    /// The legacy `schema_ref` this line is about.
    pub schema_ref: &'static str,
    /// The `kind_scope` its rows carry after the rewrite.
    pub kind_scope: &'static str,
    /// Legacy rows found.
    pub found: u64,
    /// Rows rewritten. Equals `found` — a run that cannot rewrite a row it
    /// found fails the whole transaction instead of reporting a shortfall.
    /// Identical for a dry run, which computes the same plan and applies none
    /// of it.
    pub rewritten: u64,
    /// Rows already carrying this binding's provenance as `collection@1.0.0`
    /// — migrated by an earlier run. This is what makes a second run's zero
    /// legible rather than alarming.
    pub skipped_already_generic: u64,
}

/// What [`migrate_collections`] did (or, for a dry run, would do).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationReport {
    /// True when nothing was written.
    pub dry_run: bool,
    /// The marker's state BEFORE this run.
    pub was_migrated: bool,
    /// Per legacy binding, in [`MIGRATED_BINDINGS`] order.
    pub bindings: Vec<BindingMigration>,
    /// Always `true`: the migration writes `schema_ref` and `payload` only.
    /// `Contains` edges and envelope parents are not part of the rewrite.
    pub membership_edges_untouched: bool,
}

impl MigrationReport {
    /// Total rows rewritten across all bindings.
    pub fn rewritten(&self) -> u64 {
        self.bindings.iter().map(|b| b.rewritten).sum()
    }

    /// Total legacy rows found across all bindings.
    pub fn found(&self) -> u64 {
        self.bindings.iter().map(|b| b.found).sum()
    }
}

/// One legacy binding's share of a rollback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BindingRollback {
    /// The legacy `schema_ref` restored.
    pub schema_ref: String,
    /// Rows restored to it.
    pub restored: u64,
}

/// What [`rollback_collections`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RollbackReport {
    /// Per originating `schema_ref`, ascending.
    pub bindings: Vec<BindingRollback>,
    /// Generic rows with NO migration provenance — created natively as
    /// `collection@1.0.0`. Counted, never touched.
    pub native_generic_untouched: u64,
    /// Always `true`, for the same reason as on [`MigrationReport`].
    pub membership_edges_untouched: bool,
}

impl RollbackReport {
    /// Total rows restored to a legacy schema.
    pub fn restored(&self) -> u64 {
        self.bindings.iter().map(|b| b.restored).sum()
    }
}

// ─── Marker ──────────────────────────────────────────────────────────────────

/// Is this store's collection data converged on `collection@1.0.0`?
///
/// One indexed `store_metadata` lookup on a pooled reader — cheap enough that
/// [`crate::collection_ops`] reads it once per operation rather than caching
/// it, which is what keeps migrate/rollback visible immediately to every live
/// store handle instead of requiring cache invalidation nobody would remember.
pub fn is_migrated(store: &SqliteItemStore) -> Result<bool, StoreError> {
    let values = store.query_raw(
        "SELECT value FROM store_metadata WHERE key = ?1",
        params![MARKER_KEY],
        |row| row.get::<_, String>(0),
    )?;
    Ok(values.first().map(|v| v == MARKER_VALUE).unwrap_or(false))
}

// ─── Status ──────────────────────────────────────────────────────────────────

/// Count what is in the store, on both sides of the convergence.
///
/// Safe to call at any time: it writes nothing and holds no transaction.
pub fn migration_status(store: &SqliteItemStore) -> Result<MigrationStatus, StoreError> {
    let migrated = is_migrated(store)?;

    let mut legacy = Vec::with_capacity(MIGRATED_BINDINGS.len());
    for binding in MIGRATED_BINDINGS {
        let rows = store.query_raw(
            "SELECT COUNT(*) FROM items WHERE schema_ref = ?1",
            params![binding.schema_ref],
            |row| row.get::<_, i64>(0),
        )?;
        legacy.push(LegacyRowCount {
            schema_ref: binding.schema_ref,
            kind_scope: unified_scope(&binding),
            rows: rows.first().copied().unwrap_or(0).max(0) as u64,
        });
    }

    let generic = store.query_raw(
        "SELECT COALESCE(json_extract(payload, '$.kind_scope'), ?2) AS ks,
                COUNT(*),
                SUM(CASE WHEN json_extract(payload, '$.legacy_schema_ref') IS NOT NULL
                         THEN 1 ELSE 0 END)
         FROM items WHERE schema_ref = ?1
         GROUP BY ks ORDER BY ks",
        params![COLLECTION_SCHEMA, KIND_SCOPE_ANY],
        |row| {
            Ok(KindScopeCount {
                kind_scope: row.get::<_, String>(0)?,
                rows: row.get::<_, i64>(1)?.max(0) as u64,
                migrated: row.get::<_, i64>(2)?.max(0) as u64,
            })
        },
    )?;

    Ok(MigrationStatus {
        migrated,
        legacy,
        generic,
    })
}

// ─── Migrate ─────────────────────────────────────────────────────────────────

/// Converge the three legacy collection schemas onto `collection@1.0.0`.
///
/// `dry_run: true` computes the identical plan, reports the identical counts
/// and writes NOTHING — not the rows, not the marker. Run it first; the
/// numbers it prints are the numbers the real run will print.
///
/// The real run applies every rewrite and sets [`MARKER_KEY`] in one
/// transaction, so the flag and the data can never disagree.
///
/// Idempotent: a second run finds no legacy rows and rewrites nothing, and
/// reports the already-converged rows under `skipped_already_generic`.
pub fn migrate_collections(
    store: &SqliteItemStore,
    dry_run: bool,
) -> Result<MigrationReport, StoreError> {
    // Read the marker BEFORE taking the writer lock: `is_migrated` goes
    // through the reader pool, which for an in-memory store IS the writer
    // connection behind the same non-reentrant mutex.
    let was_migrated = is_migrated(store)?;

    let conn = store
        .conn
        .lock()
        .map_err(|e| StoreError::Storage(e.to_string()))?;

    let plans = plan_migration(&conn)?;

    if !dry_run {
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("collection migration begin: {e}")))?;
        for plan in &plans {
            for row in &plan.rewrites {
                tx.execute(
                    "UPDATE items SET schema_ref = ?1, payload = ?2 WHERE id = ?3",
                    params![COLLECTION_SCHEMA, row.payload_json, row.id],
                )
                .map_err(|e| StoreError::Storage(format!("collection migration write: {e}")))?;
            }
        }
        // The marker rides the same transaction as the last batch: a store is
        // never half-converged, and a crash mid-run leaves the flag off.
        tx.execute(
            "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?1, ?2)",
            params![MARKER_KEY, MARKER_VALUE],
        )
        .map_err(|e| StoreError::Storage(format!("collection migration marker: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Storage(format!("collection migration commit: {e}")))?;
    }

    Ok(MigrationReport {
        dry_run,
        was_migrated,
        bindings: plans
            .iter()
            .map(|p| BindingMigration {
                schema_ref: p.schema_ref,
                kind_scope: p.kind_scope,
                found: p.rewrites.len() as u64,
                rewritten: p.rewrites.len() as u64,
                skipped_already_generic: p.skipped_already_generic,
            })
            .collect(),
        membership_edges_untouched: true,
    })
}

// ─── Rollback ────────────────────────────────────────────────────────────────

/// Put every migrated collection back under its original schema and payload.
///
/// Restores the verbatim `payload` text and `schema_ref` captured by
/// [`migrate_collections`], then clears [`MARKER_KEY`] — all in one
/// transaction. Rows created NATIVELY as `collection@1.0.0` carry no
/// provenance keys, are left strictly alone, and are counted separately in
/// [`RollbackReport::native_generic_untouched`].
///
/// A REWIND, not a merge: the stored payload is the one the migration froze,
/// so edits made to a migrated row after the migration are discarded with it.
/// Rows created after the migration carry no provenance and survive untouched.
///
/// Safe to run on an unmigrated store: it finds nothing, restores nothing and
/// clears a marker that was already absent.
pub fn rollback_collections(store: &SqliteItemStore) -> Result<RollbackReport, StoreError> {
    let conn = store
        .conn
        .lock()
        .map_err(|e| StoreError::Storage(e.to_string()))?;

    let candidates = generic_rows(&conn)?;

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| StoreError::Storage(format!("collection rollback begin: {e}")))?;

    let mut restored: BTreeMap<String, u64> = BTreeMap::new();
    let mut native = 0u64;

    for row in &candidates {
        let payload: BTreeMap<String, Value> = parse_payload(&row.payload_json, &row.id)?;
        let (schema_ref, original) = match (
            string_of(&payload, LEGACY_SCHEMA_REF_KEY),
            string_of(&payload, LEGACY_PAYLOAD_KEY),
        ) {
            (Some(schema_ref), Some(original)) => (schema_ref, original),
            // Provenance is all-or-nothing: a row with only one of the two
            // keys was hand-edited, and guessing the other half is how a
            // rollback eats data. Leave it as a native row.
            _ => {
                native += 1;
                continue;
            }
        };
        tx.execute(
            "UPDATE items SET schema_ref = ?1, payload = ?2 WHERE id = ?3",
            params![schema_ref, original, row.id],
        )
        .map_err(|e| StoreError::Storage(format!("collection rollback write: {e}")))?;
        *restored.entry(schema_ref).or_insert(0) += 1;
    }

    tx.execute(
        "DELETE FROM store_metadata WHERE key = ?1",
        params![MARKER_KEY],
    )
    .map_err(|e| StoreError::Storage(format!("collection rollback marker: {e}")))?;
    tx.commit()
        .map_err(|e| StoreError::Storage(format!("collection rollback commit: {e}")))?;

    Ok(RollbackReport {
        bindings: restored
            .into_iter()
            .map(|(schema_ref, restored)| BindingRollback {
                schema_ref,
                restored,
            })
            .collect(),
        native_generic_untouched: native,
        membership_edges_untouched: true,
    })
}

// ─── Internals ───────────────────────────────────────────────────────────────

/// A row as the migration sees it: everything the rewrite reads, and nothing
/// else. `payload_json` is the raw column text — the thing rollback restores.
struct RawRow {
    id: String,
    schema_ref: String,
    payload_json: String,
    envelope_parent: Option<String>,
}

/// One rewrite the plan will apply.
struct PlannedRewrite {
    id: String,
    payload_json: String,
}

/// One binding's share of the plan.
struct BindingPlan {
    schema_ref: &'static str,
    kind_scope: &'static str,
    rewrites: Vec<PlannedRewrite>,
    skipped_already_generic: u64,
}

/// The `kind_scope` a legacy binding's rows take on. Every binding in
/// [`MIGRATED_BINDINGS`] has one by construction.
fn unified_scope(binding: &CollectionSchemaBinding) -> &'static str {
    binding
        .unified_kind_scope
        .expect("a migrated binding declares its unified kind_scope")
}

/// Compute the whole rewrite without applying any of it. This is the ONE
/// implementation of "what would change" — dry-run and the real run differ
/// only in whether the result is executed.
fn plan_migration(conn: &Connection) -> Result<Vec<BindingPlan>, StoreError> {
    let mut plans = Vec::with_capacity(MIGRATED_BINDINGS.len());
    for binding in MIGRATED_BINDINGS {
        let scope = unified_scope(&binding);
        let rows = rows_of_schema(conn, binding.schema_ref)?;
        let mut rewrites = Vec::with_capacity(rows.len());
        for row in &rows {
            rewrites.push(PlannedRewrite {
                id: row.id.clone(),
                payload_json: unified_payload(&binding, scope, row)?,
            });
        }
        plans.push(BindingPlan {
            schema_ref: binding.schema_ref,
            kind_scope: scope,
            rewrites,
            skipped_already_generic: already_generic(conn, binding.schema_ref)?,
        });
    }
    Ok(plans)
}

fn rows_of_schema(conn: &Connection, schema_ref: &str) -> Result<Vec<RawRow>, StoreError> {
    let mut stmt = conn
        .prepare("SELECT id, schema_ref, payload, parent_id FROM items WHERE schema_ref = ?1")
        .map_err(|e| StoreError::Storage(format!("collection migration scan: {e}")))?;
    let rows = stmt
        .query_map(params![schema_ref], |row| {
            Ok(RawRow {
                id: row.get(0)?,
                schema_ref: row.get(1)?,
                payload_json: row.get(2)?,
                envelope_parent: row.get(3)?,
            })
        })
        .map_err(|e| StoreError::Storage(format!("collection migration scan: {e}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| StoreError::Storage(format!("collection migration scan: {e}")))
}

fn generic_rows(conn: &Connection) -> Result<Vec<RawRow>, StoreError> {
    rows_of_schema(conn, COLLECTION_SCHEMA)
}

/// Rows already converged FROM this legacy schema by an earlier run.
fn already_generic(conn: &Connection, legacy_schema_ref: &str) -> Result<u64, StoreError> {
    conn.query_row(
        "SELECT COUNT(*) FROM items
         WHERE schema_ref = ?1 AND json_extract(payload, '$.legacy_schema_ref') = ?2",
        params![COLLECTION_SCHEMA, legacy_schema_ref],
        |row| row.get::<_, i64>(0),
    )
    .optional()
    .map_err(|e| StoreError::Storage(format!("collection migration count: {e}")))
    .map(|n| n.unwrap_or(0).max(0) as u64)
}

/// Build the `collection@1.0.0` payload for one legacy row.
///
/// Deterministic in the row's original payload alone (plus, for figures, its
/// envelope parent) — which is what makes migrate → rollback → migrate produce
/// byte-identical payloads.
fn unified_payload(
    binding: &CollectionSchemaBinding,
    kind_scope: &'static str,
    row: &RawRow,
) -> Result<String, StoreError> {
    let original = parse_payload(&row.payload_json, &row.id)?;

    // Keys the canonical fields consume. Everything else lands under `legacy`.
    let mut consumed: Vec<&str> = vec!["name", "sort_order", "is_smart"];
    let parent = match binding.parent_field {
        ParentField::Payload(field) => {
            consumed.push(field);
            string_of(&original, field).and_then(|s| normalize_id(&s))
        }
        // Figure folders keep the envelope as their tree edge; the migration
        // MIRRORS it into payload `parent_id` and leaves the envelope alone,
        // so envelope-filed figure membership survives untouched.
        ParentField::Envelope => row.envelope_parent.as_deref().and_then(|s| normalize_id(s)),
    };

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert(
        "name".into(),
        Value::String(string_of(&original, "name").unwrap_or_default()),
    );
    payload.insert("kind_scope".into(), Value::String(kind_scope.to_string()));
    // Omitted for a root, exactly as `collection_ops::create` writes it.
    if let Some(parent) = parent {
        payload.insert("parent_id".into(), Value::String(parent));
    }
    payload.insert(
        "sort_order".into(),
        Value::Int(int_of(&original, "sort_order").unwrap_or(0)),
    );
    // Carried through rather than hard-cleared: imbib's `create_collection`
    // takes `is_smart`, and silently reclassifying a user's smart collections
    // is exactly the kind of quiet data change this WP exists to avoid.
    payload.insert(
        "is_smart".into(),
        Value::Bool(bool_of(&original, "is_smart").unwrap_or(false)),
    );

    let extras: BTreeMap<String, Value> = original
        .iter()
        .filter(|(key, _)| !consumed.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    if !extras.is_empty() {
        payload.insert(LEGACY_EXTRAS_KEY.into(), Value::Object(extras));
    }

    payload.insert(
        LEGACY_SCHEMA_REF_KEY.into(),
        Value::String(row.schema_ref.clone()),
    );
    payload.insert(
        LEGACY_PAYLOAD_KEY.into(),
        Value::String(row.payload_json.clone()),
    );

    serde_json::to_string(&payload)
        .map_err(|e| StoreError::Storage(format!("collection migration encode {}: {e}", row.id)))
}

fn parse_payload(json: &str, id: &str) -> Result<BTreeMap<String, Value>, StoreError> {
    serde_json::from_str(json)
        .map_err(|e| StoreError::Storage(format!("collection migration parse {id}: {e}")))
}

/// Parse a stored id ref and render it lowercase, dropping empties and
/// garbage. Matches `collection_ops::tree_parent`, which tolerates a legacy
/// uppercase ref and returns it normalized.
fn normalize_id(raw: &str) -> Option<String> {
    if raw.is_empty() {
        return None;
    }
    Uuid::parse_str(raw).ok().map(|u| u.to_string())
}

fn string_of(payload: &BTreeMap<String, Value>, field: &str) -> Option<String> {
    match payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn int_of(payload: &BTreeMap<String, Value>, field: &str) -> Option<i64> {
    match payload.get(field) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

fn bool_of(payload: &BTreeMap<String, Value>, field: &str) -> Option<bool> {
    match payload.get(field) {
        Some(Value::Bool(b)) => Some(*b),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collection_ops::{self, CollectionRow, GENERIC_COLLECTION, MANUSCRIPT_COLLECTION};
    use crate::item::{ActorKind, Item, Priority, Visibility};
    use crate::store::{FieldMutation, ItemStore};
    use chrono::Utc;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    /// A non-collection item (a library, a paper, a figure…).
    fn make_item(store: &SqliteItemStore, schema: &str, title: &str) -> String {
        let now = Utc::now();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        let item = Item {
            id: Uuid::new_v4(),
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: "collection-migration-tests".into(),
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
        store.insert(item).expect("insert").to_string()
    }

    fn uuid_of(raw: &str) -> Uuid {
        Uuid::parse_str(raw).expect("uuid")
    }

    /// Stamp an extra, unregistered payload key onto a collection — the
    /// "somebody wrote a field nobody schema'd" case the migration must not
    /// eat.
    fn stamp(store: &SqliteItemStore, id: &str, field: &str, value: Value) {
        store
            .update(
                uuid_of(id),
                vec![FieldMutation::SetPayload(field.into(), value)],
            )
            .expect("stamp payload");
    }

    fn set_envelope_parent(store: &SqliteItemStore, id: &str, parent: Option<&str>) {
        store
            .update(
                uuid_of(id),
                vec![FieldMutation::SetParent(parent.map(uuid_of))],
            )
            .expect("set envelope parent");
    }

    // ─── Raw snapshots (the byte-faithfulness instruments) ────────────────

    /// Every collection row as SQLite stores it: id, schema_ref, the raw
    /// payload TEXT, and the envelope parent. This is what "byte-equal" means.
    fn raw_rows(store: &SqliteItemStore) -> Vec<(String, String, String, Option<String>)> {
        let mut rows: Vec<(String, String, String, Option<String>)> = store
            .query_raw(
                "SELECT id, schema_ref, payload, parent_id FROM items
                 WHERE schema_ref IN ('imbib/collection', 'manuscript-collection',
                                      'figure-collection', 'collection')",
                params![],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .expect("raw rows");
        rows.sort();
        rows
    }

    /// Every edge in the store. The migration must not move one.
    fn edges(store: &SqliteItemStore) -> Vec<(String, String, String)> {
        let mut rows: Vec<(String, String, String)> = store
            .query_raw(
                "SELECT source_id, target_id, edge_type FROM item_references",
                params![],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .expect("edges");
        rows.sort();
        rows
    }

    /// Every envelope parent in the store, collection or not: the axis figure
    /// membership rides on.
    fn envelope_parents(store: &SqliteItemStore) -> Vec<(String, Option<String>)> {
        let mut rows: Vec<(String, Option<String>)> = store
            .query_raw(
                "SELECT id, parent_id FROM items WHERE schema_ref != 'core/operation'",
                params![],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .expect("envelope parents");
        rows.sort();
        rows
    }

    /// What the kernel answers through one binding: the whole tree, every
    /// collection's member ids, and every member count. Compared verbatim
    /// across the flip.
    type KernelView = (Vec<CollectionRow>, Vec<Vec<String>>, Vec<u32>);

    fn kernel_view(
        store: &SqliteItemStore,
        binding: &collection_ops::CollectionSchemaBinding,
    ) -> KernelView {
        let mut tree = collection_ops::list_tree(store, binding).expect("list_tree");
        tree.sort_by(|a, b| a.id.cmp(&b.id));
        let ids: Vec<String> = tree.iter().map(|r| r.id.clone()).collect();
        let members: Vec<Vec<String>> = ids
            .iter()
            .map(|id| {
                let mut m: Vec<String> = collection_ops::list_members(store, binding, id)
                    .expect("list_members")
                    .iter()
                    .map(|i| i.id.to_string())
                    .collect();
                m.sort();
                m
            })
            .collect();
        let counts = collection_ops::member_counts(store, binding, &ids).expect("member_counts");
        (tree, members, counts)
    }

    // ─── Fixtures: one realistic tree per binding ─────────────────────────

    struct Fixture {
        library: String,
        root: String,
        child: String,
        grandchild: String,
        members: Vec<String>,
    }

    /// imbib publication collections: nested folders under an owning library,
    /// `Contains` members, extra payload keys.
    fn imbib_fixture(store: &SqliteItemStore) -> Fixture {
        let library = make_item(store, "imbib/library", "Main library");
        let root = collection_ops::create(store, &IMBIB_COLLECTION, "Reading", None, None, Some(0))
            .expect("root")
            .id;
        set_envelope_parent(store, &root, Some(&library));
        let child = collection_ops::create(
            store,
            &IMBIB_COLLECTION,
            "Queue",
            Some(&root),
            None,
            Some(1),
        )
        .expect("child")
        .id;
        let grandchild = collection_ops::create(
            store,
            &IMBIB_COLLECTION,
            "Urgent",
            Some(&child),
            None,
            Some(2),
        )
        .expect("grandchild")
        .id;

        // Legacy payload keys nothing in the kernel knows about.
        stamp(store, &root, "is_smart", Value::Bool(true));
        stamp(
            store,
            &root,
            "smart_query",
            Value::String("tag:to-read".into()),
        );
        stamp(
            store,
            &child,
            "colour_hint",
            Value::String("#ff8800".into()),
        );

        let a = make_item(store, "imbib/bibliography-entry", "Paper A");
        let b = make_item(store, "imbib/bibliography-entry", "Paper B");
        collection_ops::add_members(store, &IMBIB_COLLECTION, &child, &[a.clone(), b.clone()])
            .expect("add members");
        Fixture {
            library,
            root,
            child,
            grandchild,
            members: vec![a, b],
        }
    }

    /// imprint manuscript folders: `parent_collection_ref` tree, `Contains`
    /// members.
    fn manuscript_fixture(store: &SqliteItemStore) -> Fixture {
        let library = make_item(store, "imbib/library", "Workspace library");
        let root = collection_ops::create(
            store,
            &MANUSCRIPT_COLLECTION,
            "Workspace",
            None,
            None,
            Some(0),
        )
        .expect("root")
        .id;
        set_envelope_parent(store, &root, Some(&library));
        let child = collection_ops::create(
            store,
            &MANUSCRIPT_COLLECTION,
            "Drafts",
            Some(&root),
            None,
            Some(1),
        )
        .expect("child")
        .id;
        let grandchild = collection_ops::create(
            store,
            &MANUSCRIPT_COLLECTION,
            "Submitted",
            Some(&child),
            None,
            Some(2),
        )
        .expect("grandchild")
        .id;
        stamp(store, &child, "is_collapsed", Value::Bool(true));

        let a = make_item(store, "manuscript", "Dark matter review");
        let b = make_item(store, "manuscript", "Rotation curves");
        collection_ops::add_members(
            store,
            &MANUSCRIPT_COLLECTION,
            &child,
            &[a.clone(), b.clone()],
        )
        .expect("add members");
        Fixture {
            library,
            root,
            child,
            grandchild,
            members: vec![a, b],
        }
    }

    /// implore figure folders: envelope nesting AND envelope membership.
    fn figure_fixture(store: &SqliteItemStore) -> Fixture {
        let root = collection_ops::create(
            store,
            &FIGURE_COLLECTION,
            "Paper figures",
            None,
            None,
            Some(0),
        )
        .expect("root")
        .id;
        let child = collection_ops::create(
            store,
            &FIGURE_COLLECTION,
            "Supplement",
            Some(&root),
            None,
            Some(1),
        )
        .expect("child")
        .id;
        let grandchild = collection_ops::create(
            store,
            &FIGURE_COLLECTION,
            "Rejected panels",
            Some(&child),
            None,
            Some(2),
        )
        .expect("grandchild")
        .id;
        stamp(store, &root, "is_collapsed", Value::Bool(false));
        stamp(store, &child, "is_collapsed", Value::Bool(true));

        let a = make_item(store, "figure", "Panel A");
        let b = make_item(store, "figure", "Rotation curve");
        collection_ops::add_members(store, &FIGURE_COLLECTION, &child, &[a.clone(), b.clone()])
            .expect("add members");
        Fixture {
            // Figure folders have no owning library; the root IS the top.
            library: String::new(),
            root,
            child,
            grandchild,
            members: vec![a, b],
        }
    }

    fn fixture_for(
        store: &SqliteItemStore,
        binding: &collection_ops::CollectionSchemaBinding,
    ) -> Fixture {
        match binding.schema_ref {
            "imbib/collection" => imbib_fixture(store),
            "manuscript-collection" => manuscript_fixture(store),
            "figure-collection" => figure_fixture(store),
            other => panic!("no fixture for {other}"),
        }
    }

    // ─── The marker ──────────────────────────────────────────────────────

    #[test]
    fn marker_is_off_by_default_and_status_reports_it() {
        let store = open();
        assert!(!is_migrated(&store).unwrap(), "the flag ships OFF");

        let fixture = imbib_fixture(&store);
        let status = migration_status(&store).unwrap();
        assert!(!status.migrated);
        assert_eq!(status.legacy_total(), 3, "root + child + grandchild");
        assert_eq!(
            status
                .legacy
                .iter()
                .find(|c| c.schema_ref == "imbib/collection")
                .unwrap()
                .rows,
            3
        );
        assert_eq!(
            status
                .legacy
                .iter()
                .map(|c| c.kind_scope)
                .collect::<Vec<_>>(),
            vec!["publication", "manuscript", "figure"],
            "status enumerates every binding, empty or not"
        );
        assert_eq!(status.generic_total(), 0);
        // A store nobody migrated still reads through the legacy binding.
        assert_eq!(
            collection_ops::list_tree(&store, &IMBIB_COLLECTION)
                .unwrap()
                .len(),
            3
        );
        assert_eq!(fixture.members.len(), 2);
    }

    // ─── Dry run ─────────────────────────────────────────────────────────

    #[test]
    fn dry_run_writes_nothing_and_reports_what_the_real_run_will() {
        let store = open();
        imbib_fixture(&store);
        manuscript_fixture(&store);
        figure_fixture(&store);

        let before_rows = raw_rows(&store);
        let before_edges = edges(&store);
        let before_parents = envelope_parents(&store);

        let dry = migrate_collections(&store, true).unwrap();
        assert!(dry.dry_run);
        assert!(!dry.was_migrated);
        assert_eq!(dry.found(), 9, "three trees of three");
        assert_eq!(dry.rewritten(), 9);
        assert!(dry.membership_edges_untouched);

        assert_eq!(raw_rows(&store), before_rows, "a dry run writes NO rows");
        assert_eq!(edges(&store), before_edges);
        assert_eq!(envelope_parents(&store), before_parents);
        assert!(
            !is_migrated(&store).unwrap(),
            "a dry run does NOT set the marker"
        );

        let real = migrate_collections(&store, false).unwrap();
        assert!(!real.dry_run);
        assert_eq!(
            real.bindings, dry.bindings,
            "the dry run reported the real run's counts, per binding"
        );
        assert!(is_migrated(&store).unwrap());
    }

    // ─── Per binding: the kernel reads identically across the flip ────────

    fn assert_binding_survives_the_flip(binding: collection_ops::CollectionSchemaBinding) {
        let store = open();
        let fixture = fixture_for(&store, &binding);
        let scope = binding.unified_kind_scope.unwrap();

        let before_view = kernel_view(&store, &binding);
        let before_rows = raw_rows(&store);
        let before_edges = edges(&store);
        let before_parents = envelope_parents(&store);

        // status → dry run → migrate
        let status = migration_status(&store).unwrap();
        assert_eq!(status.legacy_total(), 3);
        let dry = migrate_collections(&store, true).unwrap();
        assert_eq!(raw_rows(&store), before_rows);

        let report = migrate_collections(&store, false).unwrap();
        let line = report
            .bindings
            .iter()
            .find(|b| b.schema_ref == binding.schema_ref)
            .unwrap();
        assert_eq!(line.found, 3, "{}: found", binding.schema_ref);
        assert_eq!(
            line.rewritten, line.found,
            "{}: count parity found == rewritten",
            binding.schema_ref
        );
        assert_eq!(line.skipped_already_generic, 0);
        assert_eq!(line.kind_scope, scope);
        assert_eq!(
            report.bindings, dry.bindings,
            "{}: dry run predicted it exactly",
            binding.schema_ref
        );

        // The kernel answers IDENTICALLY through the same binding constant.
        assert_eq!(
            kernel_view(&store, &binding),
            before_view,
            "{}: list_tree / list_members / member_counts must not move",
            binding.schema_ref
        );

        // Membership really was not rewritten.
        assert_eq!(
            edges(&store),
            before_edges,
            "{}: Contains edges are untouched",
            binding.schema_ref
        );
        assert_eq!(
            envelope_parents(&store),
            before_parents,
            "{}: envelope parents are untouched",
            binding.schema_ref
        );

        // The rows really are generic now, with the right scope and provenance.
        let status = migration_status(&store).unwrap();
        assert!(status.migrated);
        assert_eq!(status.legacy_total(), 0, "{}", binding.schema_ref);
        let scoped = status
            .generic
            .iter()
            .find(|c| c.kind_scope == scope)
            .unwrap();
        assert_eq!(scoped.rows, 3);
        assert_eq!(scoped.migrated, 3);

        // Ids did not change — the whole reason membership survives.
        for id in [&fixture.root, &fixture.child, &fixture.grandchild] {
            let item = store.get(uuid_of(id)).unwrap().unwrap();
            assert_eq!(item.schema, COLLECTION_SCHEMA);
            assert_eq!(
                item.payload.get("kind_scope"),
                Some(&Value::String(scope.into()))
            );
            assert!(item.payload.contains_key(LEGACY_PAYLOAD_KEY));
            assert_eq!(
                item.payload.get(LEGACY_SCHEMA_REF_KEY),
                Some(&Value::String(binding.schema_ref.into()))
            );
        }

        // The tree edge is the canonical payload field for all three now.
        let child = store.get(uuid_of(&fixture.child)).unwrap().unwrap();
        assert_eq!(
            child.payload.get("parent_id"),
            Some(&Value::String(fixture.root.clone())),
            "{}: parent_id is the tree edge post-migration",
            binding.schema_ref
        );

        // Extra legacy keys are preserved, not eaten.
        let with_extras = match binding.schema_ref {
            "imbib/collection" => &fixture.root,
            _ => &fixture.child,
        };
        let item = store.get(uuid_of(with_extras)).unwrap().unwrap();
        match item.payload.get(LEGACY_EXTRAS_KEY) {
            Some(Value::Object(extras)) => assert!(
                !extras.is_empty(),
                "{}: unknown legacy keys must survive under `legacy`",
                binding.schema_ref
            ),
            other => panic!(
                "{}: expected a legacy sub-object, got {other:?}",
                binding.schema_ref
            ),
        }

        // The owning library, where there is one, stayed on the envelope.
        if !fixture.library.is_empty() {
            let root = store.get(uuid_of(&fixture.root)).unwrap().unwrap();
            assert_eq!(
                root.parent,
                Some(uuid_of(&fixture.library)),
                "{}: the envelope parent is the owning library and must not move",
                binding.schema_ref
            );
        }

        // ── rollback: byte-equal against the pre-migration snapshot ──
        let rollback = rollback_collections(&store).unwrap();
        assert_eq!(rollback.restored(), 3);
        assert_eq!(rollback.native_generic_untouched, 0);
        assert_eq!(
            rollback.bindings[0].schema_ref, binding.schema_ref,
            "restored to the schema it came from"
        );
        assert_eq!(
            raw_rows(&store),
            before_rows,
            "{}: rollback is byte-faithful — schema_ref AND payload text",
            binding.schema_ref
        );
        assert_eq!(edges(&store), before_edges);
        assert_eq!(envelope_parents(&store), before_parents);
        assert!(!is_migrated(&store).unwrap(), "rollback clears the marker");
        assert_eq!(
            kernel_view(&store, &binding),
            before_view,
            "{}: and the kernel is back where it started",
            binding.schema_ref
        );

        // ── migrate again: the round trip is a fixed point ──
        let again = migrate_collections(&store, false).unwrap();
        assert_eq!(again.rewritten(), 3);
        assert_eq!(kernel_view(&store, &binding), before_view);
    }

    #[test]
    fn imbib_collections_survive_the_flip() {
        assert_binding_survives_the_flip(IMBIB_COLLECTION);
    }

    #[test]
    fn manuscript_collections_survive_the_flip() {
        assert_binding_survives_the_flip(MANUSCRIPT_COLLECTION);
    }

    #[test]
    fn figure_collections_survive_the_flip() {
        assert_binding_survives_the_flip(FIGURE_COLLECTION);
    }

    // ─── Idempotency and the round trip ──────────────────────────────────

    #[test]
    fn a_second_migration_rewrites_nothing() {
        let store = open();
        imbib_fixture(&store);
        manuscript_fixture(&store);
        figure_fixture(&store);

        let first = migrate_collections(&store, false).unwrap();
        assert_eq!(first.rewritten(), 9);
        let after_first = raw_rows(&store);

        let second = migrate_collections(&store, false).unwrap();
        assert!(second.was_migrated, "the marker was already set");
        assert_eq!(second.found(), 0, "no legacy rows left to find");
        assert_eq!(second.rewritten(), 0);
        for line in &second.bindings {
            assert_eq!(
                line.skipped_already_generic, 3,
                "{}: the earlier run's rows are accounted for, not silently zero",
                line.schema_ref
            );
        }
        assert_eq!(raw_rows(&store), after_first, "a re-run changes nothing");
    }

    #[test]
    fn migrate_rollback_migrate_reaches_the_identical_state() {
        let store = open();
        imbib_fixture(&store);
        manuscript_fixture(&store);
        figure_fixture(&store);

        let pristine = raw_rows(&store);
        migrate_collections(&store, false).unwrap();
        let migrated = raw_rows(&store);

        rollback_collections(&store).unwrap();
        assert_eq!(raw_rows(&store), pristine, "rollback is byte-faithful");

        migrate_collections(&store, false).unwrap();
        assert_eq!(
            raw_rows(&store),
            migrated,
            "the rewrite is a pure function of the legacy row — payloads are byte-equal"
        );
    }

    /// Byte fidelity has a price and this is it: a rollback rewinds a
    /// pre-migration row to the state the migration froze, discarding edits
    /// made while migrated. Rows created afterwards are not provenance-bearing
    /// and survive. Asserted so nobody discovers it during a drill.
    #[test]
    fn rollback_rewinds_post_migration_edits_to_migrated_rows() {
        let store = open();
        let fixture = manuscript_fixture(&store);
        migrate_collections(&store, false).unwrap();

        collection_ops::rename(&store, &MANUSCRIPT_COLLECTION, &fixture.child, "Renamed").unwrap();
        collection_ops::reorder(&store, &MANUSCRIPT_COLLECTION, &fixture.child, 99).unwrap();
        let fresh = collection_ops::create(
            &store,
            &MANUSCRIPT_COLLECTION,
            "Made after the flip",
            None,
            None,
            Some(5),
        )
        .unwrap()
        .id;

        let report = rollback_collections(&store).unwrap();
        assert_eq!(report.restored(), 3, "the three migrated rows rewind");
        assert_eq!(
            report.native_generic_untouched, 1,
            "the row created after the flip has no legacy schema to go back to"
        );

        let tree = collection_ops::list_tree(&store, &MANUSCRIPT_COLLECTION).unwrap();
        let child = tree.iter().find(|r| r.id == fixture.child).unwrap();
        assert_eq!(
            child.name, "Drafts",
            "the rename made while migrated is rewound with the migration"
        );
        assert_eq!(child.sort_order, 1);
        assert!(
            !tree.iter().any(|r| r.id == fresh),
            "and the post-flip row is now invisible to the legacy binding — it \
             is still a collection@1.0.0 row, which is where it was created"
        );
        assert_eq!(
            collection_ops::list_tree(&store, &GENERIC_COLLECTION)
                .unwrap()
                .iter()
                .filter(|r| r.id == fresh)
                .count(),
            1,
            "nothing was lost: it is right where it was written"
        );
    }

    #[test]
    fn rollback_on_an_unmigrated_store_is_a_no_op() {
        let store = open();
        imbib_fixture(&store);
        let before = raw_rows(&store);
        let report = rollback_collections(&store).unwrap();
        assert_eq!(report.restored(), 0);
        assert_eq!(report.native_generic_untouched, 0);
        assert_eq!(raw_rows(&store), before);
        assert!(!is_migrated(&store).unwrap());
    }

    // ─── Mixed store: native generic rows are not collateral ─────────────

    #[test]
    fn native_generic_collections_are_never_touched() {
        let store = open();
        imbib_fixture(&store);
        manuscript_fixture(&store);
        figure_fixture(&store);

        // A NATIVE mixed-kind collection with members of two kinds — the
        // impress interaction, built before the flip.
        let mixed = collection_ops::create(
            &store,
            &GENERIC_COLLECTION,
            "Grant renewal",
            None,
            Some(KIND_SCOPE_ANY),
            Some(0),
        )
        .unwrap()
        .id;
        let nested = collection_ops::create(
            &store,
            &GENERIC_COLLECTION,
            "Appendix",
            Some(&mixed),
            Some("publication"),
            Some(1),
        )
        .unwrap()
        .id;
        let paper = make_item(&store, "imbib/bibliography-entry", "Cited paper");
        let figure = make_item(&store, "figure", "Budget chart");
        collection_ops::add_members(
            &store,
            &GENERIC_COLLECTION,
            &mixed,
            &[paper.clone(), figure.clone()],
        )
        .unwrap();

        let native_before: Vec<_> = raw_rows(&store)
            .into_iter()
            .filter(|(id, ..)| id == &mixed || id == &nested)
            .collect();
        let generic_view_before = kernel_view(&store, &GENERIC_COLLECTION);

        let report = migrate_collections(&store, false).unwrap();
        assert_eq!(report.rewritten(), 9, "only the legacy rows move");

        let native_after: Vec<_> = raw_rows(&store)
            .into_iter()
            .filter(|(id, ..)| id == &mixed || id == &nested)
            .collect();
        assert_eq!(
            native_after, native_before,
            "natively-created collection@1.0.0 rows are byte-identical after a migration"
        );

        // The generic binding is the DESTINATION: post-flip it legitimately
        // sees every converged row as well as the native ones. That is the
        // convergence, not a leak.
        let generic_after = kernel_view(&store, &GENERIC_COLLECTION);
        assert_eq!(generic_view_before.0.len(), 2, "two native rows before");
        assert_eq!(
            generic_after.0.len(),
            11,
            "2 native + 9 converged: one schema, one hierarchy"
        );
        assert_eq!(
            collection_ops::member_counts(&store, &GENERIC_COLLECTION, &[mixed.clone()]).unwrap(),
            vec![2],
            "the native mixed-kind collection still holds both kinds"
        );

        let status = migration_status(&store).unwrap();
        let any = status
            .generic
            .iter()
            .find(|c| c.kind_scope == KIND_SCOPE_ANY)
            .unwrap();
        assert_eq!(any.rows, 1);
        assert_eq!(any.migrated, 0, "the mixed collection is native");
        let publications = status
            .generic
            .iter()
            .find(|c| c.kind_scope == "publication")
            .unwrap();
        assert_eq!(publications.rows, 4, "3 converted + 1 native subcollection");
        assert_eq!(publications.migrated, 3);

        // Rollback leaves the native rows alone and says so.
        let rollback = rollback_collections(&store).unwrap();
        assert_eq!(rollback.restored(), 9);
        assert_eq!(
            rollback.native_generic_untouched, 2,
            "native rows are counted, not converted into a legacy schema they never had"
        );
        let native_rolled_back: Vec<_> = raw_rows(&store)
            .into_iter()
            .filter(|(id, ..)| id == &mixed || id == &nested)
            .collect();
        assert_eq!(native_rolled_back, native_before);
        assert_eq!(
            kernel_view(&store, &GENERIC_COLLECTION),
            generic_view_before
        );
    }

    // ─── The verbs, on the far side ──────────────────────────────────────

    fn assert_verbs_round_trip_post_migration(binding: collection_ops::CollectionSchemaBinding) {
        let store = open();
        let fixture = fixture_for(&store, &binding);
        migrate_collections(&store, false).unwrap();
        let scope = binding.unified_kind_scope.unwrap();

        // create, on a migrated parent, writing a generic row with the right scope
        let created = collection_ops::create(
            &store,
            &binding,
            "New folder",
            Some(&fixture.root),
            // Deliberately a LIE: a converged legacy binding forces its own
            // scope rather than letting a caller mislabel the row.
            Some("task"),
            Some(9),
        )
        .unwrap();
        assert_eq!(created.parent_id.as_deref(), Some(fixture.root.as_str()));
        assert_eq!(
            created.kind_scope, None,
            "{}: the row shape legacy callers see does not change at the flip",
            binding.schema_ref
        );
        let item = store.get(uuid_of(&created.id)).unwrap().unwrap();
        assert_eq!(item.schema, COLLECTION_SCHEMA);
        assert_eq!(
            item.payload.get("kind_scope"),
            Some(&Value::String(scope.into()))
        );
        assert!(
            !item.payload.contains_key(LEGACY_SCHEMA_REF_KEY),
            "a natively-created row carries no provenance and rollback leaves it alone"
        );

        // rename / reorder / reparent, with the undo contract intact
        let renamed = collection_ops::rename(&store, &binding, &created.id, "Renamed").unwrap();
        assert_eq!(renamed.row.name, "Renamed");
        assert_eq!(renamed.prior.name(), Some("New folder"));

        let reordered = collection_ops::reorder(&store, &binding, &created.id, 42).unwrap();
        assert_eq!(reordered.row.sort_order, 42);
        assert_eq!(reordered.prior.sort_order(), Some(9));

        let to_root = collection_ops::reparent(&store, &binding, &created.id, None).unwrap();
        assert_eq!(to_root.row.parent_id, None);
        assert_eq!(to_root.prior.parent_id(), Some(Some(fixture.root.as_str())));
        let back =
            collection_ops::reparent(&store, &binding, &created.id, Some(&fixture.grandchild))
                .unwrap();
        assert_eq!(
            back.row.parent_id.as_deref(),
            Some(fixture.grandchild.as_str())
        );
        assert_eq!(back.prior.parent_id(), Some(None), "it was a root");
        if binding.envelope_parent == collection_ops::EnvelopeParent::TreeParent {
            let moved = store.get(uuid_of(&created.id)).unwrap().unwrap();
            assert_eq!(
                moved.parent,
                Some(uuid_of(&fixture.grandchild)),
                "a converged figure folder keeps its envelope in step with the tree"
            );
        }

        // The cycle check still bites on generic-schema rows.
        let cycle =
            collection_ops::reparent(&store, &binding, &fixture.root, Some(&fixture.grandchild));
        assert!(
            matches!(cycle, Err(StoreError::Validation(ref m)) if m.contains("cycle")),
            "{}: {cycle:?}",
            binding.schema_ref
        );

        // delete → restore, over the migrated rows, byte-for-byte on the tree
        let before_view = kernel_view(&store, &binding);
        let snapshot = collection_ops::delete(&store, &binding, &fixture.child).unwrap();
        let mut snapshot_members = snapshot.member_ids.clone();
        snapshot_members.sort();
        let mut expected_members = fixture.members.clone();
        expected_members.sort();
        assert_eq!(
            snapshot_members, expected_members,
            "{}: membership survived the migration and the delete found it",
            binding.schema_ref
        );
        assert_eq!(
            snapshot.child_collection_ids,
            vec![fixture.grandchild.clone()]
        );

        let restored = collection_ops::restore(&store, &binding, &snapshot).unwrap();
        assert_eq!(restored.id, fixture.child);
        assert_eq!(
            kernel_view(&store, &binding),
            before_view,
            "{}: an undone delete leaves the migrated tree identical",
            binding.schema_ref
        );

        // And a member add/remove pair still inverts itself.
        let extra = make_item(&store, "manuscript", "Late addition");
        let added = collection_ops::add_members(&store, &binding, &fixture.child, &[extra.clone()])
            .unwrap();
        assert_eq!(added, vec![extra.clone()]);
        let removed =
            collection_ops::remove_members(&store, &binding, &fixture.child, &added).unwrap();
        assert_eq!(removed, added);
        assert_eq!(kernel_view(&store, &binding), before_view);
    }

    #[test]
    fn imbib_verbs_round_trip_after_migration() {
        assert_verbs_round_trip_post_migration(IMBIB_COLLECTION);
    }

    #[test]
    fn manuscript_verbs_round_trip_after_migration() {
        assert_verbs_round_trip_post_migration(MANUSCRIPT_COLLECTION);
    }

    #[test]
    fn figure_verbs_round_trip_after_migration() {
        assert_verbs_round_trip_post_migration(FIGURE_COLLECTION);
    }

    // ─── Scope isolation ─────────────────────────────────────────────────

    #[test]
    fn a_converged_binding_refuses_another_kinds_collections() {
        let store = open();
        let imbib = imbib_fixture(&store);
        manuscript_fixture(&store);
        migrate_collections(&store, false).unwrap();

        // Same schema_ref now, different kind_scope: the guard must hold.
        let err = collection_ops::rename(&store, &MANUSCRIPT_COLLECTION, &imbib.root, "Nope");
        assert!(
            matches!(err, Err(StoreError::Validation(ref m)) if m.contains("kind_scope")),
            "a converged binding must not mutate another kind's collections: {err:?}"
        );
        assert_eq!(
            collection_ops::list_tree(&store, &MANUSCRIPT_COLLECTION)
                .unwrap()
                .len(),
            3,
            "and its own tree is exactly its own"
        );
        assert_eq!(
            collection_ops::list_tree(&store, &IMBIB_COLLECTION)
                .unwrap()
                .len(),
            3
        );
    }

    // ─── Payload shape ───────────────────────────────────────────────────

    #[test]
    fn a_migrated_root_omits_parent_id_like_a_native_one() {
        let store = open();
        let fixture = manuscript_fixture(&store);
        migrate_collections(&store, false).unwrap();

        let root = store.get(uuid_of(&fixture.root)).unwrap().unwrap();
        assert!(
            !root.payload.contains_key("parent_id"),
            "a root has no parent_id key at all, exactly as `create` writes it"
        );
        assert!(
            !root.payload.contains_key("parent_collection_ref"),
            "the legacy tree field is gone from the canonical payload"
        );
        // …but it is still readable, verbatim, for the rollback.
        let Some(Value::String(legacy)) = root.payload.get(LEGACY_PAYLOAD_KEY) else {
            panic!("legacy payload missing");
        };
        assert!(legacy.contains("\"name\""));
    }

    #[test]
    fn is_smart_is_carried_through_rather_than_cleared() {
        let store = open();
        let fixture = imbib_fixture(&store);
        migrate_collections(&store, false).unwrap();

        let root = store.get(uuid_of(&fixture.root)).unwrap().unwrap();
        assert_eq!(
            root.payload.get("is_smart"),
            Some(&Value::Bool(true)),
            "a user's smart collection must not be silently reclassified"
        );
        let child = store.get(uuid_of(&fixture.child)).unwrap().unwrap();
        assert_eq!(
            child.payload.get("is_smart"),
            Some(&Value::Bool(false)),
            "and an ordinary one defaults to false"
        );
    }

    #[test]
    fn a_hand_edited_half_provenance_row_is_left_alone() {
        let store = open();
        let fixture = imbib_fixture(&store);
        migrate_collections(&store, false).unwrap();

        // Somebody deleted the verbatim payload but left the schema ref.
        store
            .update(
                uuid_of(&fixture.child),
                vec![FieldMutation::RemovePayload(LEGACY_PAYLOAD_KEY.into())],
            )
            .unwrap();

        let report = rollback_collections(&store).unwrap();
        assert_eq!(report.restored(), 2, "the two intact rows come back");
        assert_eq!(
            report.native_generic_untouched, 1,
            "guessing the missing half is how a rollback eats data"
        );
        let child = store.get(uuid_of(&fixture.child)).unwrap().unwrap();
        assert_eq!(child.schema, COLLECTION_SCHEMA);
    }

    // ─── The resolution table, without a database ────────────────────────

    #[test]
    fn the_resolution_table_matches_the_documented_one() {
        for binding in [IMBIB_COLLECTION, MANUSCRIPT_COLLECTION, FIGURE_COLLECTION] {
            let off = binding.resolved(false);
            assert_eq!(off.schema_ref, binding.schema_ref, "marker off = unchanged");
            assert_eq!(off.parent_field, binding.parent_field);
            assert_eq!(off.kind_scope, None);
            assert_eq!(off.membership, binding.membership);

            let on = binding.resolved(true);
            assert_eq!(on.schema_ref, COLLECTION_SCHEMA);
            assert_eq!(
                on.parent_field,
                crate::collection_ops::ParentField::Payload("parent_id")
            );
            assert_eq!(on.kind_scope, binding.unified_kind_scope);
            assert_eq!(
                on.membership, binding.membership,
                "the membership axis NEVER moves"
            );
            assert_eq!(
                on.kind_scope_field, binding.kind_scope_field,
                "and the reported row shape does not change either"
            );
        }

        // The generic binding is the destination: the flip is a no-op for it.
        assert_eq!(
            GENERIC_COLLECTION.resolved(true),
            crate::collection_ops::ResolvedBinding {
                unified: true,
                ..GENERIC_COLLECTION.resolved(false)
            }
        );
    }

    #[test]
    fn every_migrated_binding_declares_a_kind_scope_and_they_are_distinct() {
        let mut scopes: Vec<&str> = MIGRATED_BINDINGS.iter().map(unified_scope).collect();
        let n = scopes.len();
        scopes.sort_unstable();
        scopes.dedup();
        assert_eq!(scopes.len(), n, "two bindings must not share a kind_scope");
        assert_ne!(
            scopes.iter().position(|s| *s == KIND_SCOPE_ANY),
            Some(0),
            "no legacy binding may claim the unscoped 'any'"
        );
        assert!(
            !MIGRATED_BINDINGS
                .iter()
                .any(|b| b.schema_ref == COLLECTION_SCHEMA),
            "the generic schema is the destination, never a source"
        );
    }
}
