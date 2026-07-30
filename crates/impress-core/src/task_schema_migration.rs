//! Task / agent-run schema-ref convergence (WP C4).
//!
//! The flagged, reversible data migration that re-spells existing rows onto the
//! canonical `task@1.0.0` / `agent-run@1.0.0`. C4 unified the *code* first
//! (registries, writers, readers, descriptors); this is the *data* half, and it
//! rewrites rows in live user stores, so every property below is a contract.
//!
//! # The four losing spellings
//!
//! | legacy `schema_ref` | becomes | who wrote it |
//! |---|---|---|
//! | `impel/task` | `task@1.0.0` | impel's Swift `SharedTaskBridge` (a MIRROR of its GRDB tasks) |
//! | `task` | `task@1.0.0` | nothing in production — an impress-core registration and some test fixtures |
//! | `impel/agent-run` | `agent-run@1.0.0` | `SharedTaskBridge` *attempted* it; see the note below |
//! | `agent-run` | `agent-run@1.0.0` | nothing in production |
//!
//! Only `impel/task` is expected to have real rows. `SharedTaskBridge`'s
//! agent-run writer built its item id as `"<taskID>-run-<n>"`, and
//! `impress-store-ffi`'s `upsert_item` rejects any id that does not parse as a
//! UUID — so every one of those writes failed with `invalid UUID` and was
//! swallowed into a log line. The two bare spellings were registered, never
//! written. The migration covers all four anyway: it costs one indexed
//! `UPDATE … WHERE schema_ref = ?` per spelling against zero rows, and "we
//! assumed that spelling was empty" is not a thing to find out later.
//!
//! # The contract
//!
//! 1. **Default OFF.** Nothing here runs on open. [`MARKER_KEY`] is absent
//!    until a human calls [`migrate_task_spellings`], exactly as
//!    [`crate::collection_migration`]'s `collections.unified` marker gates G7.
//! 2. **Dry-run is first-class.** `migrate_task_spellings(store, true)`
//!    performs ZERO writes and reports the counts the real run will report —
//!    including [`SpellingMigration::newly_schedulable`], the number that
//!    answers "what happens on the next `impel-taskd` pass". Same code path;
//!    the plan is computed once and only *applied* when `dry_run` is false.
//! 3. **Payloads are never touched.** Unlike G7, this migration needs no
//!    payload provenance, because it changes exactly one column:
//!    `items.schema_ref`. The reverse direction reads the CHANGED-ID LEDGER
//!    ([`LEDGER_KEY`] in `store_metadata`), so a round trip is byte-equal at
//!    the column level for `payload` trivially and for `schema_ref` by
//!    construction. No `legacy_payload` key appears in anybody's data.
//! 4. **Ids never change**, so `DependsOn` / `ProducedBy` / `OperatesOn` edges,
//!    Swift selection state and undo snapshots all keep pointing at live rows.
//! 5. **`modified` and `logical_clock` are NOT bumped.** A schema convergence
//!    is not a user edit. Bumping them would flood the sync outbox and reorder
//!    every "recently modified" surface in the suite. The consequence, stated
//!    plainly: a CloudKit peer (ADR-0020, default OFF) does not learn about the
//!    re-spelling until the row's next real edit — each device runs the
//!    migration for itself, which is why it is idempotent and cheap.
//! 6. **Idempotent.** A second run finds no legacy rows and rewrites nothing;
//!    the ledger MERGES rather than overwrites, so a row re-spelled by a stale
//!    writer and migrated by a later run is still reversible.
//! 7. **Atomic.** Every rewrite, the ledger and the marker commit in ONE
//!    transaction. A store is never half-converged.
//!
//! # Scheduling side effects — the burst analysis
//!
//! Rows moving INTO `task@1.0.0` enter the reach of
//! [`crate::sqlite_store::SqliteItemStore::ready_tasks`], which is what
//! `impel-taskd` drains. A mirror row acquired by the scheduler would be
//! flipped to `running` and then, because no executor matches, to `failed`
//! with a bogus `error` — corrupting a view of impel's own history and writing
//! ~5 operation-journal rows per task while doing it.
//!
//! Three independent bounds make that unreachable, in decreasing order of
//! how much they are load-bearing:
//!
//! 1. **`ready_tasks` requires a non-empty payload `task_kind`** (added in C4;
//!    see its doc comment). It is the scheduler's executor dispatch key, so
//!    "ready" now means "dispatchable". Bridge-mirrored rows carry no
//!    `task_kind` — they are a projection of a task another system runs — so
//!    the count of newly-schedulable rows for `impel/task` is structurally
//!    ZERO, and [`SpellingMigration::newly_schedulable`] measures it per
//!    spelling on the real store BEFORE the flip. This is the bound that turns
//!    the burst from "bounded" into "absent".
//! 2. **Batch and poll.** `SchedulerConfig::batch` is 8 per pass and
//!    `impel-taskd --poll` defaults to 5 s, so even a store full of genuinely
//!    dispatchable migrated tasks drains at ~8 per 5 s, not all at once —
//!    the same shape as the enrichment-trigger fix's watermark bound.
//! 3. **The migration is opt-in and the daemon is opt-in.** The marker ships
//!    off; touching the live store additionally needs `impel-taskd --enable`,
//!    and `--dry-run` reports what a pass would acquire without writing.
//!
//! A legacy row that DOES carry `task_kind` (a kernel-shaped task written
//! before the spelling settled) becomes schedulable, and that is the intended
//! repair, not a regression: it was a pending task nobody would ever run.
//! `newly_schedulable` is what tells an operator how many of those there are.
//!
//! # What this migration does NOT do
//!
//! It does not touch payload `state`. Mirror rows keep impel's GRDB vocabulary
//! (`queued`/`completed`); `TaskState::parse_compat` accepts it at the kernel
//! boundary and `TaskRecordKind`'s declared lifecycle already labels it. It
//! does not rewrite edges, parents, tags or timestamps.

