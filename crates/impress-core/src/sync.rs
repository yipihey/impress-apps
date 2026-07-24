//! ADR-0007 Phase 3, Phase B: the Rust apply/snapshot sync engine.
//!
//! Everything CloudKit-agnostic lives here: snapshot projection of outbox
//! entries into wire DTOs, last-write-wins merge of remote records into the
//! local store, tombstone races, deferred references, and the manuscript
//! conflict-backup safety net. Swift (Phase D) owns CloudKit I/O and calls
//! this surface through the Phase C FFI mirrors.
//!
//! ## Merge rules (plan decisions 3, 5, 7)
//!
//! - **Items** are whole-record LWW: HLC `logical_clock`, then ActorKind
//!   precedence (Human > Agent > System), then greater `author_id`. A full
//!   tie with *differing content* is resolved by a deterministic content key
//!   (see `content_key`) — two stores can mint identical HLC clocks in the
//!   same millisecond, and a row's `author`/`author_kind`/`origin` belong to
//!   its *creator* (edits never change them), so without the content
//!   tiebreak concurrent edits to a replicated item could tie forever with
//!   divergent payloads. `resolve_lww` itself stays the pure three-step
//!   function; the content key is an apply-layer refinement.
//! - **References** have no per-edge versions: adds are `INSERT OR IGNORE`,
//!   deletes are CKRecord deletions, and the Phase A outbox triggers
//!   coalesce add-then-delete / delete-then-add of one edge so a single
//!   batch never carries both (mirroring CKSyncEngine's per-record pending
//!   change coalescing). Missing endpoints defer to `sync_pending_refs`.
//! - **Tombstones** delete the local row unless `local.modified >
//!   deleted_at` (edit-after-delete resurrects and re-pushes; ties → delete
//!   wins). Applied remote tombstones are recorded in the local `tombstones`
//!   table verbatim — the tombstone-vs-record guard on insert reads that
//!   table, and without the record a duplicate delivery of an older item
//!   batch would resurrect the item on one peer only.
//! - Remote applies run with the per-connection `_sync_apply` suppression
//!   row set, inside one transaction; store events are emitted after commit.

use std::collections::{BTreeMap, HashSet};

use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::event::ItemEvent;
use crate::item::{ActorKind, ItemId, Value};
use crate::manuscript_ops;
use crate::sqlite_store::{parse_actor_kind, SqliteItemStore};
use crate::store::{ItemStore, StoreError};

// ---------------------------------------------------------------------------
// Wire DTOs (plain structs — the uniffi mirrors arrive in Phase C)
// ---------------------------------------------------------------------------

/// One syncable envelope item, projected verbatim from `items` + `item_tags`.
///
/// `envelope_json` folds the rarely-populated envelope columns
/// (`canonical_id`, `visibility`, `message_type`, `produced_by`, `version`,
/// `batch_id`) into a single JSON object so the CKRecord schema stays frozen
/// as the envelope grows (plan decision 4). `visibility` is always present;
/// null fields are omitted.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncItemRecord {
    pub id: String,
    pub schema_ref: String,
    pub payload_json: String,
    pub logical_clock: u64,
    pub author_kind: String,
    pub author_id: String,
    pub origin: String,
    pub created_ms: i64,
    pub modified_ms: i64,
    pub tag_paths: Vec<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub priority: String,
    pub parent_id: Option<String>,
    pub envelope_json: String,
}

/// One typed edge. `record_name` is the deterministic CKRecord name
/// `"ref_" + sha256(source|target|edge)[..32]` (plan decision 5);
/// `logical_clock` carries the *source item's* clock for HLC observation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncReferenceRecord {
    pub record_name: String,
    pub source_id: String,
    pub target_id: String,
    pub edge_type: String,
    pub metadata: Option<String>,
    pub logical_clock: u64,
}

/// One deletion marker (`ImpressTombstone` CKRecord). `record_name` is the
/// lowercased item UUID.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SyncTombstoneRecord {
    pub record_name: String,
    pub schema_ref: String,
    pub deleted_at_ms: i64,
    pub origin: String,
}

/// Outcome counters for one remote-apply call.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncApplyReport {
    pub applied: u32,
    pub skipped_lww: u32,
    pub deferred: u32,
    pub resurrected: u32,
    pub conflict_backups: u32,
}

/// Live queue depths for Settings / `/api/sync/status`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncCounts {
    pub outbox: u32,
    pub pending_refs: u32,
    pub tombstones: u32,
}

// ---------------------------------------------------------------------------
// Pure merge helpers
// ---------------------------------------------------------------------------

/// ActorKind precedence for LWW ties: Human > Agent > System.
fn kind_rank(kind: &str) -> u8 {
    match parse_actor_kind(kind) {
        ActorKind::Human => 2,
        ActorKind::Agent => 1,
        ActorKind::System => 0,
    }
}

/// Whole-record last-write-wins: does the remote version win?
///
/// 1. Greater HLC `logical_clock` wins.
/// 2. Tie → ActorKind precedence: Human > Agent > System.
/// 3. Tie → greater `author_id` (lexicographic) wins.
/// 4. Full tie → remote does NOT win (idempotent re-apply of an identical
///    record is a skip; genuinely divergent full ties are resolved by the
///    apply layer's content key, see `content_key`).
///
/// Antisymmetric for non-identical inputs, so two peers evaluating the
/// mirrored comparison always agree on the winner.
pub fn resolve_lww(
    local_clock: u64,
    local_kind: &str,
    local_author: &str,
    remote_clock: u64,
    remote_kind: &str,
    remote_author: &str,
) -> bool {
    if remote_clock != local_clock {
        return remote_clock > local_clock;
    }
    let (lk, rk) = (kind_rank(local_kind), kind_rank(remote_kind));
    if rk != lk {
        return rk > lk;
    }
    remote_author > local_author
}

