//! Automerge-backed manuscript bodies (ADR-0027).
//!
//! The document is the truth; `body_content` on the `manuscript` payload is a
//! materialization rewritten on every commit (D2). Persistence and sync unit:
//! immutable `manuscript-change@1.0.0` chunk items, one per commit, loaded by
//! set-union in any order (D3). Changes that are DERIVED from materialized
//! text rather than typed — genesis and recovery — are byte-identical
//! wherever they are computed, so two replicas can never enter the same edit
//! twice (D4).
//!
//! Lock order: `SqliteItemStore::collab_docs` is taken only here, and never
//! while the writer connection is held — every store call made from inside
//! this module happens with the doc cache lock released.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::str::FromStr;

use automerge::transaction::{CommitOptions, Transactable};
use automerge::{ActorId as AmActorId, AutoCommit, ChangeHash, ObjId, ObjType, ReadDoc, ROOT};
use base64::Engine;
use chrono::Utc;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::item::{Item, ItemId, Priority, Value, Visibility};
use crate::query::ItemQuery;
#[cfg(test)]
use crate::query::Predicate;
use crate::schemas::MANUSCRIPT_CHANGE_SCHEMA_REF;
use crate::sqlite_store::SqliteItemStore;
use crate::store::FieldMutation;
use crate::store::{ItemStore, StoreError};

/// The Automerge key under ROOT holding the body text.
const BODY_KEY: &str = "body";

/// One loaded manuscript document plus the chunk items already folded in.
pub struct CollabDoc {
    doc: AutoCommit,
    /// The body Text object, resolved after genesis/loading. `None` only for
    /// a doc that has not been touched yet.
    body: Option<ObjId>,
    applied_chunks: HashSet<ItemId>,
    /// `recovers_hash` of every applied recovery chunk (D4 guard), kept here
    /// so the hot path never re-reads chunk payloads it already folded in.
    recovered_hashes: HashSet<String>,
}

impl CollabDoc {
    /// A doc with NO local operations. It must not create the body object
    /// itself: a local `put_object` would be a change of its own — a second,
    /// concurrent body Text with a random actor — and every replica that
    /// started that way would diverge from genesis (different object,
    /// different heads). Genesis creates the body; loading finds it.
    fn empty() -> Self {
        Self {
            doc: AutoCommit::new(),
            body: None,
            applied_chunks: HashSet::new(),
            recovered_hashes: HashSet::new(),
        }
    }

    /// The body Text object — created deterministically ONLY by genesis (so
    /// its object id is the same on every replica); after loading chunks it
    /// is looked up, never created.
    fn ensure_body(doc: &mut AutoCommit) -> Result<ObjId, StoreError> {
        if let Some((_, id)) = doc.get(ROOT, BODY_KEY).map_err(collab_err)? {
            return Ok(id);
        }
        doc.put_object(ROOT, BODY_KEY, ObjType::Text)
            .map_err(collab_err)
    }

    fn body_id(&mut self) -> Result<ObjId, StoreError> {
        if let Some(id) = &self.body {
            return Ok(id.clone());
        }
        let id = Self::ensure_body(&mut self.doc)?;
        self.body = Some(id.clone());
        Ok(id)
    }

    fn text(&mut self) -> Result<String, StoreError> {
        let body = self.body_id()?;
        self.doc.text(&body).map_err(collab_err)
    }

    fn heads_hex(&mut self) -> Vec<String> {
        self.doc.get_heads().iter().map(|h| h.to_string()).collect()
    }
}

/// What a commit returns to the editor: the heads to pin as the next base,
/// and the MERGED text (which differs from what was sent whenever another
/// writer's edits were folded in).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommitOutcome {
    pub heads: Vec<String>,
    pub body: String,
    pub body_hash: String,
    /// True when the returned body differs from the text the caller sent —
    /// concurrent edits were merged and the editor buffer must adopt them.
    pub merged_external: bool,
}

/// One entry of a manuscript's change history (per Automerge change).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChangeSummary {
    pub hash: String,
    pub actor: String,
    /// Automerge change time in SECONDS since the epoch (0 for the
    /// deterministic derived changes).
    pub time: i64,
    pub message: Option<String>,
    pub deps: Vec<String>,
}

fn collab_err(e: impl std::fmt::Display) -> StoreError {
    StoreError::Storage(format!("collab: {}", e))
}

fn parse_heads(hex: &[String]) -> Vec<ChangeHash> {
    hex.iter()
        .filter_map(|h| ChangeHash::from_str(h).ok())
        .collect()
}