use std::collections::BTreeMap;

use rusqlite::{params, Connection};

use crate::schemas::task::{AGENT_RUN_SCHEMA, TASK_SCHEMA};
use crate::sqlite_store::SqliteItemStore;
use crate::store::StoreError;

/// `store_metadata` key holding the convergence flag. Present with
/// [`MARKER_VALUE`] means this store's task/agent-run rows are canonically
/// spelled.
pub const MARKER_KEY: &str = "tasks.canonical-spelling";

/// The only value [`MARKER_KEY`] is ever written with.
pub const MARKER_VALUE: &str = "1";

/// `store_metadata` key holding the changed-id ledger: a JSON object mapping
/// each legacy `schema_ref` to the ids moved off it, ascending. This is the
/// rollback source of truth, and the reason no payload is ever rewritten.
pub const LEDGER_KEY: &str = "tasks.canonical-spelling.moved";

/// One legacy spelling and the canonical ref it converges onto, in stable
/// report order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpellingMove {
    /// The `schema_ref` rows currently carry.
    pub legacy_ref: &'static str,
    /// The `schema_ref` they will carry.
    pub canonical_ref: &'static str,
}

/// The four spellings this migration converges. The canonical refs are
/// deliberately absent as sources: they are the destination.
pub const CONVERGED_SPELLINGS: [SpellingMove; 4] = [
    SpellingMove {
        legacy_ref: "impel/task",
        canonical_ref: TASK_SCHEMA,
    },
    SpellingMove {
        legacy_ref: "task",
        canonical_ref: TASK_SCHEMA,
    },
    SpellingMove {
        legacy_ref: "impel/agent-run",
        canonical_ref: AGENT_RUN_SCHEMA,
    },
    SpellingMove {
        legacy_ref: "agent-run",
        canonical_ref: AGENT_RUN_SCHEMA,
    },
];

// ─── Report types ────────────────────────────────────────────────────────────

/// Rows still stored under one legacy spelling.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyRowCount {
    /// The legacy `schema_ref`.
    pub legacy_ref: &'static str,
    /// What it converges onto.
    pub canonical_ref: &'static str,
    /// Rows still carrying the legacy spelling.
    pub rows: u64,
}

/// What [`migration_status`] answers: is this store converged, and what is in
/// it?
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationStatus {
    /// The [`MARKER_KEY`] flag.
    pub migrated: bool,
    /// Per legacy spelling, in [`CONVERGED_SPELLINGS`] order.
    pub legacy: Vec<LegacyRowCount>,
    /// Rows already under `task@1.0.0`.
    pub canonical_tasks: u64,
    /// Rows already under `agent-run@1.0.0`.
    pub canonical_runs: u64,
    /// Ids recorded in the ledger — the rows a rollback would rewind.
    pub ledger_rows: u64,
}

impl MigrationStatus {
    /// Total rows still under a legacy spelling.
    pub fn legacy_total(&self) -> u64 {
        self.legacy.iter().map(|c| c.rows).sum()
    }
}

/// One legacy spelling's share of a migration run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpellingMigration {
    /// The legacy `schema_ref` this line is about.
    pub legacy_ref: &'static str,
    /// The canonical ref its rows now carry.
    pub canonical_ref: &'static str,
    /// Legacy rows found.
    pub found: u64,
    /// Rows rewritten. Equals `found` — a run that cannot rewrite a row it
    /// found fails the whole transaction rather than report a shortfall.
    /// Identical for a dry run, which computes the same plan and applies none.
    pub rewritten: u64,
    /// Of `found`, how many satisfy `ready_tasks`' own predicate (state
    /// `pending`/`queued` AND a non-empty `task_kind`) and so become
    /// schedulable the moment the flip lands. An UPPER BOUND: unmet
    /// `DependsOn` edges can only reduce it. Always 0 for the agent-run
    /// spellings, which are not tasks.
    pub newly_schedulable: u64,
    /// Rows this spelling already contributed to the canonical ref in an
    /// earlier run, per the ledger. What makes a second run's zero legible
    /// rather than alarming.
    pub skipped_already_canonical: u64,
}

/// What [`migrate_task_spellings`] did (or, for a dry run, would do).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationReport {
    /// True when nothing was written.
    pub dry_run: bool,
    /// The marker's state BEFORE this run.
    pub was_migrated: bool,
    /// Per legacy spelling, in [`CONVERGED_SPELLINGS`] order.
    pub spellings: Vec<SpellingMigration>,
    /// Always `true`: the migration writes `items.schema_ref` and nothing
    /// else — not `payload`, not `modified`, not `logical_clock`, not edges.
    pub payloads_untouched: bool,
}

