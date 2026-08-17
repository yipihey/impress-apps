//! `ManuscriptCollabService` — the manuscript body as a collaborative
//! document, for agents (ADR-0027 D6).
//!
//! An agent that edits a manuscript body is one more concurrent writer, and
//! it gets the same contract the editors do: read the current `heads`, send
//! its text with those heads as `base_heads`, and receive the MERGED body
//! plus the heads to send next. A stale base never overwrites — the agent's
//! edits land beside the human's. Thin wrappers over
//! `impress_core::collab` on the shared store; the same verbs `ImbibStore`
//! and `SharedStore` expose over the FFI, so Swift, the CLI and an agent
//! share one vocabulary.
//!
//! Watched-folder manuscripts (`external_source`, ADR-0023 D4) are indexes of
//! files the user edits elsewhere; committing to them is refused, because the
//! file — not the store — is their truth.

use std::sync::Arc;

use impress_core::item::ItemId;
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

use crate::store::store_instance;

/// Outcome of a body commit.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollabCommitResult {
    pub ok: bool,
    /// The manuscript id, echoed back.
    pub id: String,
    /// The document heads AFTER this commit — send these as `base_heads`
    /// with the next commit.
    pub heads: Vec<String>,
    /// The MERGED body. Differs from what was sent whenever another writer's
    /// edits were folded in (`merged_external`); an agent that keeps a local
    /// copy must adopt it.
    pub body: String,
    pub body_hash: String,
    pub merged_external: bool,
    pub message: String,
}

/// The document's current heads.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollabHeadsResult {
    pub ok: bool,
    pub id: String,
    pub heads: Vec<String>,
    pub message: String,
}

/// One change in a manuscript body's history.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollabChange {
    /// Hex change hash — a valid entry for `base_heads` / `text_at`.
    pub hash: String,
    /// Automerge actor id (hex); random per commit for typed edits.
    pub actor: String,
    /// Seconds since the epoch; 0 for the deterministic genesis/recovery
    /// changes.
    pub time: i64,
    /// The commit message — the author string the writer passed
    /// (`user:local`, `agent:http`, an agent id) or `genesis` / `recovery`.
    pub message: Option<String>,
    pub deps: Vec<String>,
}

/// A manuscript body's per-change history, oldest first.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollabHistoryResult {
    pub ok: bool,
    pub id: String,
    pub heads: Vec<String>,
    pub changes: Vec<CollabChange>,
    pub message: String,
}

/// The body as of some heads (time travel).
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollabTextAtResult {
    pub ok: bool,
    pub id: String,
    pub heads: Vec<String>,
    pub body: String,
    pub message: String,
}

/// Commit, inspect and time-travel a manuscript body's collaborative
/// document (ADR-0027). Every id is a lowercase manuscript UUID string.
#[impress_service]
pub trait ManuscriptCollabService: Send + Sync + 'static {
    /// The document's current heads — what to send as `base_heads` with your
    /// first commit. Migrates a never-touched manuscript (deterministic
    /// genesis from its current body).
    #[impress_method]
    async fn manuscript_heads(&self, id: String) -> CollabHeadsResult;

    /// Commit `body` to the manuscript's document. `base_heads` are the heads
    /// you last saw (from `manuscript_heads` or a previous commit); your text
    /// is diffed against the document AT THAT BASE and MERGED, so edits made
    /// meanwhile by a human or another agent survive beside yours. An empty
    /// `base_heads` diffs against the current text (last-writer for
    /// overlapping regions, no loss elsewhere). `author` labels the change in
    /// history (e.g. your agent id). Refused for watched-folder manuscripts.
    #[impress_method]
    async fn commit_manuscript_body(
        &self,
        id: String,
        base_heads: Vec<String>,
        body: String,
        author: String,
    ) -> CollabCommitResult;

    /// The body's per-change history, oldest first, plus the current heads.
    #[impress_method]
    async fn manuscript_change_history(&self, id: String) -> CollabHistoryResult;

    /// The body as it read at `heads` (any hashes from the history) — time
    /// travel without changing anything.
    #[impress_method]
    async fn manuscript_text_at(&self, id: String, heads: Vec<String>) -> CollabTextAtResult;
}