/// Deterministic CKRecord name for a reference edge:
/// `"ref_" + sha256(source|target|edge)[..32]` (plan decision 5).
pub fn sync_reference_record_name(source_id: &str, target_id: &str, edge_type: &str) -> String {
    let digest = manuscript_ops::sha256_hex(&format!("{}|{}|{}", source_id, target_id, edge_type));
    format!("ref_{}", &digest[..32])
}

/// Canonicalize a JSON object string: parse into the crate's
/// `BTreeMap`-backed `Value` (sorted keys at every level) and re-serialize.
/// Unparseable input is returned verbatim.
fn canonical_json(json: &str) -> String {
    match serde_json::from_str::<BTreeMap<String, Value>>(json) {
        Ok(map) => serde_json::to_string(&map).unwrap_or_else(|_| json.to_string()),
        Err(_) => json.to_string(),
    }
}

/// Deterministic content key for full-LWW-tie resolution. Both peers compute
/// the same key for the same record content (payload canonicalized, tags
/// sorted), so "remote wins iff its key is greater" is antisymmetric and
/// convergent; equal keys mean the records are materially identical and the
/// re-apply is skipped.
fn content_key(rec: &SyncItemRecord) -> String {
    let mut tags = rec.tag_paths.clone();
    tags.sort();
    serde_json::to_string(&(
        &rec.schema_ref,
        canonical_json(&rec.payload_json),
        rec.created_ms,
        rec.modified_ms,
        rec.is_read,
        rec.is_starred,
        &rec.flag_color,
        &rec.flag_style,
        &rec.flag_length,
        &rec.priority,
        &rec.parent_id,
        &tags,
        canonical_json(&rec.envelope_json),
        &rec.origin,
    ))
    .unwrap_or_default()
}

/// Full merge decision between a local row and a remote record: `resolve_lww`
/// first, content key only on a full three-way tie.
fn remote_wins_over_local(local: &SyncItemRecord, remote: &SyncItemRecord) -> bool {
    if resolve_lww(
        local.logical_clock,
        &local.author_kind,
        &local.author_id,
        remote.logical_clock,
        &remote.author_kind,
        &remote.author_id,
    ) {
        return true;
    }
    let full_tie = local.logical_clock == remote.logical_clock
        && kind_rank(&local.author_kind) == kind_rank(&remote.author_kind)
        && local.author_id == remote.author_id;
    full_tie && content_key(remote) > content_key(local)
}

/// The envelope columns folded into `envelope_json`.
#[derive(Default)]
struct EnvelopeFields {
    canonical_id: Option<String>,
    visibility: String,
    message_type: Option<String>,
    produced_by: Option<String>,
    version: Option<String>,
    batch_id: Option<String>,
}

fn build_envelope_json(fields: &EnvelopeFields) -> String {
    let mut env = serde_json::Map::new();
    if let Some(v) = &fields.canonical_id {
        env.insert("canonical_id".into(), v.as_str().into());
    }
    env.insert("visibility".into(), fields.visibility.as_str().into());
    if let Some(v) = &fields.message_type {
        env.insert("message_type".into(), v.as_str().into());
    }
    if let Some(v) = &fields.produced_by {
        env.insert("produced_by".into(), v.as_str().into());
    }
    if let Some(v) = &fields.version {
        env.insert("version".into(), v.as_str().into());
    }
    if let Some(v) = &fields.batch_id {
        env.insert("batch_id".into(), v.as_str().into());
    }
    serde_json::Value::Object(env).to_string()
}

fn parse_envelope_json(envelope_json: &str) -> EnvelopeFields {
    let mut fields = EnvelopeFields {
        visibility: "private".into(),
        ..Default::default()
    };
    let Ok(serde_json::Value::Object(env)) =
        serde_json::from_str::<serde_json::Value>(envelope_json)
    else {
        return fields;
    };
    let get = |key: &str| env.get(key).and_then(|v| v.as_str()).map(String::from);
    fields.canonical_id = get("canonical_id");
    if let Some(v) = get("visibility") {
        fields.visibility = v;
    }
    fields.message_type = get("message_type");
    fields.produced_by = get("produced_by");
    fields.version = get("version");
    fields.batch_id = get("batch_id");
    fields
}

fn extract_body_content(payload_json: &str) -> String {
    serde_json::from_str::<serde_json::Value>(payload_json)
        .ok()
        .and_then(|v| {
            v.get("body_content")
                .and_then(|b| b.as_str())
                .map(String::from)
        })
        .unwrap_or_default()
}

fn parse_item_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id).map_err(|e| {
        StoreError::Validation(format!("sync record id '{}' is not a UUID: {}", id, e))
    })
}

// ---------------------------------------------------------------------------
// The engine — inherent methods on SqliteItemStore
// ---------------------------------------------------------------------------

impl SqliteItemStore {
    /// Run `f` inside one transaction on the writer connection with the
    /// `_sync_apply` suppression row set, so nothing `f` writes re-enters
    /// the outbox or the tombstone chokepoint. The suppression row is
    /// removed afterwards **unconditionally** — error paths included.
    fn with_suppressed_tx<T>(
        &self,
        f: impl FnOnce(&Connection) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        conn.execute("INSERT INTO _sync_apply (flag) VALUES (1)", [])
            .map_err(|e| StoreError::Storage(format!("suppress capture: {}", e)))?;
        let result = (|| {
            let tx = conn
                .unchecked_transaction()
                .map_err(|e| StoreError::Storage(format!("sync tx: {}", e)))?;
            let out = f(&tx)?;
            tx.commit()
                .map_err(|e| StoreError::Storage(format!("sync commit: {}", e)))?;
            Ok(out)
        })();
        // ALWAYS restore capture — a poisoned suppression flag would
        // silently stop change tracking for the rest of the process.
        let _ = conn.execute("DELETE FROM _sync_apply", []);
        result
    }