impl MigrationReport {
    /// Total rows rewritten.
    pub fn rewritten(&self) -> u64 {
        self.spellings.iter().map(|s| s.rewritten).sum()
    }

    /// Total legacy rows found.
    pub fn found(&self) -> u64 {
        self.spellings.iter().map(|s| s.found).sum()
    }

    /// Total rows the scheduler will newly pick up. The burst bound, measured.
    pub fn newly_schedulable(&self) -> u64 {
        self.spellings.iter().map(|s| s.newly_schedulable).sum()
    }
}

/// One legacy spelling's share of a rollback.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpellingRollback {
    /// The legacy `schema_ref` restored.
    pub legacy_ref: String,
    /// Rows put back under it.
    pub restored: u64,
    /// Ledger ids that were NOT restored: the row is gone, or no longer
    /// carries the canonical ref (deleted, or re-spelled by something else
    /// since). Counted, never guessed at.
    pub skipped: u64,
}

/// What [`rollback_task_spellings`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RollbackReport {
    /// Per legacy `schema_ref`, ascending.
    pub spellings: Vec<SpellingRollback>,
    /// Always `true`, for the same reason as on [`MigrationReport`].
    pub payloads_untouched: bool,
}

impl RollbackReport {
    /// Total rows restored.
    pub fn restored(&self) -> u64 {
        self.spellings.iter().map(|s| s.restored).sum()
    }

    /// Total ledger ids skipped.
    pub fn skipped(&self) -> u64 {
        self.spellings.iter().map(|s| s.skipped).sum()
    }
}

// ─── Marker + ledger ─────────────────────────────────────────────────────────

/// Are this store's task/agent-run rows canonically spelled?
///
/// One indexed `store_metadata` lookup on a pooled reader, same shape as
/// `collection_migration::is_migrated`.
pub fn is_migrated(store: &SqliteItemStore) -> Result<bool, StoreError> {
    let values = store.query_raw(
        "SELECT value FROM store_metadata WHERE key = ?1",
        params![MARKER_KEY],
        |row| row.get::<_, String>(0),
    )?;
    Ok(values.first().map(|v| v == MARKER_VALUE).unwrap_or(false))
}

/// The changed-id ledger: legacy `schema_ref` → ids moved off it.
///
/// Empty (not an error) when absent or unparseable — a corrupt ledger must not
/// make the store unopenable, and an empty one degrades rollback to a no-op
/// rather than to a guess.
pub fn ledger(store: &SqliteItemStore) -> Result<BTreeMap<String, Vec<String>>, StoreError> {
    let values = store.query_raw(
        "SELECT value FROM store_metadata WHERE key = ?1",
        params![LEDGER_KEY],
        |row| row.get::<_, String>(0),
    )?;
    Ok(values
        .first()
        .and_then(|json| serde_json::from_str(json).ok())
        .unwrap_or_default())
}

// ─── Status ──────────────────────────────────────────────────────────────────

/// Count what is in the store, on both sides of the convergence.
///
/// Safe at any time: writes nothing, holds no transaction.
pub fn migration_status(store: &SqliteItemStore) -> Result<MigrationStatus, StoreError> {
    let migrated = is_migrated(store)?;
    let mut legacy = Vec::with_capacity(CONVERGED_SPELLINGS.len());
    for spelling in CONVERGED_SPELLINGS {
        legacy.push(LegacyRowCount {
            legacy_ref: spelling.legacy_ref,
            canonical_ref: spelling.canonical_ref,
            rows: count_of_schema(store, spelling.legacy_ref)?,
        });
    }
    let ledger_rows = ledger(store)?.values().map(|ids| ids.len() as u64).sum();
    Ok(MigrationStatus {
        migrated,
        legacy,
        canonical_tasks: count_of_schema(store, TASK_SCHEMA)?,
        canonical_runs: count_of_schema(store, AGENT_RUN_SCHEMA)?,
        ledger_rows,
    })
}

// ─── Migrate ─────────────────────────────────────────────────────────────────