// ---------------------------------------------------------------------------
// Implementation
// ---------------------------------------------------------------------------

/// Store-backed `ManuscriptCollabService`. `new()` uses the shared store
/// (opened lazily); `with_store` takes an explicit one, as the tests do.
#[derive(Clone, Default)]
pub struct DefaultManuscriptCollabService {
    store: Option<Arc<SqliteItemStore>>,
}

impl DefaultManuscriptCollabService {
    pub fn new() -> Self {
        Self { store: None }
    }

    pub fn with_store(store: Arc<SqliteItemStore>) -> Self {
        Self { store: Some(store) }
    }

    fn store(&self) -> Arc<SqliteItemStore> {
        self.store.clone().unwrap_or_else(store_instance)
    }

    fn parse(id: &str) -> Result<ItemId, StoreError> {
        id.parse::<ItemId>()
            .map_err(|_| StoreError::Validation(format!("invalid manuscript UUID: {id}")))
    }

    /// Watched-folder manuscripts are indexes of files edited elsewhere
    /// (ADR-0023 D4/W3): the file is the truth, so nothing may commit to the
    /// store copy behind its back.
    fn refuse_external(store: &SqliteItemStore, id: ItemId) -> Result<(), StoreError> {
        let item = store.get(id)?.ok_or(StoreError::NotFound(id))?;
        if item.payload.contains_key("external_source") {
            return Err(StoreError::Validation(format!(
                "manuscript {id} is a watched-folder file (external_source); edit the file, \
                 not the store copy"
            )));
        }
        Ok(())
    }
}

#[async_trait::async_trait]
impl ManuscriptCollabService for DefaultManuscriptCollabService {
    async fn manuscript_heads(&self, id: String) -> CollabHeadsResult {
        let outcome = Self::parse(&id).and_then(|uuid| self.store().manuscript_collab_heads(uuid));
        match outcome {
            Ok(heads) => CollabHeadsResult {
                ok: true,
                id,
                heads,
                message: "Current heads; send them as base_heads with your commit.".into(),
            },
            Err(e) => CollabHeadsResult {
                ok: false,
                id,
                heads: vec![],
                message: e.to_string(),
            },
        }
    }

    async fn commit_manuscript_body(
        &self,
        id: String,
        base_heads: Vec<String>,
        body: String,
        author: String,
    ) -> CollabCommitResult {
        let store = self.store();
        let author = if author.trim().is_empty() {
            "agent".to_string()
        } else {
            author
        };
        let outcome = Self::parse(&id).and_then(|uuid| {
            Self::refuse_external(&store, uuid)?;
            store.commit_manuscript_body(uuid, &base_heads, &body, &author)
        });
        match outcome {
            Ok(out) => CollabCommitResult {
                ok: true,
                id,
                message: if out.merged_external {
                    "Committed; another writer's edits were merged in — adopt `body`.".into()
                } else {
                    "Committed.".into()
                },
                heads: out.heads,
                body: out.body,
                body_hash: out.body_hash,
                merged_external: out.merged_external,
            },
            Err(e) => CollabCommitResult {
                ok: false,
                id,
                heads: vec![],
                body: String::new(),
                body_hash: String::new(),
                merged_external: false,
                message: e.to_string(),
            },
        }
    }

    async fn manuscript_change_history(&self, id: String) -> CollabHistoryResult {
        let store = self.store();
        let outcome = Self::parse(&id).and_then(|uuid| {
            let heads = store.manuscript_collab_heads(uuid)?;
            let changes = store.manuscript_change_history(uuid)?;
            Ok((heads, changes))
        });
        match outcome {
            Ok((heads, changes)) => CollabHistoryResult {
                ok: true,
                id,
                heads,
                message: format!("{} change(s).", changes.len()),
                changes: changes
                    .into_iter()
                    .map(|c| CollabChange {
                        hash: c.hash,
                        actor: c.actor,
                        time: c.time,
                        message: c.message,
                        deps: c.deps,
                    })
                    .collect(),
            },
            Err(e) => CollabHistoryResult {
                ok: false,
                id,
                heads: vec![],
                changes: vec![],
                message: e.to_string(),
            },
        }
    }

