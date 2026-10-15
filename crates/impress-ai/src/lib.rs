//! Provenance-first AI infrastructure for the Impress suite.
//!
//! The AI kernel is koine's (`koine-ai`, koine docs/plan-koine-ai-tasks.md
//! AI-D1): the providers, the catalogue, the registry and
//! `<workspace>/ai/preferences.json`, the conversation store over the store
//! port, the task executors and the desk agent. This crate re-exports it, so
//! every `impress_ai::` path in the suite is unchanged, and adds what is
//! impress's own:
//!
//! * [`migration`]: the one-time LocalModels import;
//! * [`AiStoreSqlite`]: `AiStore::open` over the suite's SQLite store, and
//!   the typed handle back for the callers that need SQLite's own methods.

pub use koine_ai::*;

pub mod migration;

pub use migration::{migrate_localmodels, LocalModelsMigrationReport};

use std::path::Path;
use std::sync::Arc;

use impress_core::item::ActorKind;
use impress_core::sqlite_store::{SqliteItemStore, StoreConfig};

/// `AiStore` over the suite's SQLite store.
pub trait AiStoreSqlite: Sized {
    /// Open (or create) the SQLite store at `path` and the kernel over it,
    /// writing as `actor` (`actor_kind` attributes the store's own writes).
    fn open(path: &Path, actor: impl Into<String>, actor_kind: ActorKind) -> Result<Self>;

    /// The SQLite store underneath. Every `AiStore` this suite builds is over
    /// one ([`Self::open`], or `AiStore::from_store` with an
    /// `Arc<SqliteItemStore>`); a kernel over another backend panics here,
    /// naming the caller's mistake.
    fn sqlite_store(&self) -> Arc<SqliteItemStore>;
}

impl AiStoreSqlite for AiStore {
    fn open(path: &Path, actor: impl Into<String>, actor_kind: ActorKind) -> Result<Self> {
        let actor = actor.into();
        let store = SqliteItemStore::open_with_config(
            path,
            StoreConfig {
                author: actor.clone(),
                author_kind: actor_kind,
                tag_namespace: "ai".into(),
            },
        )?;
        Ok(AiStore::from_store(Arc::new(store), actor))
    }

    fn sqlite_store(&self) -> Arc<SqliteItemStore> {
        self.backing::<SqliteItemStore>()
            .expect("this AiStore is not over SQLite; build it with AiStoreSqlite::open")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_opened_store_is_sqlite_and_keeps_conversations() {
        let directory = tempfile::tempdir().unwrap();
        let ai = AiStore::open(
            &directory.path().join("impress.sqlite"),
            "test:sqlite",
            ActorKind::Human,
        )
        .unwrap();
        let id = ai
            .create_conversation(ConversationDraft {
                title: "Over SQLite".into(),
                provider: "omlx".into(),
                model: "m".into(),
                ..ConversationDraft::default()
            })
            .unwrap();
        assert!(ai
            .list_conversations(false)
            .unwrap()
            .iter()
            .any(|c| c.id == id));
        let sqlite = ai.sqlite_store();
        let port: Arc<dyn impress_core::store::AttributedStore> = ai.shared_store();
        assert_eq!(
            impress_core::store::ItemStore::get(sqlite.as_ref(), id)
                .unwrap()
                .map(|c| c.id),
            port.get(id).unwrap().map(|c| c.id)
        );
    }
}