/// Converge the four legacy task/agent-run spellings onto `task@1.0.0` /
/// `agent-run@1.0.0`.
///
/// `dry_run: true` computes the identical plan, reports the identical counts —
/// including `newly_schedulable` — and writes NOTHING: not the rows, not the
/// ledger, not the marker. Run it first; its numbers are the real run's
/// numbers.
///
/// The real run applies every rewrite, merges the ledger and sets
/// [`MARKER_KEY`] in one transaction, so flag and data can never disagree.
pub fn migrate_task_spellings(
    store: &SqliteItemStore,
    dry_run: bool,
) -> Result<MigrationReport, StoreError> {
    // Read marker/ledger BEFORE taking the writer lock: the reader pool for an
    // in-memory store IS the writer connection behind the same non-reentrant
    // mutex (the same footgun `collection_migration` documents).
    let was_migrated = is_migrated(store)?;
    let mut merged = ledger(store)?;

    let conn = store
        .conn
        .lock()
        .map_err(|e| StoreError::Storage(e.to_string()))?;

    let plans = plan_migration(&conn, &merged)?;

    if !dry_run {
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("task spelling migration begin: {e}")))?;
        for plan in &plans {
            for id in &plan.ids {
                tx.execute(
                    "UPDATE items SET schema_ref = ?1 WHERE id = ?2",
                    params![plan.spelling.canonical_ref, id],
                )
                .map_err(|e| StoreError::Storage(format!("task spelling migration write: {e}")))?;
            }
            if plan.ids.is_empty() {
                continue;
            }
            // MERGE, never replace: an earlier run's ids stay reversible even
            // if a stale writer produced a second batch under the same
            // spelling afterwards.
            let entry = merged
                .entry(plan.spelling.legacy_ref.to_string())
                .or_default();
            entry.extend(plan.ids.iter().cloned());
            entry.sort();
            entry.dedup();
        }
        tx.execute(
            "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?1, ?2)",
            params![
                LEDGER_KEY,
                serde_json::to_string(&merged).map_err(|e| StoreError::Storage(format!(
                    "task spelling migration ledger encode: {e}"
                )))?
            ],
        )
        .map_err(|e| StoreError::Storage(format!("task spelling migration ledger: {e}")))?;
        // The marker rides the same transaction: never half-converged, and a
        // crash mid-run leaves the flag off.
        tx.execute(
            "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?1, ?2)",
            params![MARKER_KEY, MARKER_VALUE],
        )
        .map_err(|e| StoreError::Storage(format!("task spelling migration marker: {e}")))?;
        tx.commit()
            .map_err(|e| StoreError::Storage(format!("task spelling migration commit: {e}")))?;
    }

    Ok(MigrationReport {
        dry_run,
        was_migrated,
        spellings: plans
            .iter()
            .map(|p| SpellingMigration {
                legacy_ref: p.spelling.legacy_ref,
                canonical_ref: p.spelling.canonical_ref,
                found: p.ids.len() as u64,
                rewritten: p.ids.len() as u64,
                newly_schedulable: p.newly_schedulable,
                skipped_already_canonical: p.already_canonical,
            })
            .collect(),
        payloads_untouched: true,
    })
}

// ─── Rollback ────────────────────────────────────────────────────────────────

/// Put every migrated row back under the spelling it came from.
///
/// Reads the changed-id ledger and restores each id's original `schema_ref`,
/// then clears both the ledger and [`MARKER_KEY`] — all in one transaction.
///
/// A row is restored only if it is still present AND still carries the
/// canonical ref; anything else is counted in
/// [`SpellingRollback::skipped`] and left alone. Rows created AFTER the
/// migration are not in the ledger and are never touched, so a rollback cannot
/// invent a legacy spelling for a row that never had one.
///
/// Unlike G7's rollback this is not a rewind of user edits: the migration froze
/// no payload, so an edit made while migrated survives the rollback intact.
/// Only the `schema_ref` moves back.
///
/// Safe on an unmigrated store: the ledger is empty, nothing is restored, and
/// it clears keys that were already absent.
pub fn rollback_task_spellings(store: &SqliteItemStore) -> Result<RollbackReport, StoreError> {
    let recorded = ledger(store)?;

    let conn = store
        .conn
        .lock()
        .map_err(|e| StoreError::Storage(e.to_string()))?;

    let tx = conn
        .unchecked_transaction()
        .map_err(|e| StoreError::Storage(format!("task spelling rollback begin: {e}")))?;

    let mut spellings = Vec::with_capacity(recorded.len());
    for (legacy_ref, ids) in &recorded {
        let canonical = CONVERGED_SPELLINGS
            .iter()
            .find(|s| s.legacy_ref == legacy_ref)
            .map(|s| s.canonical_ref);
        let mut restored = 0u64;
        let mut skipped = 0u64;
        for id in ids {
            // Guarded by BOTH id and current spelling: a row somebody deleted,
            // or re-spelled by another migration since, is not ours to move.
            let affected = match canonical {
                Some(canonical) => tx
                    .execute(
                        "UPDATE items SET schema_ref = ?1 WHERE id = ?2 AND schema_ref = ?3",
                        params![legacy_ref, id, canonical],
                    )
                    .map_err(|e| {
                        StoreError::Storage(format!("task spelling rollback write: {e}"))
                    })?,
                // A ledger entry for a spelling this build no longer knows
                // about. Report it; never guess a destination.
                None => 0,
            };
            if affected > 0 {
                restored += 1;
            } else {
                skipped += 1;
            }
        }
        spellings.push(SpellingRollback {
            legacy_ref: legacy_ref.clone(),
            restored,
            skipped,
        });
    }

    for key in [LEDGER_KEY, MARKER_KEY] {
        tx.execute("DELETE FROM store_metadata WHERE key = ?1", params![key])
            .map_err(|e| StoreError::Storage(format!("task spelling rollback marker: {e}")))?;
    }
    tx.commit()
        .map_err(|e| StoreError::Storage(format!("task spelling rollback commit: {e}")))?;

    Ok(RollbackReport {
        spellings,
        payloads_untouched: true,
    })
}

// ─── Internals ───────────────────────────────────────────────────────────────