    async fn manuscript_text_at(&self, id: String, heads: Vec<String>) -> CollabTextAtResult {
        let outcome =
            Self::parse(&id).and_then(|uuid| self.store().manuscript_text_at(uuid, &heads));
        match outcome {
            Ok(body) => CollabTextAtResult {
                ok: true,
                id,
                heads,
                body,
                message: "Body as of the given heads.".into(),
            },
            Err(e) => CollabTextAtResult {
                ok: false,
                id,
                heads,
                body: String::new(),
                message: e.to_string(),
            },
        }
    }
}

impress_service_impl! {
    service = ManuscriptCollabService,
    impl = DefaultManuscriptCollabService,
    instance = DefaultManuscriptCollabService::new,
    methods = [
        manuscript_heads(id: String) -> CollabHeadsResult,
        commit_manuscript_body(id: String, base_heads: Vec<String>, body: String, author: String) -> CollabCommitResult,
        manuscript_change_history(id: String) -> CollabHistoryResult,
        manuscript_text_at(id: String, heads: Vec<String>) -> CollabTextAtResult,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::test_store;
    use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
    use std::collections::BTreeMap;

    fn manuscript(store: &SqliteItemStore, body: &str, external: bool) -> String {
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String("Paper".into()));
        payload.insert("format".into(), Value::String("typst".into()));
        payload.insert("body_content".into(), Value::String(body.into()));
        payload.insert(
            "body_content_hash".into(),
            Value::String(impress_core::manuscript_ops::sha256_hex(body)),
        );
        if external {
            payload.insert(
                "external_source".into(),
                Value::String("/Users/x/docs/paper.md".into()),
            );
        }
        let now = chrono::Utc::now();
        let item = Item {
            id: uuid::Uuid::new_v4(),
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
        store.insert(item).unwrap().to_string()
    }

    #[tokio::test]
    async fn stale_base_commits_merge_through_the_service() {
        let store = test_store();
        let s = DefaultManuscriptCollabService::with_store(store.clone());
        let id = manuscript(&store, "The quick brown fox.", false);

        let base = s.manuscript_heads(id.clone()).await;
        assert!(base.ok && !base.heads.is_empty());
        let a = s
            .commit_manuscript_body(
                id.clone(),
                base.heads.clone(),
                "Note: The quick brown fox.".into(),
                "agent:a".into(),
            )
            .await;
        assert!(a.ok && !a.merged_external);
        let b = s
            .commit_manuscript_body(
                id.clone(),
                base.heads,
                "The quick brown fox. Jumps.".into(),
                "agent:b".into(),
            )
            .await;
        assert!(b.ok && b.merged_external, "{}", b.message);
        assert_eq!(b.body, "Note: The quick brown fox. Jumps.");

        let history = s.manuscript_change_history(id.clone()).await;
        assert!(history.ok);
        assert_eq!(history.changes.len(), 3, "genesis + a + b");
        assert_eq!(history.changes[1].message.as_deref(), Some("agent:a"));
        let at = s
            .manuscript_text_at(id, vec![history.changes[1].hash.clone()])
            .await;
        assert!(at.ok);
        assert_eq!(at.body, "Note: The quick brown fox.");
    }

    #[tokio::test]
    async fn watched_folder_manuscripts_are_refused_and_bad_ids_report() {
        let store = test_store();
        let s = DefaultManuscriptCollabService::with_store(store.clone());
        let id = manuscript(&store, "indexed file", true);
        let out = s
            .commit_manuscript_body(id, vec![], "edited".into(), "agent".into())
            .await;
        assert!(!out.ok);
        assert!(out.message.contains("external_source"), "{}", out.message);

        let bad = s.manuscript_heads("not-a-uuid".into()).await;
        assert!(!bad.ok);
    }
}
