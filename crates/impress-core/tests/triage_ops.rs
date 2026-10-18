//! The triage kernel over SQLite. The kernel itself lives in koine
//! (`koine-triage`, tested there over the memory and directory stores); this
//! pins that impress-core's re-export still works on `SqliteItemStore`.
#![cfg(feature = "sqlite")]

use chrono::Utc;
use std::collections::BTreeMap;

use impress_core::item::{Item, Priority, Visibility};
use impress_core::sqlite_store::SqliteItemStore;
use impress_core::store::{ItemStore, StoreError};
use impress_core::triage_ops::*;
use uuid::Uuid;

fn open() -> SqliteItemStore {
    SqliteItemStore::open_in_memory().expect("open in-memory store")
}

fn make_item(store: &SqliteItemStore, schema: &str) -> String {
    let now = Utc::now();
    let item = Item {
        id: Uuid::new_v4(),
        schema: impress_core::SchemaRef::from_stored(schema.to_owned()),
        payload: BTreeMap::new(),
        created: now,
        modified: now,
        author: "test".into(),
        author_kind: impress_core::item::ActorKind::Human,
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
        extra: Default::default(),
    };
    store.insert(item).expect("insert").to_string()
}

fn get(store: &SqliteItemStore, id: &str) -> Item {
    store
        .get(Uuid::parse_str(id).unwrap())
        .unwrap()
        .expect("item present")
}

#[test]
fn star_flag_tag_status_round_trip() {
    let store = open();
    let id = make_item(&store, "manuscript");

    set_starred(&store, &id, true).unwrap();
    assert!(get(&store, &id).is_starred);
    set_starred(&store, &id, false).unwrap();
    assert!(!get(&store, &id).is_starred);

    set_flag(&store, &id, Some("red")).unwrap();
    assert_eq!(get(&store, &id).flag.map(|f| f.color), Some("red".into()));
    set_flag(&store, &id, None).unwrap();
    assert!(get(&store, &id).flag.is_none());
    // An empty colour clears rather than storing "".
    set_flag(&store, &id, Some("blue")).unwrap();
    set_flag(&store, &id, Some("  ")).unwrap();
    assert!(get(&store, &id).flag.is_none());

    add_tag(&store, &id, "reading/queue").unwrap();
    assert!(get(&store, &id).tags.contains(&"reading/queue".to_string()));
    remove_tag(&store, &id, "reading/queue").unwrap();
    assert!(!get(&store, &id).tags.contains(&"reading/queue".to_string()));
    // Removing a tag the item never had is a no-op, not an error.
    remove_tag(&store, &id, "never/applied").unwrap();

    set_status(&store, &id, Some(STATUS_ARCHIVED)).unwrap();
    assert_eq!(status(&store, &id).unwrap().as_deref(), Some("archived"));
    set_status(&store, &id, Some(STATUS_DISMISSED)).unwrap();
    assert_eq!(status(&store, &id).unwrap().as_deref(), Some("dismissed"));
    set_status(&store, &id, None).unwrap();
    assert_eq!(status(&store, &id).unwrap(), None);
}

#[test]
fn status_is_free_form() {
    let store = open();
    let id = make_item(&store, "task");
    // No Rust validation: schema-owned vocabularies must keep working.
    set_status(&store, &id, Some("waiting_review")).unwrap();
    assert_eq!(
        status(&store, &id).unwrap().as_deref(),
        Some("waiting_review")
    );
}

#[test]
fn triage_is_schema_agnostic() {
    let store = open();
    for schema in ["manuscript", "figure", "email-message", "task"] {
        let id = make_item(&store, schema);
        set_starred(&store, &id, true).unwrap();
        add_tag(&store, &id, "triage").unwrap();
        assert!(get(&store, &id).is_starred, "{schema} could not be starred");
    }
}

#[test]
fn missing_and_malformed_ids_error() {
    let store = open();
    let missing = Uuid::new_v4().to_string();
    assert!(matches!(
        set_starred(&store, &missing, true),
        Err(StoreError::NotFound(_))
    ));
    assert!(matches!(
        set_status(&store, "not-a-uuid", Some("archived")),
        Err(StoreError::Validation(_))
    ));
    let id = make_item(&store, "manuscript");
    assert!(matches!(
        add_tag(&store, &id, "  "),
        Err(StoreError::Validation(_))
    ));
}