/// One spelling's share of the plan.
struct SpellingPlan {
    spelling: SpellingMove,
    /// Ids to rewrite, ascending (stable ledger output).
    ids: Vec<String>,
    /// Of `ids`, how many `ready_tasks` will select once re-spelled.
    newly_schedulable: u64,
    /// Ids this spelling already contributed, per the ledger.
    already_canonical: u64,
}

/// Compute the whole rewrite without applying any of it — the ONE
/// implementation of "what would change". Dry-run and the real run differ only
/// in whether the result is executed.
fn plan_migration(
    conn: &Connection,
    recorded: &BTreeMap<String, Vec<String>>,
) -> Result<Vec<SpellingPlan>, StoreError> {
    let mut plans = Vec::with_capacity(CONVERGED_SPELLINGS.len());
    for spelling in CONVERGED_SPELLINGS {
        let ids = ids_of_schema(conn, spelling.legacy_ref)?;
        let newly_schedulable = if spelling.canonical_ref == TASK_SCHEMA {
            schedulable_count(conn, spelling.legacy_ref)?
        } else {
            0
        };
        plans.push(SpellingPlan {
            spelling,
            ids,
            newly_schedulable,
            already_canonical: recorded
                .get(spelling.legacy_ref)
                .map(|ids| ids.len() as u64)
                .unwrap_or(0),
        });
    }
    Ok(plans)
}

fn ids_of_schema(conn: &Connection, schema_ref: &str) -> Result<Vec<String>, StoreError> {
    let mut stmt = conn
        .prepare("SELECT id FROM items WHERE schema_ref = ?1 ORDER BY id")
        .map_err(|e| StoreError::Storage(format!("task spelling scan: {e}")))?;
    let rows = stmt
        .query_map(params![schema_ref], |row| row.get::<_, String>(0))
        .map_err(|e| StoreError::Storage(format!("task spelling scan: {e}")))?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(|e| StoreError::Storage(format!("task spelling scan: {e}")))
}

/// Rows of `schema_ref` that `ready_tasks` would select if they carried
/// `task@1.0.0`. The predicate is a deliberate copy of `ready_tasks`' own
/// state/`task_kind` clauses, minus the `DependsOn` sub-select — so this is an
/// upper bound, which is the safe direction for a "how big is the burst"
/// number. `tasks_migrated_into_the_queue_are_only_the_dispatchable_ones`
/// pins the two against each other.
fn schedulable_count(conn: &Connection, schema_ref: &str) -> Result<u64, StoreError> {
    conn.query_row(
        "SELECT COUNT(*) FROM items
         WHERE schema_ref = ?1
           AND json_extract(payload, '$.state') IN ('pending', 'queued')
           AND COALESCE(json_extract(payload, '$.task_kind'), '') != ''",
        params![schema_ref],
        |row| row.get::<_, i64>(0),
    )
    .map_err(|e| StoreError::Storage(format!("task spelling schedulable count: {e}")))
    .map(|n| n.max(0) as u64)
}