    /// Project one syncable item row (+ its tags) into a `SyncItemRecord`.
    /// Returns `None` for missing rows, operation items, and ephemeral rows —
    /// none of those sync (plan decision 2).
    fn sync_item_record_on(
        conn: &Connection,
        id: &str,
    ) -> Result<Option<SyncItemRecord>, StoreError> {
        let row = conn
            .query_row(
                "SELECT id, schema_ref, payload, logical_clock, author_kind, author,
                        COALESCE(origin, ''), created, modified, is_read, is_starred,
                        flag_color, flag_style, flag_length, priority, parent_id,
                        canonical_id, visibility, message_type, produced_by, version, batch_id
                 FROM items
                 WHERE id = ?1
                   AND op_target_id IS NULL
                   AND COALESCE(retention, 'durable') != 'ephemeral'",
                params![id],
                |r| {
                    let envelope = EnvelopeFields {
                        canonical_id: r.get(16)?,
                        visibility: r.get(17)?,
                        message_type: r.get(18)?,
                        produced_by: r.get(19)?,
                        version: r.get(20)?,
                        batch_id: r.get(21)?,
                    };
                    Ok(SyncItemRecord {
                        id: r.get(0)?,
                        schema_ref: r.get(1)?,
                        payload_json: r.get(2)?,
                        logical_clock: r.get::<_, i64>(3)? as u64,
                        author_kind: r.get(4)?,
                        author_id: r.get(5)?,
                        origin: r.get(6)?,
                        created_ms: r.get(7)?,
                        modified_ms: r.get(8)?,
                        tag_paths: Vec::new(),
                        is_read: r.get::<_, i64>(9)? != 0,
                        is_starred: r.get::<_, i64>(10)? != 0,
                        flag_color: r.get(11)?,
                        flag_style: r.get(12)?,
                        flag_length: r.get(13)?,
                        priority: r.get(14)?,
                        parent_id: r.get(15)?,
                        envelope_json: build_envelope_json(&envelope),
                    })
                },
            )
            .optional()
            .map_err(|e| StoreError::Storage(format!("sync item projection: {}", e)))?;

        let Some(mut record) = row else {
            return Ok(None);
        };

        let mut stmt = conn
            .prepare("SELECT tag_path FROM item_tags WHERE item_id = ?1 ORDER BY tag_path")
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let tags = stmt
            .query_map(params![id], |r| r.get::<_, String>(0))
            .map_err(|e| StoreError::Storage(e.to_string()))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        record.tag_paths = tags;
        Ok(Some(record))
    }

    /// Record a *remote-origin* tombstone locally, keeping the newest
    /// `deleted_at` on conflict. Required (deviation from the original spec's
    /// "skip it"): the tombstone-vs-record guard in `sync_apply_remote_items`
    /// reads this table, and without the entry a duplicate delivery of an
    /// older item batch would resurrect the row on this peer only.
    fn record_remote_tombstone_on(
        conn: &Connection,
        id_str: &str,
        schema: &str,
        deleted_at_ms: i64,
        origin: &str,
    ) -> Result<(), StoreError> {
        conn.execute(
            "INSERT INTO tombstones (id, schema_ref, deleted_at, origin)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(id) DO UPDATE SET
                 deleted_at = excluded.deleted_at,
                 schema_ref = excluded.schema_ref,
                 origin = excluded.origin
             WHERE excluded.deleted_at > tombstones.deleted_at",
            params![id_str, schema, deleted_at_ms, origin],
        )
        .map_err(|e| StoreError::Storage(format!("record remote tombstone: {}", e)))?;
        Ok(())
    }

    /// Apply one remote deletion to a local row under the tombstone race
    /// rule: delete unless `local.modified > deleted_at` (ties → delete
    /// wins). On skip the surviving local edit is re-enqueued for push (it
    /// must overwrite the deletion remotely); we are suppressed, so the
    /// outbox row is inserted explicitly. Shared by
    /// `sync_apply_remote_tombstones` and the item-UUID arm of
    /// `sync_apply_remote_deletions`.
    #[allow(clippy::too_many_arguments)]
    fn apply_remote_deletion_on(
        conn: &Connection,
        id_str: &str,
        deleted_at_ms: i64,
        schema_hint: &str,
        origin: &str,
        report: &mut SyncApplyReport,
        deleted_events: &mut Vec<(ItemId, String)>,
    ) -> Result<(), StoreError> {
        let local: Option<(i64, String)> = conn
            .query_row(
                "SELECT modified, schema_ref FROM items WHERE id = ?1",
                params![id_str],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|e| StoreError::Storage(format!("deletion lookup: {}", e)))?;

        match local {
            Some((modified_ms, schema)) => {
                if modified_ms > deleted_at_ms {
                    // Edit-after-delete: the local edit survives and must
                    // overwrite the deletion remotely.
                    report.resurrected += 1;
                    conn.execute(
                        "INSERT INTO sync_outbox (kind, record_name, item_id, queued_at)
                         VALUES ('item', lower(?1), ?1, ?2)
                         ON CONFLICT(kind, record_name) DO UPDATE SET queued_at = excluded.queued_at",
                        params![id_str, Utc::now().timestamp_millis()],
                    )
                    .map_err(|e| StoreError::Storage(format!("resurrect enqueue: {}", e)))?;
                } else {
                    Self::delete_fts(conn, id_str)?;
                    conn.execute("DELETE FROM items WHERE id = ?1", params![id_str])
                        .map_err(|e| StoreError::Storage(format!("apply deletion: {}", e)))?;
                    conn.execute(
                        "DELETE FROM sync_outbox WHERE kind = 'item' AND record_name = lower(?1)",
                        params![id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("deletion outbox prune: {}", e)))?;
                    Self::record_remote_tombstone_on(conn, id_str, &schema, deleted_at_ms, origin)?;
                    report.applied += 1;
                    deleted_events.push((parse_item_id(id_str)?, schema));
                }
            }
            None => {
                // Already gone — still record the tombstone so a later
                // stale item record cannot resurrect (duplicate-delivery
                // guard), then treat as an idempotent apply.
                Self::record_remote_tombstone_on(conn, id_str, schema_hint, deleted_at_ms, origin)?;
                report.applied += 1;
            }
        }
        Ok(())
    }

