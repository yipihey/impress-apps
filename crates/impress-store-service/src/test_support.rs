//! Shared test fixtures: an in-memory store, a way to put items in it, and a
//! self-cleaning scratch directory.
//!
//! The services take their store by injection (`with_store`), so every test
//! runs against a private database and none of them can reach the real one.
//! The scratch directory is the same rule for the filesystem: every test that
//! needs files on disk makes its own tree under the OS temp dir and removes it
//! on drop, so no test can read — let alone write — a real library.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use impress_core::item::{Item, Priority, Value, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;

/// A fresh, private, in-memory store.
pub fn test_store() -> Arc<SqliteItemStore> {
    Arc::new(SqliteItemStore::open_in_memory().expect("open in-memory store"))
}

/// A temp directory that cleans itself up. No dev-dependency for a dozen lines
/// of `std::fs`, and no test ever names a path outside the OS temp dir.
pub struct ScratchDir(PathBuf);

impl ScratchDir {
    pub fn new(tag: &str) -> Self {
        let dir = std::env::temp_dir().join(format!(
            "impress-store-service-{tag}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir_all(&dir).expect("create scratch dir");
        Self(dir)
    }

    /// Write (or overwrite) a file, creating parents. Returns its absolute path.
    pub fn write(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.0.join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create parent");
        }
        fs::write(&path, contents).expect("write file");
        path
    }

    /// Delete a file from the tree — how a test makes a discovered file vanish.
    pub fn remove(&self, name: &str) {
        let _ = fs::remove_file(self.0.join(name));
    }

    /// The absolute path of a member, whether or not it exists.
    pub fn join(&self, name: &str) -> String {
        self.0.join(name).to_string_lossy().to_string()
    }

    /// Remove the whole tree — how a test simulates an unmounted volume.
    pub fn destroy(&self) {
        let _ = fs::remove_dir_all(&self.0);
    }

    pub fn path(&self) -> String {
        self.0.to_string_lossy().to_string()
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Insert a bare item of `schema` and return its lowercase UUID string.
pub fn make_item(store: &SqliteItemStore, schema: &str) -> String {
    make_item_named(store, schema, "Untitled")
}

/// Insert an item of `schema` with a `title` payload field.
pub fn make_item_named(store: &SqliteItemStore, schema: &str, title: &str) -> String {
    let now = chrono::Utc::now();
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("title".into(), Value::String(title.into()));
    let item = Item {
        id: uuid::Uuid::new_v4(),
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "impress-store-service-tests".into(),
        author_kind: impress_core::item::ActorKind::System,
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
    store.insert(item).expect("insert item").to_string()
}