fn count_of_schema(store: &SqliteItemStore, schema_ref: &str) -> Result<u64, StoreError> {
    let rows = store.query_raw(
        "SELECT COUNT(*) FROM items WHERE schema_ref = ?1",
        params![schema_ref],
        |row| row.get::<_, i64>(0),
    )?;
    Ok(rows.first().copied().unwrap_or(0).max(0) as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ActorKind, Item, Priority, Value, Visibility};
    use crate::reference::{EdgeType, TypedReference};
    use crate::store::ItemStore;
    use chrono::Utc;
    use uuid::Uuid;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    /// Insert a row with an EXPLICIT `schema_ref`, the way a writer from
    /// before the convergence did. The envelope is otherwise a normal item, so
    /// these rows are indistinguishable from real ones to every query under
    /// test.
    fn seed(
        store: &SqliteItemStore,
        schema: &str,
        fields: &[(&str, Value)],
        references: Vec<TypedReference>,
    ) -> Uuid {
        let now = Utc::now();
        let payload: BTreeMap<String, Value> = fields
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect();
        let item = Item {
            id: Uuid::new_v4(),
            schema: schema.into(),
            payload,
            created: now,
            modified: now,
            author: "task-spelling-tests".into(),
            author_kind: ActorKind::Agent,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references,
            parent: None,
        };
        store.insert(item).expect("seed insert")
    }

    fn s(value: &str) -> Value {
        Value::String(value.into())
    }

    /// EXACTLY what `SharedTaskBridge.taskCreated` writes: a mirror of a GRDB
    /// task. Note what is absent — no `task_kind`, because impel's own
    /// orchestrator runs this task, not impress's scheduler.
    fn seed_bridge_task(store: &SqliteItemStore, title: &str, state: &str) -> Uuid {
        let external = Uuid::new_v4().to_string();
        seed(
            store,
            "impel/task",
            &[
                ("title", s(title)),
                ("state", s(state)),
                ("description", s("full query text sent to counsel")),
                ("source_app", s("impel")),
                ("external_id", s(&external)),
            ],
            vec![],
        )
    }

    /// EXACTLY what `SharedTaskBridge.agentRoundCompleted` builds. In the wild
    /// these writes all FAILED (the id was `"<taskID>-run-<n>"`, which
    /// `upsert_item` rejects as a non-UUID), so real stores hold none — the
    /// fixture exists so the migration is tested against the shape anyway.
    fn seed_bridge_run(store: &SqliteItemStore, round: i64) -> Uuid {
        seed(
            store,
            "impel/agent-run",
            &[
                ("agent_id", s("counsel")),
                ("model", s("claude-opus-4-6")),
                ("prompt_hash", s("deadbeef")),
                ("round_number", Value::Int(round)),
                ("status", s("completed")),
            ],
            vec![],
        )
    }

    /// A kernel-shaped task (`create_task_dag`'s payload) that ended up under
    /// a losing spelling: this one SHOULD become schedulable.
    fn seed_kernel_shaped_task(store: &SqliteItemStore, schema: &str, kind: &str) -> Uuid {
        seed(
            store,
            schema,
            &[
                ("title", s(kind)),
                ("task_kind", s(kind)),
                ("state", s("pending")),
            ],
            vec![],
        )
    }

    /// Every row's id, schema_ref and RAW payload text — what "byte-equal"
    /// means for this migration.
    fn raw_rows(store: &SqliteItemStore) -> Vec<(String, String, String, i64, i64)> {
        let mut rows: Vec<(String, String, String, i64, i64)> = store
            .query_raw(
                "SELECT id, schema_ref, payload, modified, logical_clock FROM items",
                params![],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
            )
            .expect("raw rows");
        rows.sort();
        rows
    }

    fn ready_ids(store: &SqliteItemStore) -> Vec<Uuid> {
        let mut ids: Vec<Uuid> = store
            .ready_tasks(64)
            .expect("ready_tasks")
            .iter()
            .map(|i| i.id)
            .collect();
        ids.sort();
        ids
    }

    // ─── The marker ───────────────────────────────────────────────────────

    #[test]
    fn marker_is_off_by_default_and_status_reports_it() {
        let store = open();
        assert!(!is_migrated(&store).unwrap(), "the flag ships OFF");

        seed_bridge_task(&store, "Summarise the Bardeen paper", "queued");
        seed_bridge_run(&store, 1);

        let status = migration_status(&store).unwrap();
        assert!(!status.migrated);
        assert_eq!(status.legacy_total(), 2);
        assert_eq!(
            status
                .legacy
                .iter()
                .map(|c| c.legacy_ref)
                .collect::<Vec<_>>(),
            vec!["impel/task", "task", "impel/agent-run", "agent-run"],
            "status enumerates every spelling, empty or not"
        );
        assert_eq!(status.canonical_tasks, 0);
        assert_eq!(status.ledger_rows, 0);
    }

    // ─── Dry run ──────────────────────────────────────────────────────────

    #[test]
    fn dry_run_writes_nothing_and_reports_what_the_real_run_will() {
        let store = open();
        seed_bridge_task(&store, "Draft the response", "queued");
        seed_bridge_task(&store, "Finished thing", "completed");
        seed_bridge_run(&store, 1);
        seed_kernel_shaped_task(&store, "task", "metadata-resolve");

        let before = raw_rows(&store);

        let dry = migrate_task_spellings(&store, true).unwrap();
        assert!(dry.dry_run);
        assert!(!dry.was_migrated);
        assert_eq!(dry.found(), 4);
        assert_eq!(dry.rewritten(), 4);
        assert_eq!(raw_rows(&store), before, "a dry run writes NO rows");
        assert!(!is_migrated(&store).unwrap(), "…and sets no marker");
        assert!(ledger(&store).unwrap().is_empty(), "…and no ledger");

        let real = migrate_task_spellings(&store, false).unwrap();
        assert!(!real.dry_run);
        assert_eq!(
            real.spellings, dry.spellings,
            "the dry run reported the real run's counts, per spelling"
        );
        assert!(is_migrated(&store).unwrap());
    }

    // ─── The round trip ───────────────────────────────────────────────────

    #[test]
    fn every_losing_spelling_round_trips_byte_equal() {
        let store = open();
        let bridge_task = seed_bridge_task(&store, "Reply to the referee", "queued");
        let bridge_run = seed_bridge_run(&store, 2);
        let bare_task = seed_kernel_shaped_task(&store, "task", "keyword-tag");
        let bare_run = seed(
            &store,
            "agent-run",
            &[
                ("agent_id", s("librarian")),
                ("model", s("heuristic-v1")),
                ("prompt_hash", s("cafe")),
            ],
            vec![],
        );
        // A row that is ALREADY canonical, and a non-task row: neither is the
        // migration's business.
        let native = seed_kernel_shaped_task(&store, TASK_SCHEMA, "metadata-resolve");
        let paper = seed(
            &store,
            "imbib/bibliography-entry",
            &[("title", s("A"))],
            vec![],
        );

        let pristine = raw_rows(&store);

        let report = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(report.found(), 4);
        assert_eq!(report.rewritten(), 4);
        assert!(report.payloads_untouched);
        for line in &report.spellings {
            assert_eq!(line.found, 1, "{}", line.legacy_ref);
            assert_eq!(line.skipped_already_canonical, 0);
        }

        // Every row now carries its canonical ref, and NOTHING else moved.
        for (id, expected) in [
            (bridge_task, TASK_SCHEMA),
            (bare_task, TASK_SCHEMA),
            (bridge_run, AGENT_RUN_SCHEMA),
            (bare_run, AGENT_RUN_SCHEMA),
            (native, TASK_SCHEMA),
        ] {
            let item = store.get(id).unwrap().unwrap();
            assert_eq!(item.schema, expected);
        }
        let migrated_rows = raw_rows(&store);
        assert_eq!(
            migrated_rows.len(),
            pristine.len(),
            "no row was added or dropped"
        );
        for ((id, _, payload, modified, clock), (pid, _, ppayload, pmodified, pclock)) in
            migrated_rows.iter().zip(pristine.iter())
        {
            assert_eq!(id, pid);
            assert_eq!(payload, ppayload, "payload text is untouched");
            assert_eq!(modified, pmodified, "`modified` is not bumped");
            assert_eq!(clock, pclock, "`logical_clock` is not bumped");
        }
        let status = migration_status(&store).unwrap();
        assert_eq!(status.legacy_total(), 0);
        assert_eq!(status.ledger_rows, 4);

        // ── reverse ──
        let rollback = rollback_task_spellings(&store).unwrap();
        assert_eq!(rollback.restored(), 4);
        assert_eq!(rollback.skipped(), 0);
        assert!(rollback.payloads_untouched);
        assert_eq!(
            raw_rows(&store),
            pristine,
            "the reverse is byte-equal on every column, for every row"
        );
        assert!(!is_migrated(&store).unwrap(), "rollback clears the marker");
        assert!(ledger(&store).unwrap().is_empty(), "…and the ledger");
        // The already-canonical row and the paper were never in the ledger and
        // so were never candidates to be "restored" to a spelling they never had.
        assert_eq!(store.get(native).unwrap().unwrap().schema, TASK_SCHEMA);
        assert_eq!(
            store.get(paper).unwrap().unwrap().schema,
            "imbib/bibliography-entry"
        );

        // ── and forward again: a fixed point ──
        let again = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(again.rewritten(), 4);
        assert_eq!(raw_rows(&store), migrated_rows);
    }

    // ─── The scheduler contract (the burst analysis, as a test) ───────────

    /// The migration's one dangerous side effect, bounded and measured: rows
    /// arriving in `task@1.0.0` enter `ready_tasks`' reach. Only the
    /// DISPATCHABLE ones do — a bridge mirror row (no `task_kind`) is never
    /// acquired, so it can never be flipped to `running`/`failed` by a
    /// scheduler pass, and `newly_schedulable` predicts the exact set.
    #[test]
    fn tasks_migrated_into_the_queue_are_only_the_dispatchable_ones() {
        let store = open();
        // Three mirror rows in states `ready_tasks` accepts…
        let mirrors = [
            seed_bridge_task(&store, "Draft a reply to Referee 2", "queued"),
            seed_bridge_task(&store, "Summarise these three papers", "queued"),
            seed_bridge_task(&store, "Find the missing DOI", "pending"),
        ];
        // …one mirror in a state it does not…
        seed_bridge_task(&store, "Already done", "completed");
        // …and one genuinely dispatchable task stranded under a losing spelling.
        let dispatchable = seed_kernel_shaped_task(&store, "impel/task", "metadata-resolve");

        assert!(
            ready_ids(&store).is_empty(),
            "nothing is schedulable before the flip — that is the bug C4 fixes \
             for the kernel-shaped row and the non-bug it preserves for mirrors"
        );

        let dry = migrate_task_spellings(&store, true).unwrap();
        assert_eq!(
            dry.newly_schedulable(),
            1,
            "the dry run predicts the burst BEFORE any write: one row, not five"
        );
        let impel_line = dry
            .spellings
            .iter()
            .find(|s| s.legacy_ref == "impel/task")
            .unwrap();
        assert_eq!(impel_line.found, 5);
        assert_eq!(impel_line.newly_schedulable, 1);

        let report = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(report.newly_schedulable(), 1);

        // The prediction is the reality: `ready_tasks` agrees exactly.
        assert_eq!(
            ready_ids(&store),
            vec![dispatchable],
            "the mirrored counsel history is NOT queued for execution"
        );
        for mirror in mirrors {
            let item = store.get(mirror).unwrap().unwrap();
            assert_eq!(item.schema, TASK_SCHEMA, "it IS converged…");
            assert!(
                !item.payload.contains_key("task_kind"),
                "…and still not dispatchable"
            );
        }
    }

    /// An unmet dependency still blocks after migration — the migration adds
    /// rows to the queue's reach without loosening any of its other rules.
    #[test]
    fn dependencies_still_gate_a_migrated_task() {
        let store = open();
        let blocker = seed_kernel_shaped_task(&store, "impel/task", "metadata-resolve");
        let blocked = seed(
            &store,
            "impel/task",
            &[
                ("title", s("keyword-tag")),
                ("task_kind", s("keyword-tag")),
                ("state", s("pending")),
            ],
            vec![TypedReference {
                target: blocker,
                edge_type: EdgeType::DependsOn,
                metadata: None,
            }],
        );

        let report = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(
            report.newly_schedulable(),
            2,
            "the count is an upper bound: it does not model DependsOn"
        );
        assert_eq!(
            ready_ids(&store),
            vec![blocker],
            "…and the real queue does, so only the blocker is ready"
        );
        assert!(store.get(blocked).unwrap().is_some());
    }

    // ─── Idempotency and the awkward cases ────────────────────────────────

    #[test]
    fn a_second_migration_rewrites_nothing_and_says_why() {
        let store = open();
        seed_bridge_task(&store, "One", "queued");
        seed_bridge_task(&store, "Two", "queued");

        let first = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(first.rewritten(), 2);
        let after_first = raw_rows(&store);

        let second = migrate_task_spellings(&store, false).unwrap();
        assert!(second.was_migrated, "the marker was already set");
        assert_eq!(second.found(), 0, "no legacy rows left to find");
        let line = second
            .spellings
            .iter()
            .find(|s| s.legacy_ref == "impel/task")
            .unwrap();
        assert_eq!(
            line.skipped_already_canonical, 2,
            "the earlier run's rows are accounted for, not silently zero"
        );
        assert_eq!(raw_rows(&store), after_first, "a re-run changes nothing");
    }

    /// A stale writer (an un-updated app build) writes a legacy row AFTER the
    /// migration. The next run picks it up and the ledger keeps BOTH batches
    /// reversible.
    #[test]
    fn a_late_legacy_row_is_migrated_and_stays_reversible() {
        let store = open();
        let first_batch = seed_bridge_task(&store, "Before", "queued");
        migrate_task_spellings(&store, false).unwrap();

        let late = seed_bridge_task(&store, "Written by a stale app build", "queued");
        let second = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(second.found(), 1);
        assert_eq!(
            ledger(&store).unwrap()["impel/task"].len(),
            2,
            "the ledger merged rather than overwrote"
        );

        let rollback = rollback_task_spellings(&store).unwrap();
        assert_eq!(rollback.restored(), 2);
        for id in [first_batch, late] {
            assert_eq!(store.get(id).unwrap().unwrap().schema, "impel/task");
        }
    }

    /// Rows deleted while migrated are reported, not resurrected, and do not
    /// abort the rest of the rollback.
    #[test]
    fn rollback_skips_ledger_ids_that_moved_on() {
        let store = open();
        let kept = seed_bridge_task(&store, "Kept", "queued");
        let deleted = seed_bridge_task(&store, "Deleted while migrated", "queued");
        migrate_task_spellings(&store, false).unwrap();
        store.delete(deleted).unwrap();

        let rollback = rollback_task_spellings(&store).unwrap();
        assert_eq!(rollback.restored(), 1);
        assert_eq!(
            rollback.skipped(),
            1,
            "the deleted row is counted, not guessed"
        );
        assert_eq!(store.get(kept).unwrap().unwrap().schema, "impel/task");
        assert!(store.get(deleted).unwrap().is_none());
    }

    #[test]
    fn rollback_on_an_unmigrated_store_is_a_no_op() {
        let store = open();
        seed_bridge_task(&store, "Untouched", "queued");
        let before = raw_rows(&store);
        let report = rollback_task_spellings(&store).unwrap();
        assert_eq!(report.restored(), 0);
        assert_eq!(report.skipped(), 0);
        assert_eq!(raw_rows(&store), before);
        assert!(!is_migrated(&store).unwrap());
    }

    #[test]
    fn migrating_an_empty_store_is_a_no_op_that_still_sets_the_marker() {
        let store = open();
        let report = migrate_task_spellings(&store, false).unwrap();
        assert_eq!(report.found(), 0);
        assert_eq!(report.newly_schedulable(), 0);
        assert!(
            is_migrated(&store).unwrap(),
            "a store with nothing to converge IS converged"
        );
    }

    /// Edges are not part of the rewrite, and the ids they point at do not
    /// change — the reason `ProducedBy` provenance survives the flip.
    #[test]
    fn edges_and_ids_survive_both_directions() {
        let store = open();
        let task = seed_bridge_task(&store, "Has a run", "queued");
        let run = seed(
            &store,
            "impel/agent-run",
            &[
                ("agent_id", s("counsel")),
                ("model", s("m")),
                ("prompt_hash", s("h")),
            ],
            vec![TypedReference {
                target: task,
                edge_type: EdgeType::ProducedBy,
                metadata: None,
            }],
        );
        let edges = |store: &SqliteItemStore| -> Vec<(String, String, String)> {
            let mut rows: Vec<(String, String, String)> = store
                .query_raw(
                    "SELECT source_id, target_id, edge_type FROM item_references",
                    params![],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .expect("edges");
            rows.sort();
            rows
        };
        let before = edges(&store);
        assert!(!before.is_empty());

        migrate_task_spellings(&store, false).unwrap();
        assert_eq!(edges(&store), before, "migration moves no edge");
        assert_eq!(store.get(run).unwrap().unwrap().schema, AGENT_RUN_SCHEMA);

        rollback_task_spellings(&store).unwrap();
        assert_eq!(edges(&store), before, "neither does the rollback");
        assert_eq!(store.get(run).unwrap().unwrap().schema, "impel/agent-run");
    }
}