    // -- Outbox / snapshot (push side) --------------------------------------

    /// Remove confirmed-pushed outbox rows by sequence number.
    pub fn sync_outbox_remove(&self, seqs: Vec<i64>) -> Result<(), StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("outbox remove tx: {}", e)))?;
        {
            let mut stmt = tx
                .prepare("DELETE FROM sync_outbox WHERE seq = ?1")
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            for seq in &seqs {
                stmt.execute(params![seq])
                    .map_err(|e| StoreError::Storage(format!("outbox remove: {}", e)))?;
            }
        }
        tx.commit()
            .map_err(|e| StoreError::Storage(format!("outbox remove commit: {}", e)))?;
        Ok(())
    }

    /// Project outbox `'item'` entries into wire records. Rows that are
    /// operation items, ephemeral, or already gone are omitted — the caller
    /// simply confirms their outbox rows away.
    pub fn sync_snapshot_items(&self, ids: Vec<String>) -> Result<Vec<SyncItemRecord>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut out = Vec::with_capacity(ids.len());
        for id in &ids {
            if let Some(record) = Self::sync_item_record_on(&conn, id)? {
                out.push(record);
            }
        }
        Ok(out)
    }

    /// Project outbox `'reference'` entries (raw `src|tgt|edge` names) into
    /// wire records with hashed `ref_` record names. Edges that no longer
    /// exist are omitted (their deletion, if any, travels separately).
    pub fn sync_snapshot_references(
        &self,
        record_names: Vec<String>,
    ) -> Result<Vec<SyncReferenceRecord>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut out = Vec::with_capacity(record_names.len());
        for raw in &record_names {
            let mut parts = raw.splitn(3, '|');
            let (Some(src), Some(tgt), Some(edge)) = (parts.next(), parts.next(), parts.next())
            else {
                continue;
            };
            let metadata: Option<Option<String>> = conn
                .query_row(
                    "SELECT metadata FROM item_references
                     WHERE source_id = ?1 AND target_id = ?2 AND edge_type = ?3",
                    params![src, tgt, edge],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| StoreError::Storage(format!("snapshot reference: {}", e)))?;
            let Some(metadata) = metadata else {
                continue; // edge gone — nothing to push
            };
            let clock: i64 = conn
                .query_row(
                    "SELECT logical_clock FROM items WHERE id = ?1",
                    params![src],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|e| StoreError::Storage(format!("snapshot ref clock: {}", e)))?
                .unwrap_or(0);
            out.push(SyncReferenceRecord {
                record_name: sync_reference_record_name(src, tgt, edge),
                source_id: src.to_string(),
                target_id: tgt.to_string(),
                edge_type: edge.to_string(),
                metadata,
                logical_clock: clock as u64,
            });
        }
        Ok(out)
    }

    /// Local tombstones since `since_ms`, as wire records (record_name =
    /// lowercased item UUID). Queries the table directly rather than
    /// wrapping `list_tombstones_since`, which drops the `origin` column.
    pub fn sync_local_tombstones(
        &self,
        since_ms: i64,
    ) -> Result<Vec<SyncTombstoneRecord>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut stmt = conn
            .prepare(
                "SELECT id, schema_ref, deleted_at, COALESCE(origin, '')
                 FROM tombstones WHERE deleted_at > ?1 ORDER BY deleted_at ASC",
            )
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let rows = stmt
            .query_map(params![since_ms], |r| {
                Ok(SyncTombstoneRecord {
                    record_name: r.get::<_, String>(0)?.to_lowercase(),
                    schema_ref: r.get(1)?,
                    deleted_at_ms: r.get(2)?,
                    origin: r.get(3)?,
                })
            })
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| StoreError::Storage(format!("local tombstones: {}", e)))
    }

    // -- Remote apply (fetch side) ------------------------------------------

    /// Merge fetched remote item records into the local store (whole-record
    /// LWW, upsert-in-place, tags reconciled, FTS refreshed, tombstone races
    /// honored). Events are emitted after commit.
    ///
    /// Manuscript safety net (plan decision 7): a losing local manuscript
    /// with *unpushed* edits and a differing body gets a
    /// `sync-conflict-backup` revision **before** the overwrite. The backup
    /// runs as an unsuppressed pre-pass outside the apply transaction —
    /// `create_revision` re-enters the store (get/insert/apply_operation
    /// would deadlock on the writer lock), it must read the body before the
    /// overwrite, and the revision is a genuine local item that should sync.
    /// Its head-pointer op bumps the manuscript's clock, so the apply stage
    /// FORCES remote-wins for the pre-decided ids — the decision was made
    /// against pre-backup state and must not flip.
    pub fn sync_apply_remote_items(
        &self,
        records: Vec<SyncItemRecord>,
    ) -> Result<SyncApplyReport, StoreError> {
        let mut report = SyncApplyReport::default();

        // Stage 1: decide which losing local manuscripts need a backup.
        let backup_ids: Vec<String> = {
            let conn = self
                .conn
                .lock()
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let mut ids = Vec::new();
            for rec in &records {
                if rec.schema_ref != "manuscript" {
                    continue;
                }
                let Some(local) = Self::sync_item_record_on(&conn, &rec.id)? else {
                    continue;
                };
                if !remote_wins_over_local(&local, rec) {
                    continue;
                }
                if extract_body_content(&local.payload_json)
                    == extract_body_content(&rec.payload_json)
                {
                    continue;
                }
                let unpushed: bool = conn
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM sync_outbox
                          WHERE kind = 'item' AND record_name = lower(?1))",
                        params![&rec.id],
                        |r| r.get::<_, i64>(0),
                    )
                    .map(|v| v != 0)
                    .unwrap_or(false);
                if unpushed {
                    ids.push(rec.id.clone());
                }
            }
            ids
        };

        // Stage 2: create the conflict-backup revisions (unsuppressed — the
        // backup revision is a genuine local item and syncs like any other).
        for id in &backup_ids {
            let manuscript_id = parse_item_id(id)?;
            let tag = format!("sync-conflict-{}", manuscript_ops::iso8601_now());
            manuscript_ops::create_revision(
                self,
                manuscript_id,
                &tag,
                "sync-conflict-backup",
                &self.default_author,
                self.default_author_kind,
            )?;
            report.conflict_backups += 1;
        }
        let forced_remote_wins: HashSet<String> =
            backup_ids.iter().map(|s| s.to_lowercase()).collect();

        // Stage 3: the suppressed apply transaction.
        let mut created_ids: Vec<ItemId> = Vec::new();
        let mut updated_events: Vec<(ItemId, String)> = Vec::new();
        self.with_suppressed_tx(|conn| {
            // Remote records may arrive before their parents; check FKs at
            // commit instead of per-statement, then detach the stragglers.
            conn.pragma_update(None, "defer_foreign_keys", "ON")
                .map_err(|e| StoreError::Storage(format!("defer fk: {}", e)))?;

            for rec in &records {
                let item_id = parse_item_id(&rec.id)?;
                Self::hlc_observe_remote(conn, rec.logical_clock)?;

                let local = Self::sync_item_record_on(conn, &rec.id)?;
                let envelope = parse_envelope_json(&rec.envelope_json);

                if let Some(local) = local {
                    let forced = forced_remote_wins.contains(&rec.id.to_lowercase());
                    if !forced && !remote_wins_over_local(&local, rec) {
                        report.skipped_lww += 1;
                        continue;
                    }
                    // Upsert-in-place. Never INSERT OR REPLACE: that is a
                    // delete+insert under the hood and would CASCADE away
                    // this item's tags and edges.
                    conn.execute(
                        "UPDATE items SET
                             schema_ref = ?2, payload = ?3, created = ?4, modified = ?5,
                             author = ?6, author_kind = ?7, is_read = ?8, is_starred = ?9,
                             flag_color = ?10, flag_style = ?11, flag_length = ?12,
                             parent_id = ?13, logical_clock = ?14, origin = ?15,
                             canonical_id = ?16, priority = ?17, visibility = ?18,
                             message_type = ?19, produced_by = ?20, version = ?21,
                             batch_id = ?22, op_target_id = NULL, retention = 'durable'
                         WHERE id = ?1",
                        params![
                            &rec.id,
                            &rec.schema_ref,
                            &rec.payload_json,
                            rec.created_ms,
                            rec.modified_ms,
                            &rec.author_id,
                            &rec.author_kind,
                            rec.is_read as i32,
                            rec.is_starred as i32,
                            &rec.flag_color,
                            &rec.flag_style,
                            &rec.flag_length,
                            &rec.parent_id,
                            rec.logical_clock as i64,
                            &rec.origin,
                            &envelope.canonical_id,
                            &rec.priority,
                            &envelope.visibility,
                            &envelope.message_type,
                            &envelope.produced_by,
                            &envelope.version,
                            &envelope.batch_id,
                        ],
                    )
                    .map_err(|e| StoreError::Storage(format!("apply item update: {}", e)))?;
                    updated_events.push((item_id, rec.schema_ref.clone()));
                } else {
                    // Tombstone-vs-record: a local deletion at or after the
                    // remote edit wins; skip the insert.
                    let tombstone_ms: Option<i64> = conn
                        .query_row(
                            "SELECT deleted_at FROM tombstones WHERE id = ?1",
                            params![&rec.id],
                            |r| r.get(0),
                        )
                        .optional()
                        .map_err(|e| StoreError::Storage(format!("tombstone probe: {}", e)))?;
                    if let Some(deleted_at) = tombstone_ms {
                        if deleted_at >= rec.modified_ms {
                            report.skipped_lww += 1;
                            continue;
                        }
                    }
                    conn.execute(
                        "INSERT INTO items (id, schema_ref, payload, created, modified,
                             author, author_kind, is_read, is_starred, flag_color,
                             flag_style, flag_length, parent_id, logical_clock, origin,
                             canonical_id, priority, visibility, message_type, produced_by,
                             version, batch_id, op_target_id, retention)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                                 ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, NULL, 'durable')",
                        params![
                            &rec.id,
                            &rec.schema_ref,
                            &rec.payload_json,
                            rec.created_ms,
                            rec.modified_ms,
                            &rec.author_id,
                            &rec.author_kind,
                            rec.is_read as i32,
                            rec.is_starred as i32,
                            &rec.flag_color,
                            &rec.flag_style,
                            &rec.flag_length,
                            &rec.parent_id,
                            rec.logical_clock as i64,
                            &rec.origin,
                            &envelope.canonical_id,
                            &rec.priority,
                            &envelope.visibility,
                            &envelope.message_type,
                            &envelope.produced_by,
                            &envelope.version,
                            &envelope.batch_id,
                        ],
                    )
                    .map_err(|e| StoreError::Storage(format!("apply item insert: {}", e)))?;
                    created_ids.push(item_id);
                }

                // Reconcile tags to exactly the record's tag_paths.
                conn.execute("DELETE FROM item_tags WHERE item_id = ?1", params![&rec.id])
                    .map_err(|e| StoreError::Storage(format!("reconcile tags clear: {}", e)))?;
                for tag in &rec.tag_paths {
                    conn.execute(
                        "INSERT OR IGNORE INTO item_tags (item_id, tag_path) VALUES (?1, ?2)",
                        params![&rec.id, tag],
                    )
                    .map_err(|e| StoreError::Storage(format!("reconcile tag: {}", e)))?;
                }

                Self::refresh_fts(conn, &rec.id)?;

                // The record now IS local state: any tombstone for it is
                // obsolete (resurrection), and a pending local push would
                // only re-send what we just received.
                let cleared = conn
                    .execute("DELETE FROM tombstones WHERE id = ?1", params![&rec.id])
                    .map_err(|e| StoreError::Storage(format!("clear tombstone: {}", e)))?;
                if cleared > 0 {
                    report.resurrected += 1;
                }
                conn.execute(
                    "DELETE FROM sync_outbox WHERE kind = 'item' AND record_name = lower(?1)",
                    params![&rec.id],
                )
                .map_err(|e| StoreError::Storage(format!("apply outbox prune: {}", e)))?;

                report.applied += 1;
            }

            // Parents that never arrived: detach, matching the FK's
            // ON DELETE SET NULL semantics. If the parent shows up in a
            // later batch its own record re-establishes nothing here — a
            // documented Phase-3.0 limitation (parents ship with children
            // in practice: one zone, one batch stream).
            conn.execute(
                "UPDATE items SET parent_id = NULL
                 WHERE parent_id IS NOT NULL
                   AND parent_id NOT IN (SELECT id FROM items)",
                [],
            )
            .map_err(|e| StoreError::Storage(format!("parent fixup: {}", e)))?;
            Ok(())
        })?;

        // Events after commit, outside the writer lock.
        for id in created_ids {
            if let Ok(Some(item)) = self.get(id) {
                let schema = item.schema.to_string();
                self.emit(Some(&schema), ItemEvent::Created(Box::new(item)));
            }
        }
        for (id, schema) in updated_events {
            self.emit(
                Some(&schema),
                ItemEvent::Updated {
                    id,
                    mutations: vec![],
                },
            );
        }

        Ok(report)
    }

    /// Apply fetched remote reference records: both endpoints present →
    /// `INSERT OR IGNORE`; missing endpoint → parked in `sync_pending_refs`
    /// for `sync_retry_pending_references` (plan decision 5).
    pub fn sync_apply_remote_references(
        &self,
        refs: Vec<SyncReferenceRecord>,
    ) -> Result<SyncApplyReport, StoreError> {
        let mut report = SyncApplyReport::default();
        self.with_suppressed_tx(|conn| {
            for r in &refs {
                Self::hlc_observe_remote(conn, r.logical_clock)?;
                let endpoints: i64 = conn
                    .query_row(
                        "SELECT (SELECT COUNT(*) FROM items WHERE id IN (?1, ?2))",
                        params![&r.source_id, &r.target_id],
                        |row| row.get(0),
                    )
                    .map_err(|e| StoreError::Storage(format!("ref endpoints: {}", e)))?;
                if endpoints == 2 {
                    conn.execute(
                        "INSERT OR IGNORE INTO item_references
                             (source_id, target_id, edge_type, metadata)
                         VALUES (?1, ?2, ?3, ?4)",
                        params![&r.source_id, &r.target_id, &r.edge_type, &r.metadata],
                    )
                    .map_err(|e| StoreError::Storage(format!("apply reference: {}", e)))?;
                    report.applied += 1;
                } else {
                    conn.execute(
                        "INSERT INTO sync_pending_refs
                             (record_name, source_id, target_id, edge_type, metadata,
                              logical_clock, received_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                         ON CONFLICT(record_name) DO UPDATE SET
                             metadata = excluded.metadata,
                             logical_clock = excluded.logical_clock,
                             received_at = excluded.received_at",
                        params![
                            &r.record_name,
                            &r.source_id,
                            &r.target_id,
                            &r.edge_type,
                            &r.metadata,
                            r.logical_clock as i64,
                            Utc::now().timestamp_millis(),
                        ],
                    )
                    .map_err(|e| StoreError::Storage(format!("defer reference: {}", e)))?;
                    report.deferred += 1;
                }
            }
            Ok(())
        })?;
        Ok(report)
    }

    /// Re-attempt every deferred reference. Resolvable ones are applied and
    /// removed; refs whose endpoint is tombstoned are dropped (the edge can
    /// never resolve — counted as `skipped_lww`); the rest stay deferred.
    pub fn sync_retry_pending_references(&self) -> Result<SyncApplyReport, StoreError> {
        let mut report = SyncApplyReport::default();
        self.with_suppressed_tx(|conn| {
            let pending: Vec<(String, String, String, String, Option<String>)> = {
                let mut stmt = conn
                    .prepare(
                        "SELECT record_name, source_id, target_id, edge_type, metadata
                         FROM sync_pending_refs ORDER BY received_at",
                    )
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                let rows = stmt
                    .query_map([], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                    })
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                rows.collect::<Result<Vec<_>, _>>()
                    .map_err(|e| StoreError::Storage(format!("pending refs: {}", e)))?
            };

            for (record_name, source_id, target_id, edge_type, metadata) in &pending {
                let endpoints: i64 = conn
                    .query_row(
                        "SELECT (SELECT COUNT(*) FROM items WHERE id IN (?1, ?2))",
                        params![source_id, target_id],
                        |row| row.get(0),
                    )
                    .map_err(|e| StoreError::Storage(format!("retry endpoints: {}", e)))?;
                if endpoints == 2 {
                    conn.execute(
                        "INSERT OR IGNORE INTO item_references
                             (source_id, target_id, edge_type, metadata)
                         VALUES (?1, ?2, ?3, ?4)",
                        params![source_id, target_id, edge_type, metadata],
                    )
                    .map_err(|e| StoreError::Storage(format!("retry reference: {}", e)))?;
                    conn.execute(
                        "DELETE FROM sync_pending_refs WHERE record_name = ?1",
                        params![record_name],
                    )
                    .map_err(|e| StoreError::Storage(format!("retry dequeue: {}", e)))?;
                    report.applied += 1;
                } else {
                    let tombstoned: i64 = conn
                        .query_row(
                            "SELECT EXISTS(SELECT 1 FROM tombstones WHERE id IN (?1, ?2))",
                            params![source_id, target_id],
                            |row| row.get(0),
                        )
                        .map_err(|e| StoreError::Storage(format!("retry tombstone: {}", e)))?;
                    if tombstoned != 0 {
                        conn.execute(
                            "DELETE FROM sync_pending_refs WHERE record_name = ?1",
                            params![record_name],
                        )
                        .map_err(|e| StoreError::Storage(format!("retry drop: {}", e)))?;
                        report.skipped_lww += 1;
                    } else {
                        report.deferred += 1;
                    }
                }
            }
            Ok(())
        })?;
        Ok(report)
    }

    /// Apply CKRecord *deletions* (no tombstone metadata available):
    /// `ref_...` names delete the matching edge (found by recomputing each
    /// edge's hash — a linear scan, fine at our scale and only when ref
    /// deletions arrive); item-UUID names run the tombstone rule with
    /// `deleted_at = now`.
    pub fn sync_apply_remote_deletions(
        &self,
        record_names: Vec<String>,
    ) -> Result<SyncApplyReport, StoreError> {
        let mut report = SyncApplyReport::default();
        let mut deleted_events: Vec<(ItemId, String)> = Vec::new();
        let now_ms = Utc::now().timestamp_millis();

        self.with_suppressed_tx(|conn| {
            let ref_names: HashSet<&String> = record_names
                .iter()
                .filter(|n| n.starts_with("ref_"))
                .collect();

            if !ref_names.is_empty() {
                let edges: Vec<(String, String, String)> = {
                    let mut stmt = conn
                        .prepare("SELECT source_id, target_id, edge_type FROM item_references")
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    let rows = stmt
                        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    rows.collect::<Result<Vec<_>, _>>()
                        .map_err(|e| StoreError::Storage(format!("edge scan: {}", e)))?
                };
                for (src, tgt, edge) in &edges {
                    let name = sync_reference_record_name(src, tgt, edge);
                    if ref_names.contains(&name) {
                        conn.execute(
                            "DELETE FROM item_references
                             WHERE source_id = ?1 AND target_id = ?2 AND edge_type = ?3",
                            params![src, tgt, edge],
                        )
                        .map_err(|e| StoreError::Storage(format!("delete reference: {}", e)))?;
                        report.applied += 1;
                    }
                }
                // A deletion also cancels any deferred copy of the edge.
                for name in &ref_names {
                    conn.execute(
                        "DELETE FROM sync_pending_refs WHERE record_name = ?1",
                        params![name],
                    )
                    .map_err(|e| StoreError::Storage(format!("delete pending ref: {}", e)))?;
                }
            }

            for name in record_names.iter().filter(|n| !n.starts_with("ref_")) {
                Self::apply_remote_deletion_on(
                    conn,
                    name,
                    now_ms,
                    "unknown",
                    "remote",
                    &mut report,
                    &mut deleted_events,
                )?;
            }
            Ok(())
        })?;

        for (id, schema) in deleted_events {
            self.emit(Some(&schema), ItemEvent::Deleted(id));
        }
        Ok(report)
    }

    /// Apply fetched `ImpressTombstone` records (plan decision 3). Deletes
    /// the local row unless it was modified after the tombstone
    /// (edit-after-delete → resurrect + re-push); ties → delete wins.
    pub fn sync_apply_remote_tombstones(
        &self,
        tombstones: Vec<SyncTombstoneRecord>,
    ) -> Result<SyncApplyReport, StoreError> {
        let mut report = SyncApplyReport::default();
        let mut deleted_events: Vec<(ItemId, String)> = Vec::new();

        self.with_suppressed_tx(|conn| {
            for ts in &tombstones {
                Self::apply_remote_deletion_on(
                    conn,
                    &ts.record_name,
                    ts.deleted_at_ms,
                    &ts.schema_ref,
                    &ts.origin,
                    &mut report,
                    &mut deleted_events,
                )?;
            }
            Ok(())
        })?;

        for (id, schema) in deleted_events {
            self.emit(Some(&schema), ItemEvent::Deleted(id));
        }
        Ok(report)
    }

    // -- Engine state -------------------------------------------------------

    /// Read a sync-namespaced metadata value (`"sync."`-prefixed keys only).
    pub fn sync_metadata_get(&self, key: &str) -> Result<Option<String>, StoreError> {
        if !key.starts_with("sync.") {
            return Err(StoreError::Validation(format!(
                "sync metadata keys must start with 'sync.': '{}'",
                key
            )));
        }
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        conn.query_row(
            "SELECT value FROM store_metadata WHERE key = ?1",
            params![key],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| StoreError::Storage(format!("sync metadata get: {}", e)))
    }

    /// Write (or clear, with `None`) a sync-namespaced metadata value.
    pub fn sync_metadata_set(&self, key: &str, value: Option<String>) -> Result<(), StoreError> {
        if !key.starts_with("sync.") {
            return Err(StoreError::Validation(format!(
                "sync metadata keys must start with 'sync.': '{}'",
                key
            )));
        }
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        match value {
            Some(v) => {
                conn.execute(
                    "INSERT OR REPLACE INTO store_metadata (key, value) VALUES (?1, ?2)",
                    params![key, v],
                )
                .map_err(|e| StoreError::Storage(format!("sync metadata set: {}", e)))?;
            }
            None => {
                conn.execute("DELETE FROM store_metadata WHERE key = ?1", params![key])
                    .map_err(|e| StoreError::Storage(format!("sync metadata clear: {}", e)))?;
            }
        }
        Ok(())
    }

    /// Read the archived CKRecord system fields for a record, if any.
    pub fn sync_record_state_get(&self, record_name: &str) -> Result<Option<Vec<u8>>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        conn.query_row(
            "SELECT system_fields FROM sync_record_state WHERE record_name = ?1",
            params![record_name],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| StoreError::Storage(format!("record state get: {}", e)))
    }

    /// Archive CKRecord system fields for a record.
    pub fn sync_record_state_set(
        &self,
        record_name: &str,
        blob: Vec<u8>,
    ) -> Result<(), StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        conn.execute(
            "INSERT OR REPLACE INTO sync_record_state (record_name, system_fields, updated_at)
             VALUES (?1, ?2, ?3)",
            params![record_name, blob, Utc::now().timestamp_millis()],
        )
        .map_err(|e| StoreError::Storage(format!("record state set: {}", e)))?;
        Ok(())
    }

    /// Drop the archived system fields for a record.
    pub fn sync_record_state_delete(&self, record_name: &str) -> Result<(), StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        conn.execute(
            "DELETE FROM sync_record_state WHERE record_name = ?1",
            params![record_name],
        )
        .map_err(|e| StoreError::Storage(format!("record state delete: {}", e)))?;
        Ok(())
    }

    /// Live queue depths (outbox / deferred refs / tombstones).
    pub fn sync_status_counts(&self) -> Result<SyncCounts, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let count = |sql: &str| -> Result<u32, StoreError> {
            conn.query_row(sql, [], |r| r.get::<_, i64>(0))
                .map(|v| v as u32)
                .map_err(|e| StoreError::Storage(format!("status counts: {}", e)))
        };
        Ok(SyncCounts {
            outbox: count("SELECT COUNT(*) FROM sync_outbox")?,
            pending_refs: count("SELECT COUNT(*) FROM sync_pending_refs")?,
            tombstones: count("SELECT COUNT(*) FROM tombstones")?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- resolve_lww branch coverage -----------------------------------------

    #[test]
    fn lww_greater_clock_wins() {
        assert!(resolve_lww(5, "human", "zed", 6, "system", "abe"));
        assert!(!resolve_lww(6, "system", "abe", 5, "human", "zed"));
    }

    #[test]
    fn lww_clock_tie_kind_precedence() {
        // Human beats Agent beats System.
        assert!(resolve_lww(7, "agent", "same", 7, "human", "same"));
        assert!(!resolve_lww(7, "human", "same", 7, "agent", "same"));
        assert!(resolve_lww(7, "system", "same", 7, "agent", "same"));
        assert!(!resolve_lww(7, "agent", "same", 7, "system", "same"));
        assert!(resolve_lww(7, "system", "same", 7, "human", "same"));
    }

    #[test]
    fn lww_full_kind_tie_author_lexicographic() {
        assert!(resolve_lww(7, "human", "user-a", 7, "human", "user-b"));
        assert!(!resolve_lww(7, "human", "user-b", 7, "human", "user-a"));
    }

    #[test]
    fn lww_identical_never_remote_wins() {
        assert!(!resolve_lww(7, "human", "user-a", 7, "human", "user-a"));
    }

    #[test]
    fn lww_is_antisymmetric_for_distinct_inputs() {
        let cases = [
            ((5u64, "human", "a"), (6u64, "human", "a")),
            ((7, "agent", "a"), (7, "human", "a")),
            ((7, "human", "a"), (7, "human", "b")),
        ];
        for ((lc, lk, la), (rc, rk, ra)) in cases {
            let forward = resolve_lww(lc, lk, la, rc, rk, ra);
            let backward = resolve_lww(rc, rk, ra, lc, lk, la);
            assert_ne!(forward, backward, "antisymmetry violated");
        }
    }

    // -- record-name + content-key helpers -----------------------------------

    #[test]
    fn reference_record_name_shape_and_determinism() {
        let a = sync_reference_record_name("s", "t", "\"Cites\"");
        let b = sync_reference_record_name("s", "t", "\"Cites\"");
        assert_eq!(a, b);
        assert!(a.starts_with("ref_"));
        assert_eq!(a.len(), 4 + 32);
        assert_ne!(a, sync_reference_record_name("s", "t", "\"RelatesTo\""));
    }

    fn record_with(payload: &str, tags: &[&str]) -> SyncItemRecord {
        SyncItemRecord {
            id: "00000000-0000-0000-0000-000000000001".into(),
            schema_ref: "test/paper".into(),
            payload_json: payload.into(),
            logical_clock: 7,
            author_kind: "human".into(),
            author_id: "user-a".into(),
            origin: "o".into(),
            created_ms: 1,
            modified_ms: 2,
            tag_paths: tags.iter().map(|s| s.to_string()).collect(),
            is_read: false,
            is_starred: false,
            flag_color: None,
            flag_style: None,
            flag_length: None,
            priority: "normal".into(),
            parent_id: None,
            envelope_json: "{\"visibility\":\"private\"}".into(),
        }
    }

    #[test]
    fn content_key_is_order_insensitive_for_tags_and_payload_keys() {
        let a = record_with("{\"a\":1,\"b\":2}", &["x", "y"]);
        let b = record_with("{\"b\":2,\"a\":1}", &["y", "x"]);
        assert_eq!(content_key(&a), content_key(&b));
    }

    #[test]
    fn content_key_differs_on_content() {
        let a = record_with("{\"a\":1}", &[]);
        let b = record_with("{\"a\":2}", &[]);
        assert_ne!(content_key(&a), content_key(&b));
        // Full-tie decision is antisymmetric on the differing pair.
        assert_ne!(
            remote_wins_over_local(&a, &b),
            remote_wins_over_local(&b, &a)
        );
        // Identical records: nobody wins (idempotent skip).
        assert!(!remote_wins_over_local(&a, &a.clone()));
    }

    #[test]
    fn envelope_json_round_trip() {
        let fields = EnvelopeFields {
            canonical_id: Some("doi:10.1/x".into()),
            visibility: "shared".into(),
            message_type: None,
            produced_by: Some("agent:enrich".into()),
            version: None,
            batch_id: Some("b1".into()),
        };
        let json = build_envelope_json(&fields);
        let back = parse_envelope_json(&json);
        assert_eq!(back.canonical_id.as_deref(), Some("doi:10.1/x"));
        assert_eq!(back.visibility, "shared");
        assert_eq!(back.message_type, None);
        assert_eq!(back.produced_by.as_deref(), Some("agent:enrich"));
        assert_eq!(back.batch_id.as_deref(), Some("b1"));
        // Missing/garbage envelope falls back to private visibility.
        assert_eq!(parse_envelope_json("").visibility, "private");
        assert_eq!(parse_envelope_json("{}").visibility, "private");
    }
}