/// A stable actor id derived from its inputs — the D4 idempotency rule.
fn derived_actor(tag: &str, parts: &[&str]) -> AmActorId {
    let mut hasher = Sha256::new();
    hasher.update(tag.as_bytes());
    for part in parts {
        hasher.update(b"|");
        hasher.update(part.as_bytes());
    }
    let digest = hasher.finalize();
    AmActorId::from(&digest[..16])
}

fn payload_string(item: &Item, key: &str) -> Option<String> {
    match item.payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

impl SqliteItemStore {
    /// Every chunk item for `manuscript` WITH payloads, oldest first. Test
    /// support (replica shipping, counts); the hot path reads ids only via
    /// `manuscript_chunk_ids` and compaction reads all kinds' chunks at once.
    #[cfg(test)]
    fn manuscript_chunks(&self, manuscript: ItemId) -> Result<Vec<Item>, StoreError> {
        let q = ItemQuery {
            schema: Some(MANUSCRIPT_CHANGE_SCHEMA_REF.into()),
            predicates: vec![Predicate::HasParent(manuscript)],
            sort: vec![],
            limit: None,
            offset: None,
            include_tags: false,
            include_references: false,
        };
        let mut chunks = self.query(&q)?;
        chunks.sort_by_key(|c| c.created);
        Ok(chunks)
    }

    /// The chunk ids for `manuscript`, oldest first — the hot-path shape.
    /// A 2 MB manuscript's genesis chunk is a ~2.7 MB payload; re-parsing it
    /// on every commit (as `manuscript_chunks` would) is most of a second.
    /// Only chunks not yet applied are fetched with their payloads.
    fn manuscript_chunk_ids(&self, manuscript: ItemId) -> Result<Vec<ItemId>, StoreError> {
        let rows = self.query_raw(
            "SELECT id FROM items WHERE schema_ref = ?1 AND parent_id = ?2 ORDER BY created ASC",
            &[&MANUSCRIPT_CHANGE_SCHEMA_REF, &manuscript.to_string()],
            |row| row.get::<_, String>(0),
        )?;
        Ok(rows.iter().filter_map(|id| id.parse().ok()).collect())
    }

    fn manuscript_item(&self, manuscript: ItemId) -> Result<Item, StoreError> {
        let item = self
            .get(manuscript)?
            .ok_or(StoreError::NotFound(manuscript))?;
        if item.schema != "manuscript" {
            return Err(StoreError::Validation(format!(
                "collab verbs require schema 'manuscript', got '{}'",
                item.schema
            )));
        }
        Ok(item)
    }

    /// Persist raw Automerge bytes as one immutable chunk item.
    fn write_chunk(
        &self,
        manuscript: ItemId,
        kind: &str,
        bytes: &[u8],
        heads: &[String],
        actor: &str,
        recovers_hash: Option<&str>,
    ) -> Result<ItemId, StoreError> {
        let mut payload = BTreeMap::new();
        if let Some(h) = recovers_hash {
            payload.insert("recovers_hash".into(), Value::String(h.into()));
        }
        payload.insert(
            "parent_manuscript_ref".into(),
            Value::String(manuscript.to_string()),
        );
        payload.insert("kind".into(), Value::String(kind.into()));
        payload.insert(
            "heads".into(),
            Value::Array(heads.iter().cloned().map(Value::String).collect()),
        );
        payload.insert(
            "bytes_b64".into(),
            Value::String(base64::engine::general_purpose::STANDARD.encode(bytes)),
        );
        payload.insert("byte_length".into(), Value::Int(bytes.len() as i64));
        payload.insert("actor".into(), Value::String(actor.into()));
        let now = Utc::now();
        let item = Item {
            id: Uuid::new_v4(),
            schema: MANUSCRIPT_CHANGE_SCHEMA_REF.into(),
            payload,
            created: now,
            modified: now,
            author: self.default_author.clone(),
            author_kind: self.default_author_kind,
            logical_clock: 0,
            origin: Some(self.origin_id.clone()),
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: true,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: Some(manuscript),
        };
        self.insert(item)
    }

    /// Fold every chunk not yet applied into `doc`, fetching payloads only for
    /// the unseen ids. Returns how many were new.
    fn apply_unseen_chunks(
        &self,
        doc: &mut CollabDoc,
        chunk_ids: &[ItemId],
    ) -> Result<usize, StoreError> {
        let mut applied = 0;
        for id in chunk_ids {
            if doc.applied_chunks.contains(id) {
                continue;
            }
            let Some(chunk) = self.get(*id)? else {
                continue; // deleted between the index read and now (compaction)
            };
            let b64 = payload_string(&chunk, "bytes_b64").unwrap_or_default();
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(b64.as_bytes())
                .map_err(collab_err)?;
            // Both kinds load incrementally: a `save()` is itself a valid
            // change stream, and duplicates de-duplicate by change hash.
            doc.doc.load_incremental(&bytes).map_err(collab_err)?;
            if let Some(h) = payload_string(&chunk, "recovers_hash") {
                doc.recovered_hashes.insert(h);
            }
            doc.applied_chunks.insert(*id);
            applied += 1;
        }
        if applied > 0 {
            doc.body = None;
            doc.body_id()?;
        }
        Ok(applied)
    }

    /// The deterministic GENESIS change (D4): actor from (manuscript, body
    /// hash), time 0, fixed message, `update_text` from empty. Every replica
    /// that migrates the same manuscript from the same body produces the same
    /// change hash.
    fn genesis(
        &self,
        manuscript: ItemId,
        body_text: &str,
        body_hash: &str,
    ) -> Result<CollabDoc, StoreError> {
        let mut doc = AutoCommit::new().with_actor(derived_actor(
            "genesis",
            &[&manuscript.to_string(), body_hash],
        ));
        let body = doc
            .put_object(ROOT, BODY_KEY, ObjType::Text)
            .map_err(collab_err)?;
        doc.update_text(&body, body_text).map_err(collab_err)?;
        doc.commit_with(
            CommitOptions::default()
                .with_message("genesis")
                .with_time(0),
        );
        let bytes = doc.save();
        let mut collab = CollabDoc {
            doc,
            body: Some(body),
            applied_chunks: HashSet::new(),
            recovered_hashes: HashSet::new(),
        };
        let heads = collab.heads_hex();
        let id = self.write_chunk(manuscript, "change", &bytes, &heads, "genesis", None)?;
        collab.applied_chunks.insert(id);
        Ok(collab)
    }

    /// Reconcile the document with the manuscript row (D2 + D4). Returns the
    /// document's text afterwards (callers reuse it rather than materialize
    /// a multi-MB body again).
    ///
    /// `collab_materialized_hash` is what THIS layer last wrote as
    /// `body_content_hash`. While the two agree, the document is authoritative
    /// and a text difference means the document moved (chunks arrived from
    /// another replica) — the row is re-materialized. When they disagree, a
    /// non-collab writer moved `body_content` (an old build, a watched-folder
    /// re-read): fold the difference in as the deterministic RECOVERY change —
    /// actor derived from (manuscript, current heads, body hash), time 0 —
    /// unless a chunk that already recovers this exact body hash is applied
    /// (a sibling got there first), in which case the merged text wins.
    fn reconcile(
        &self,
        manuscript: ItemId,
        doc: &mut CollabDoc,
        item: &Item,
        body_text: &str,
        body_hash: &str,
        materialized_hash: Option<&str>,
    ) -> Result<String, StoreError> {
        let doc_text = doc.text()?;
        if doc_text == body_text {
            return Ok(doc_text);
        }
        let row_is_collab_owned = materialized_hash == Some(body_hash);
        let already_recovered = doc.recovered_hashes.contains(body_hash);
        if row_is_collab_owned || already_recovered {
            let hash = crate::manuscript_ops::sha256_hex(&doc_text);
            self.materialize_body(manuscript, item, &doc_text, &hash)?;
            return Ok(doc_text);
        }

        let heads = doc.doc.get_heads();
        let heads_hex: Vec<String> = heads.iter().map(|h| h.to_string()).collect();
        let actor = derived_actor(
            "recovery",
            &[&manuscript.to_string(), &heads_hex.join(","), body_hash],
        );
        let mut fork = doc.doc.fork_at(&heads).map_err(collab_err)?;
        fork.set_actor(actor);
        let body_obj = CollabDoc::ensure_body(&mut fork)?;
        fork.update_text(&body_obj, body_text).map_err(collab_err)?;
        fork.commit_with(
            CommitOptions::default()
                .with_message("recovery")
                .with_time(0),
        );
        doc.doc.merge(&mut fork).map_err(collab_err)?;
        let new_changes = doc.doc.get_changes(&heads);
        let bytes: Vec<u8> = new_changes
            .iter()
            .flat_map(|c| c.raw_bytes().to_vec())
            .collect();
        let after = doc.heads_hex();
        let id = self.write_chunk(
            manuscript,
            "change",
            &bytes,
            &after,
            "recovery",
            Some(body_hash),
        )?;
        doc.applied_chunks.insert(id);
        doc.recovered_hashes.insert(body_hash.to_string());
        // The recovered text is now the document's; pin the row as collab-owned.
        let merged = doc.text()?;
        let hash = crate::manuscript_ops::sha256_hex(&merged);
        self.materialize_body(manuscript, item, &merged, &hash)?;
        Ok(merged)
    }

    /// Bring the cached document for `manuscript` up to date with the store:
    /// load (or genesis) it, fold unseen chunks, reconcile with the
    /// materialized body. Runs `f` on the ready document with its current
    /// text and the manuscript row. The whole per-manuscript sequence runs
    /// under one cache lock, which is the in-process serialization the commit
    /// contract needs.
    fn with_manuscript_doc<T>(
        &self,
        manuscript: ItemId,
        f: impl FnOnce(&Self, &mut CollabDoc, &Item, String) -> Result<T, StoreError>,
    ) -> Result<T, StoreError> {
        let item = self.manuscript_item(manuscript)?;
        let body_text = payload_string(&item, "body_content").unwrap_or_default();
        let body_hash = payload_string(&item, "body_content_hash")
            .unwrap_or_else(|| crate::manuscript_ops::sha256_hex(&body_text));
        let materialized_hash = payload_string(&item, "collab_materialized_hash");
        let chunk_ids = self.manuscript_chunk_ids(manuscript)?;

        let mut cache = self
            .collab_docs
            .lock()
            .map_err(|e| StoreError::Storage(format!("collab cache lock: {}", e)))?;
        let doc = cache.entry(manuscript).or_insert_with(CollabDoc::empty);

        let current_text = if chunk_ids.is_empty() && doc.applied_chunks.is_empty() {
            // First touch anywhere: genesis from the materialized body, and
            // the row becomes collab-owned (marker == body hash).
            *doc = self.genesis(manuscript, &body_text, &body_hash)?;
            self.materialize_body(manuscript, &item, &body_text, &body_hash)?;
            body_text
        } else {
            self.apply_unseen_chunks(doc, &chunk_ids)?;
            self.reconcile(
                manuscript,
                doc,
                &item,
                &body_text,
                &body_hash,
                materialized_hash.as_deref(),
            )?
        };
        f(self, doc, &item, current_text)
    }

    /// The commit verb (ADR-0027 D6). `base_heads` are the heads the caller
    /// last saw (from a previous outcome or `manuscript_collab_heads`); the
    /// caller's text is diffed against the document AT THAT BASE and merged,
    /// so a stale caller's edits land as concurrent ops beside anyone else's
    /// instead of overwriting them. Empty/unknown base = diff against current.
    pub fn commit_manuscript_body(
        &self,
        manuscript: ItemId,
        base_heads: &[String],
        text: &str,
        author: &str,
    ) -> Result<CommitOutcome, StoreError> {
        self.with_manuscript_doc(manuscript, |store, doc, item, current_text| {
            let current_heads = doc.doc.get_heads();
            let requested = parse_heads(base_heads);
            // A base is usable only if every hash is known to this document;
            // otherwise fall back to the current heads (unknown base).
            let base_is_current = requested.is_empty()
                || requested.len() == current_heads.len()
                    && requested.iter().all(|h| current_heads.contains(h));
            let base: Vec<ChangeHash> = if !base_is_current
                && requested
                    .iter()
                    .all(|h| doc.doc.get_change_by_hash(h).is_some())
            {
                requested
            } else {
                current_heads.clone()
            };
            let at_current = base == current_heads;

            let mut merged: Option<String> = None;
            if at_current {
                // Fast path — the editor is up to date, so the diff is against
                // the live document: no fork (a fork re-materializes the whole
                // document, which for a multi-MB body is most of a second).
                if current_text != text {
                    doc.doc.set_actor(AmActorId::random());
                    let body_obj = doc.body_id()?;
                    doc.doc.update_text(&body_obj, text).map_err(collab_err)?;
                    doc.doc.commit_with(
                        CommitOptions::default()
                            .with_message(author.to_string())
                            .with_time(Utc::now().timestamp()),
                    );
                    merged = Some(text.to_string());
                }
            } else {
                let mut fork = doc.doc.fork_at(&base).map_err(collab_err)?;
                fork.set_actor(AmActorId::random());
                let body_obj = CollabDoc::ensure_body(&mut fork)?;
                if fork.text(&body_obj).map_err(collab_err)? != text {
                    fork.update_text(&body_obj, text).map_err(collab_err)?;
                    fork.commit_with(
                        CommitOptions::default()
                            .with_message(author.to_string())
                            .with_time(Utc::now().timestamp()),
                    );
                    doc.doc.merge(&mut fork).map_err(collab_err)?;
                    merged = Some(doc.text()?);
                }
            }

            let new_changes = doc.doc.get_changes(&current_heads);
            if !new_changes.is_empty() {
                let bytes: Vec<u8> = new_changes
                    .iter()
                    .flat_map(|c| c.raw_bytes().to_vec())
                    .collect();
                let actor_hex = new_changes
                    .first()
                    .map(|c| c.actor_id().to_hex_string())
                    .unwrap_or_default();
                let after = doc.heads_hex();
                let id =
                    store.write_chunk(manuscript, "change", &bytes, &after, &actor_hex, None)?;
                doc.applied_chunks.insert(id);
            }

            let merged = merged.unwrap_or(current_text);
            let merged_hash = crate::manuscript_ops::sha256_hex(&merged);
            store.materialize_body(manuscript, item, &merged, &merged_hash)?;
            Ok(CommitOutcome {
                heads: doc.heads_hex(),
                merged_external: merged != text,
                body: merged,
                body_hash: merged_hash,
            })
        })
    }

    /// Rewrite the manuscript's derived body fields (D2). No-op when the
    /// stored body already matches (the store's no-op filter also guards
    /// this, but skipping the update avoids even the read).
    fn materialize_body(
        &self,
        manuscript: ItemId,
        item: &Item,
        body: &str,
        body_hash: &str,
    ) -> Result<(), StoreError> {
        if payload_string(item, "body_content_hash").as_deref() == Some(body_hash)
            && payload_string(item, "collab_materialized_hash").as_deref() == Some(body_hash)
            && payload_string(item, "body_content").as_deref() == Some(body)
        {
            return Ok(());
        }
        self.update(
            manuscript,
            vec![
                FieldMutation::SetPayload("body_content".into(), Value::String(body.into())),
                FieldMutation::SetPayload(
                    "body_content_hash".into(),
                    Value::String(body_hash.into()),
                ),
                // The D2/D4 ownership marker: while this equals
                // `body_content_hash`, the row was last written by this layer.
                FieldMutation::SetPayload(
                    "collab_materialized_hash".into(),
                    Value::String(body_hash.into()),
                ),
                FieldMutation::SetPayload(
                    "body_modified_at".into(),
                    Value::String(crate::manuscript_ops::iso8601_now()),
                ),
            ],
        )
    }

    /// The document's current heads (loading/genesis-ing it if needed) — what
    /// an editor pins as its first base.
    pub fn manuscript_collab_heads(&self, manuscript: ItemId) -> Result<Vec<String>, StoreError> {
        self.with_manuscript_doc(manuscript, |_, doc, _, _| Ok(doc.heads_hex()))
    }

    /// Per-change history, oldest first.
    pub fn manuscript_change_history(
        &self,
        manuscript: ItemId,
    ) -> Result<Vec<ChangeSummary>, StoreError> {
        self.with_manuscript_doc(manuscript, |_, doc, _, _| {
            Ok(doc
                .doc
                .get_changes(&[])
                .iter()
                .map(|c| ChangeSummary {
                    hash: c.hash().to_string(),
                    actor: c.actor_id().to_hex_string(),
                    time: c.timestamp(),
                    message: c.message().map(|m| m.to_string()),
                    deps: c.deps().iter().map(|d| d.to_string()).collect(),
                })
                .collect())
        })
    }

    /// The body as of `heads` (time travel). Unknown heads → error.
    pub fn manuscript_text_at(
        &self,
        manuscript: ItemId,
        heads: &[String],
    ) -> Result<String, StoreError> {
        self.with_manuscript_doc(manuscript, |_, doc, _, _| {
            let parsed = parse_heads(heads);
            if parsed.len() != heads.len() {
                return Err(StoreError::Validation("unparseable change hash".into()));
            }
            let body = doc.body_id()?;
            doc.doc.text_at(&body, &parsed).map_err(collab_err)
        })
    }

    /// Compaction (D5): for every manuscript with at least `min_chunks` chunk
    /// items, write ONE snapshot chunk holding the full document and delete
    /// the chunks it covers. Also sweeps chunks whose manuscript is gone.
    /// Returns the number of chunk items removed.
    pub fn compact_manuscript_changes(&self, min_chunks: usize) -> Result<usize, StoreError> {
        let q = ItemQuery {
            schema: Some(MANUSCRIPT_CHANGE_SCHEMA_REF.into()),
            predicates: vec![],
            sort: vec![],
            limit: None,
            offset: None,
            include_tags: false,
            include_references: false,
        };
        let all = self.query(&q)?;
        let mut by_manuscript: HashMap<Option<ItemId>, Vec<Item>> = HashMap::new();
        for chunk in all {
            by_manuscript.entry(chunk.parent).or_default().push(chunk);
        }

        let mut removed = 0;
        for (parent, chunks) in by_manuscript {
            let Some(manuscript) = parent else {
                // Orphans: their manuscript was deleted (FK set parent NULL).
                for chunk in &chunks {
                    self.delete(chunk.id)?;
                    removed += 1;
                }
                continue;
            };
            if chunks.len() < min_chunks.max(2) {
                continue;
            }
            if self.get(manuscript)?.is_none() {
                for chunk in &chunks {
                    self.delete(chunk.id)?;
                    removed += 1;
                }
                continue;
            }
            // Snapshot covers exactly the chunks we already hold; anything a
            // sibling writes meanwhile is a newer row we don't touch.
            let covered: Vec<ItemId> = chunks.iter().map(|c| c.id).collect();
            let (bytes, heads) = self.with_manuscript_doc(manuscript, |_, doc, _, _| {
                Ok((doc.doc.save(), doc.heads_hex()))
            })?;
            let snapshot =
                self.write_chunk(manuscript, "snapshot", &bytes, &heads, "snapshot", None)?;
            {
                let mut cache = self
                    .collab_docs
                    .lock()
                    .map_err(|e| StoreError::Storage(format!("collab cache lock: {}", e)))?;
                if let Some(doc) = cache.get_mut(&manuscript) {
                    doc.applied_chunks.insert(snapshot);
                    for id in &covered {
                        doc.applied_chunks.remove(id);
                    }
                }
            }
            for id in covered {
                self.delete(id)?;
                removed += 1;
            }
        }
        Ok(removed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::ActorKind;

    fn store() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().unwrap()
    }

    fn manuscript(store: &SqliteItemStore, body: &str) -> ItemId {
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String("Paper".into()));
        payload.insert("body_content".into(), Value::String(body.into()));
        payload.insert(
            "body_content_hash".into(),
            Value::String(crate::manuscript_ops::sha256_hex(body)),
        );
        payload.insert("format".into(), Value::String("typst".into()));
        let now = Utc::now();
        let item = Item {
            id: Uuid::new_v4(),
            schema: "manuscript".into(),
            payload,
            created: now,
            modified: now,
            author: "user:test".into(),
            author_kind: ActorKind::Human,
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
            references: vec![],
            parent: None,
        };
        store.insert(item).unwrap()
    }

    fn body_of(store: &SqliteItemStore, id: ItemId) -> String {
        payload_string(&store.get(id).unwrap().unwrap(), "body_content").unwrap()
    }

    fn chunk_count(store: &SqliteItemStore, id: ItemId) -> usize {
        store.manuscript_chunks(id).unwrap().len()
    }

    /// Copy every chunk row from `from` to `to` (the sync engine's job,
    /// simulated), in the given order.
    fn ship_chunks(from: &SqliteItemStore, to: &SqliteItemStore, id: ItemId, reverse: bool) {
        let mut chunks = from.manuscript_chunks(id).unwrap();
        if reverse {
            chunks.reverse();
        }
        for chunk in chunks {
            if to.get(chunk.id).unwrap().is_none() {
                to.insert(chunk).unwrap();
            }
        }
    }

    #[test]
    fn genesis_is_deterministic_across_replicas() {
        let a = store();
        let b = store();
        let id = manuscript(&a, "Hello, world.");
        // Same manuscript row on both replicas (as sync would deliver it).
        b.insert(a.get(id).unwrap().unwrap()).unwrap();

        let ha = a.manuscript_collab_heads(id).unwrap();
        let hb = b.manuscript_collab_heads(id).unwrap();
        assert_eq!(ha, hb, "genesis must hash identically on every replica");
        assert_eq!(chunk_count(&a, id), 1);
    }

    #[test]
    fn commit_materializes_and_pins_heads() {
        let s = store();
        let id = manuscript(&s, "abc");
        let heads = s.manuscript_collab_heads(id).unwrap();
        let out = s
            .commit_manuscript_body(id, &heads, "abcd", "user:test")
            .unwrap();
        assert!(!out.merged_external);
        assert_eq!(out.body, "abcd");
        assert_eq!(body_of(&s, id), "abcd");
        assert_ne!(out.heads, heads);
        // genesis + one commit
        assert_eq!(chunk_count(&s, id), 2);
    }

    #[test]
    fn stale_base_merges_instead_of_overwriting() {
        let s = store();
        let id = manuscript(&s, "The quick brown fox.");
        let base = s.manuscript_collab_heads(id).unwrap();

        // Writer A (from base) prepends; writer B (from the SAME stale base)
        // appends. Under CAS one of them would 409; here both land.
        let a = s
            .commit_manuscript_body(id, &base, "Note: The quick brown fox.", "A")
            .unwrap();
        assert!(!a.merged_external);
        let b = s
            .commit_manuscript_body(id, &base, "The quick brown fox. Jumps.", "B")
            .unwrap();
        assert!(b.merged_external, "B must learn about A's edit");
        assert_eq!(b.body, "Note: The quick brown fox. Jumps.");
        assert_eq!(body_of(&s, id), "Note: The quick brown fox. Jumps.");
    }

    #[test]
    fn replicas_converge_regardless_of_chunk_order_and_duplicates() {
        let a = store();
        let b = store();
        let id = manuscript(&a, "one two three");
        b.insert(a.get(id).unwrap().unwrap()).unwrap();

        let ha = a.manuscript_collab_heads(id).unwrap();
        let hb = b.manuscript_collab_heads(id).unwrap();
        a.commit_manuscript_body(id, &ha, "ZERO one two three", "a")
            .unwrap();
        b.commit_manuscript_body(id, &hb, "one two three FOUR", "b")
            .unwrap();
        let ha2 = a.manuscript_collab_heads(id).unwrap();
        a.commit_manuscript_body(id, &ha2, "ZERO one TWO three", "a")
            .unwrap();

        // Ship in opposite orders, and ship twice (duplicates).
        ship_chunks(&a, &b, id, true);
        ship_chunks(&b, &a, id, false);
        ship_chunks(&a, &b, id, false);

        // Touching the document re-materializes each replica's row from the
        // union of chunks — no caller text involved.
        let fa = a.manuscript_collab_heads(id).unwrap();
        let fb = b.manuscript_collab_heads(id).unwrap();
        assert_eq!(fa, fb, "same chunk set → same heads");
        let ba = body_of(&a, id);
        assert!(
            ba.contains("ZERO") && ba.contains("TWO") && ba.contains("FOUR"),
            "{ba}"
        );
        assert_eq!(ba, body_of(&b, id));

        // And a commit from a proper base on either side keeps them equal
        // once its chunk ships.
        let out = a
            .commit_manuscript_body(id, &fa, &format!("{} FIVE", ba), "a")
            .unwrap();
        assert!(!out.merged_external);
        ship_chunks(&a, &b, id, false);
        let _ = b.manuscript_collab_heads(id).unwrap();
        assert_eq!(body_of(&a, id), body_of(&b, id));
    }

    #[test]
    fn recovery_folds_legacy_writes_deterministically() {
        let a = store();
        let b = store();
        let id = manuscript(&a, "v1");
        b.insert(a.get(id).unwrap().unwrap()).unwrap();
        let _ = a.manuscript_collab_heads(id).unwrap();
        ship_chunks(&a, &b, id, false);
        let _ = b.manuscript_collab_heads(id).unwrap();

        // A legacy writer moves body_content on BOTH replicas without a
        // chunk (as an old build would, then sync would carry the row).
        for s in [&a, &b] {
            s.update(
                id,
                vec![
                    FieldMutation::SetPayload("body_content".into(), Value::String("v1 v2".into())),
                    FieldMutation::SetPayload(
                        "body_content_hash".into(),
                        Value::String(crate::manuscript_ops::sha256_hex("v1 v2")),
                    ),
                ],
            )
            .unwrap();
        }
        let ha = a.manuscript_collab_heads(id).unwrap();
        let hb = b.manuscript_collab_heads(id).unwrap();
        assert_eq!(ha, hb, "recovery must hash identically on every replica");
        // Cross-ship the recovery chunks: no duplication of "v2".
        ship_chunks(&a, &b, id, false);
        ship_chunks(&b, &a, id, false);
        let out = a.commit_manuscript_body(id, &[], "v1 v2", "a").unwrap();
        assert_eq!(out.body, "v1 v2");
        assert_eq!(body_of(&b, id), "v1 v2");
        assert_eq!(
            b.manuscript_collab_heads(id).unwrap(),
            a.manuscript_collab_heads(id).unwrap()
        );
    }

    #[test]
    fn history_and_time_travel() {
        let s = store();
        let id = manuscript(&s, "draft");
        let h0 = s.manuscript_collab_heads(id).unwrap();
        let o1 = s.commit_manuscript_body(id, &h0, "draft one", "u").unwrap();
        let _o2 = s
            .commit_manuscript_body(id, &o1.heads, "draft one two", "u")
            .unwrap();
        let history = s.manuscript_change_history(id).unwrap();
        assert_eq!(history.len(), 3, "genesis + 2 commits");
        assert_eq!(history[0].message.as_deref(), Some("genesis"));
        assert_eq!(s.manuscript_text_at(id, &h0).unwrap(), "draft");
        assert_eq!(s.manuscript_text_at(id, &o1.heads).unwrap(), "draft one");
    }

    #[test]
    fn compaction_snapshots_and_round_trips() {
        let s = store();
        let id = manuscript(&s, "");
        let mut heads = s.manuscript_collab_heads(id).unwrap();
        for i in 0..10 {
            let out = s
                .commit_manuscript_body(id, &heads, &format!("line {}", i), "u")
                .unwrap();
            heads = out.heads;
        }
        assert_eq!(chunk_count(&s, id), 11);
        let removed = s.compact_manuscript_changes(4).unwrap();
        assert_eq!(removed, 11);
        assert_eq!(chunk_count(&s, id), 1);

        // A fresh replica loading only the snapshot reads the same text and
        // heads, and can keep committing.
        let b = store();
        b.insert(s.get(id).unwrap().unwrap()).unwrap();
        ship_chunks(&s, &b, id, false);
        assert_eq!(b.manuscript_collab_heads(id).unwrap(), heads);
        let out = b
            .commit_manuscript_body(id, &heads, "line 9 more", "u")
            .unwrap();
        assert_eq!(out.body, "line 9 more");
        assert_eq!(s.manuscript_change_history(id).unwrap().len(), 11);
    }

    /// The per-keystroke hot path on a REALISTIC body (~2 MB) must stay
    /// linear and well under the editor's debounce budget: an up-to-date
    /// editor's commit is a no-fork diff against the live document, and the
    /// chunk index is read by id (never re-parsing the multi-MB genesis
    /// chunk). PMC's `ManuscriptLargeBodyPerfTests` guards the same path
    /// through the FFI; this one names the layer that owns the cost.
    #[test]
    fn large_body_commit_stays_fast() {
        let s = store();
        let paragraph = "The quick brown fox jumps over the lazy dog. ".repeat(40);
        let mut body = String::from("= A Large Manuscript\n\n");
        let mut section = 0;
        while body.len() < 2_000_000 {
            section += 1;
            body.push_str(&format!("== Section {}\n\n{}\n\n", section, paragraph));
        }
        let id = manuscript(&s, &body);
        let heads = s.manuscript_collab_heads(id).unwrap(); // genesis (untimed)

        // Release: the whole test (2 MB genesis + two commits) ran in ~1.05 s
        // on 2026-08-17. Debug builds walk Automerge's 2M-element text an
        // order of magnitude slower, so the debug budget only has to catch a
        // super-linear regression (which would be minutes, not seconds).
        let budget = if cfg!(debug_assertions) { 8.0 } else { 1.0 };

        let edited = format!("{}\n\n== Appended\n\nOne more paragraph.", body);
        let start = std::time::Instant::now();
        let out = s.commit_manuscript_body(id, &heads, &edited, "u").unwrap();
        let elapsed = start.elapsed();
        assert!(!out.merged_external);
        assert!(
            elapsed.as_secs_f64() < budget,
            "2 MB up-to-date commit took {:.3}s (budget {budget}s)",
            elapsed.as_secs_f64()
        );
        // And a second edit from the new base is just as fast (the index now
        // holds two multi-MB chunks that must NOT be re-parsed).
        let start = std::time::Instant::now();
        let edited2 = format!("{} Again.", edited);
        s.commit_manuscript_body(id, &out.heads, &edited2, "u")
            .unwrap();
        assert!(
            start.elapsed().as_secs_f64() < budget,
            "second 2 MB commit took {:.3}s (budget {budget}s)",
            start.elapsed().as_secs_f64()
        );
    }

    #[test]
    fn chunks_are_immutable() {
        let s = store();
        let id = manuscript(&s, "x");
        let _ = s.manuscript_collab_heads(id).unwrap();
        let chunk = s.manuscript_chunks(id).unwrap().remove(0);
        let err = s
            .update(
                chunk.id,
                vec![FieldMutation::SetPayload(
                    "bytes_b64".into(),
                    Value::String("AA==".into()),
                )],
            )
            .unwrap_err();
        assert!(err.to_string().contains("immutable"), "{err}");
    }

    #[test]
    fn body_equals_document_after_every_verb() {
        let s = store();
        let id = manuscript(&s, "start");
        let h = s.manuscript_collab_heads(id).unwrap();
        let o = s
            .commit_manuscript_body(id, &h, "start middle", "u")
            .unwrap();
        s.compact_manuscript_changes(2).unwrap();
        let text = s.manuscript_text_at(id, &o.heads).unwrap();
        assert_eq!(text, body_of(&s, id));
    }
}
