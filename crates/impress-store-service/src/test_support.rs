//! Shared test fixtures: an in-memory store and a way to put items in it.
//!
//! The services take their store by injection (`with_store`), so every test
//! runs against a private database and none of them can reach the real one.

use std::collections::BTreeMap;
use std::sync::Arc;

use impress_core::item::{Item, Priority, Value, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::ItemStore;

/// A fresh, private, in-memory store.
pub fn test_store() -> Arc<SqliteItemStore> {
    Arc::new(SqliteItemStore::open_in_memory().expect("open in-memory store"))
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
