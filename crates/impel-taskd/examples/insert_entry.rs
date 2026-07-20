//! Insert a bibliography-entry into a workspace store — from a separate
//! process, the way imbib does it. Smoke-test companion for impel-taskd.
//!
//! Usage: cargo run -p impel-taskd --example insert_entry -- <workspace-dir> <doi> <title...>

use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, Priority, Value, Visibility};
use impress_core::sqlite_store::{SqliteItemStore, StoreConfig};
use impress_core::store::ItemStore;
use uuid::Uuid;

fn main() {
    let mut args = std::env::args().skip(1);
    let workspace = args.next().expect("workspace dir");
    let doi = args.next().expect("doi");
    let title: String = args.collect::<Vec<_>>().join(" ");

    let store = SqliteItemStore::open_with_config(
        &std::path::Path::new(&workspace).join("impress.sqlite"),
        StoreConfig {
            author: "tom".into(),
            author_kind: ActorKind::Human,
            ..StoreConfig::default()
        },
    )
    .expect("open store");

    let mut payload = BTreeMap::new();
    payload.insert("title".into(), Value::String(title.clone()));
    payload.insert("doi".into(), Value::String(doi.clone()));
    let item = Item {
        id: Uuid::new_v4(),
        schema: "bibliography-entry@1.0.0".into(),
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: "tom".into(),
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
    let id = store.insert(item).expect("insert");
    println!("inserted bibliography-entry {id} (doi={doi}, title=\"{title}\")");
}
