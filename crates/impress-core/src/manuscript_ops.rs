//! Manuscript revision operations (ADR-0011 D45, GUI-meld plan §History).
//!
//! Revision snapshots are the durable, named stratum of manuscript history —
//! immutable point-in-time captures forming a linear chain via
//! `predecessor_revision_ref` / `Supersedes`. The fine-grained stratum is the
//! ordinary operations log (`operations_for`), which for body edits may be
//! compacted; revisions must therefore be creatable *before* any compaction
//! cadence is enabled (see `compact_operations`).
//!
//! This lives in impress-core — next to the store-boundary immutability
//! enforcement in `sqlite_store::apply_operation` — so both FFI surfaces
//! (`impress-store-ffi::SharedStore` and `imbib-core::ImbibStore`) share one
//! implementation instead of drifting.

use std::collections::BTreeMap;

use chrono::{SecondsFormat, Utc};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use crate::operation::{OperationIntent, OperationSpec, OperationType, RetentionTier};
use crate::query::{ItemQuery, Predicate, SortDescriptor};
use crate::reference::{EdgeType, TypedReference};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{ItemStore, StoreError};

/// Prefix marking a payload string as a content-addressed blob reference.
pub const BLOB_REF_PREFIX: &str = "blob:sha256:";

/// SHA-256 hex digest of a UTF-8 string.
pub fn sha256_hex(text: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    hex_encode(&hasher.finalize())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Create an immutable `manuscript-revision` snapshot of a manuscript's
/// current body, link it into the linear revision chain, and advance the
/// manuscript's `current_revision_ref`.
///
/// Snapshot mechanics (Phase-7-era single-file form, per the
/// `source_archive_ref` field doc):
/// - `content_hash` = SHA-256 of the body (reuses `body_content_hash` when
///   present and the body is inline; recomputed otherwise).
/// - `source_archive_ref` = `blob:sha256:<content_hash>`; when the body is
///   inline (not itself a blob ref) the full text is additionally carried in
///   a `source_inline` payload field so the snapshot is self-contained even
///   without a content-addressed store entry. Directory-bundle archives and
///   compiled-PDF artifacts are attached by richer callers via
///   `pdf_artifact_ref` later; this in-store path stores `""` for it.
/// - `Supersedes` edge + `predecessor_revision_ref` link to the prior head.
/// - `IsPartOf` edge points to the manuscript.
///
/// The manuscript's `current_revision_ref` is advanced with an Editorial,
/// Durable operation attributed to `author`.
pub fn create_revision(
    store: &SqliteItemStore,
    manuscript_id: ItemId,
    revision_tag: &str,
    snapshot_reason: &str,
    author: &str,
    author_kind: ActorKind,
) -> Result<Item, StoreError> {
    let manuscript = store
        .get(manuscript_id)?
        .ok_or(StoreError::NotFound(manuscript_id))?;
    if manuscript.schema != "manuscript" {
        return Err(StoreError::Validation(format!(
            "create_revision requires schema 'manuscript', got '{}'",
            manuscript.schema
        )));
    }

    let body = match manuscript.payload.get("body_content") {
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    };
    let body_is_blob_ref = body.starts_with(BLOB_REF_PREFIX);

    let content_hash = match manuscript.payload.get("body_content_hash") {
        Some(Value::String(h)) if !h.is_empty() && !body_is_blob_ref => h.clone(),
        _ if body_is_blob_ref => body
            .strip_prefix(BLOB_REF_PREFIX)
            .unwrap_or_default()
            .to_string(),
        _ => sha256_hex(&body),
    };

    let predecessor = current_head(store, manuscript_id, &manuscript)?;

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert(
        "parent_manuscript_ref".into(),
        Value::String(manuscript_id.to_string()),
    );
    payload.insert(
        "revision_tag".into(),
        Value::String(revision_tag.to_string()),
    );
    payload.insert("content_hash".into(), Value::String(content_hash.clone()));
    payload.insert("pdf_artifact_ref".into(), Value::String(String::new()));
    payload.insert(
        "source_archive_ref".into(),
        Value::String(format!("{}{}", BLOB_REF_PREFIX, content_hash)),
    );
    payload.insert(
        "snapshot_reason".into(),
        Value::String(snapshot_reason.to_string()),
    );
    if !body_is_blob_ref {
        payload.insert(
            "word_count".into(),
            Value::Int(body.split_whitespace().count() as i64),
        );
        payload.insert("source_inline".into(), Value::String(body));
    }
    if let Some(pred) = &predecessor {
        payload.insert(
            "predecessor_revision_ref".into(),
            Value::String(pred.to_string()),
        );
    }

    let mut references = vec![TypedReference {
        target: manuscript_id,
        edge_type: EdgeType::IsPartOf,
        metadata: None,
    }];
    if let Some(pred) = predecessor {
        references.push(TypedReference {
            target: pred,
            edge_type: EdgeType::Supersedes,
            metadata: None,
        });
    }

    let now = Utc::now();
    let revision = Item {
        id: Uuid::new_v4(),
        schema: "manuscript-revision".into(),
        payload,
        created: now,
        modified: now,
        author: author.to_string(),
        author_kind,
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
        references,
        parent: Some(manuscript_id),
    };

    store.insert(revision.clone())?;

    // Advance the manuscript's head pointer as an attributed, durable edit.
    store.apply_operation(OperationSpec {
        target_id: manuscript_id,
        op_type: OperationType::SetPayload(
            "current_revision_ref".into(),
            Value::String(revision.id.to_string()),
        ),
        intent: OperationIntent::Editorial,
        reason: Some(format!("revision '{}'", revision_tag)),
        batch_id: None,
        author: author.to_string(),
        author_kind,
        retention: RetentionTier::Durable,
    })?;

    Ok(revision)
}

/// List all revisions of a manuscript, newest first.
pub fn list_revisions(
    store: &SqliteItemStore,
    manuscript_id: ItemId,
) -> Result<Vec<Item>, StoreError> {
    let q = ItemQuery {
        schema: Some("manuscript-revision".into()),
        predicates: vec![Predicate::Eq(
            "parent_manuscript_ref".into(),
            Value::String(manuscript_id.to_string()),
        )],
        sort: vec![SortDescriptor {
            field: "created".into(),
            ascending: false,
        }],
        ..Default::default()
    };
    store.query(&q)
}

/// Resolve the current revision head: prefer a valid `current_revision_ref`
/// that points at an actual revision item; otherwise fall back to the newest
/// revision by creation time. Returns None for a manuscript with no revisions
/// (the freshly-created self-ref case).
fn current_head(
    store: &SqliteItemStore,
    manuscript_id: ItemId,
    manuscript: &Item,
) -> Result<Option<ItemId>, StoreError> {
    if let Some(Value::String(head)) = manuscript.payload.get("current_revision_ref") {
        if let Ok(head_id) = head.parse::<ItemId>() {
            if head_id != manuscript_id {
                if let Some(item) = store.get(head_id)? {
                    if item.schema == "manuscript-revision" {
                        return Ok(Some(head_id));
                    }
                }
            }
        }
    }
    let revisions = list_revisions(store, manuscript_id)?;
    Ok(revisions.first().map(|r| r.id))
}

/// ISO 8601 timestamp (seconds precision, Z suffix) matching Swift's
/// `ISO8601DateFormatter` output, for `body_modified_at` writes.
pub fn iso8601_now() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_manuscript(store: &SqliteItemStore, body: &str) -> ItemId {
        let id = Uuid::new_v4();
        let mut payload: BTreeMap<String, Value> = BTreeMap::new();
        payload.insert("title".into(), Value::String("Test Paper".into()));
        payload.insert("status".into(), Value::String("draft".into()));
        payload.insert(
            "current_revision_ref".into(),
            Value::String(id.to_string()), // self-ref until first revision
        );
        payload.insert("format".into(), Value::String("typst".into()));
        payload.insert("body_content".into(), Value::String(body.into()));
        payload.insert(
            "body_content_hash".into(),
            Value::String(sha256_hex(body)),
        );
        let now = Utc::now();
        let item = Item {
            id,
            schema: "manuscript".into(),
            payload,
            created: now,
            modified: now,
            author: "test".into(),
            author_kind: ActorKind::Human,
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
        store.insert(item).unwrap();
        id
    }

    #[test]
    fn create_revision_snapshots_body_and_advances_head() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let ms = make_manuscript(&store, "= Introduction\nHello world");

        let rev = create_revision(&store, ms, "v1", "manual", "user:tom", ActorKind::Human)
            .expect("create revision");

        assert_eq!(rev.schema, "manuscript-revision");
        assert_eq!(
            rev.payload.get("parent_manuscript_ref"),
            Some(&Value::String(ms.to_string()))
        );
        assert_eq!(
            rev.payload.get("source_inline"),
            Some(&Value::String("= Introduction\nHello world".into()))
        );
        assert_eq!(rev.payload.get("word_count"), Some(&Value::Int(4)));
        assert!(rev
            .payload
            .get("predecessor_revision_ref")
            .is_none());

        // Head advanced
        let ms_item = store.get(ms).unwrap().unwrap();
        assert_eq!(
            ms_item.payload.get("current_revision_ref"),
            Some(&Value::String(rev.id.to_string()))
        );
    }

    #[test]
    fn second_revision_links_predecessor_chain() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let ms = make_manuscript(&store, "draft one");
        let r1 = create_revision(&store, ms, "v1", "manual", "u", ActorKind::Human).unwrap();
        let r2 = create_revision(&store, ms, "v2", "user-tag", "u", ActorKind::Human).unwrap();

        assert_eq!(
            r2.payload.get("predecessor_revision_ref"),
            Some(&Value::String(r1.id.to_string()))
        );
        assert!(r2
            .references
            .iter()
            .any(|r| r.edge_type == EdgeType::Supersedes && r.target == r1.id));

        let revs = list_revisions(&store, ms).unwrap();
        assert_eq!(revs.len(), 2);
        assert_eq!(revs[0].id, r2.id, "newest first");
    }

    #[test]
    fn revision_is_immutable_after_creation() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let ms = make_manuscript(&store, "body");
        let rev = create_revision(&store, ms, "v1", "manual", "u", ActorKind::Human).unwrap();

        let err = store.apply_operation(OperationSpec {
            target_id: rev.id,
            op_type: OperationType::SetPayload(
                "revision_tag".into(),
                Value::String("tampered".into()),
            ),
            intent: OperationIntent::Routine,
            reason: None,
            batch_id: None,
            author: "u".into(),
            author_kind: ActorKind::Human,
            retention: RetentionTier::Durable,
        });
        assert!(err.is_err(), "revision payload mutation must be rejected");
    }

    #[test]
    fn create_revision_rejects_non_manuscript() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let ms = make_manuscript(&store, "body");
        let rev = create_revision(&store, ms, "v1", "manual", "u", ActorKind::Human).unwrap();
        let err = create_revision(&store, rev.id, "v2", "manual", "u", ActorKind::Human);
        assert!(matches!(err, Err(StoreError::Validation(_))));
    }

    /// Regression: `effective_state` time-travel must revert payload fields
    /// edited AFTER the cutoff. The forward replay starts from the CURRENT
    /// materialized payload, so without the reverse un-apply pass a field's
    /// post-cutoff value leaked into "past" states (found by the GUI-meld
    /// Phase 0 history tests).
    #[test]
    fn effective_state_reverts_post_cutoff_payload_edits() {
        use crate::operation::StateAsOf;
        use crate::store::FieldMutation;

        let store = SqliteItemStore::open_in_memory().unwrap();
        let ms = make_manuscript(&store, "v1");

        store
            .update(
                ms,
                vec![FieldMutation::SetPayload(
                    "body_content".into(),
                    Value::String("v2".into()),
                )],
            )
            .unwrap();
        let clock_after_body = store
            .operations_for(ms, None)
            .unwrap()
            .last()
            .expect("body op recorded")
            .logical_clock;
        store
            .update(
                ms,
                vec![FieldMutation::SetPayload(
                    "title".into(),
                    Value::String("Renamed".into()),
                )],
            )
            .unwrap();

        // As of the body edit: body is v2, but title must still be the original.
        let past = store
            .effective_state(ms, StateAsOf::LogicalClock(clock_after_body))
            .unwrap()
            .expect("state exists");
        assert_eq!(
            past.payload.get("body_content"),
            Some(&Value::String("v2".into()))
        );
        assert_eq!(
            past.payload.get("title"),
            Some(&Value::String("Test Paper".into())),
            "post-cutoff title edit must be reverted"
        );

        // Before everything (clock 0): body must be v1 and a field created
        // later must be absent.
        store
            .update(
                ms,
                vec![FieldMutation::SetPayload(
                    "journal_target".into(),
                    Value::String("ApJ".into()),
                )],
            )
            .unwrap();
        let origin = store
            .effective_state(ms, StateAsOf::LogicalClock(0))
            .unwrap()
            .expect("state exists");
        assert_eq!(
            origin.payload.get("body_content"),
            Some(&Value::String("v1".into()))
        );
        assert!(
            origin.payload.get("journal_target").is_none(),
            "field created after cutoff must not exist in past state"
        );

        // Current state is untouched by time travel.
        let current = store
            .effective_state(ms, StateAsOf::Current)
            .unwrap()
            .unwrap();
        assert_eq!(
            current.payload.get("title"),
            Some(&Value::String("Renamed".into()))
        );
    }

    #[test]
    fn blob_ref_body_snapshots_without_inline_copy() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let id = make_manuscript(&store, "placeholder");
        // Simulate the >1MB escape hatch: body is a blob ref.
        store
            .update(
                id,
                vec![crate::store::FieldMutation::SetPayload(
                    "body_content".into(),
                    Value::String(format!("{}abc123", BLOB_REF_PREFIX)),
                )],
            )
            .unwrap();

        let rev = create_revision(&store, id, "v1", "manual", "u", ActorKind::Human).unwrap();
        assert!(rev.payload.get("source_inline").is_none());
        assert_eq!(
            rev.payload.get("content_hash"),
            Some(&Value::String("abc123".into()))
        );
    }
}
