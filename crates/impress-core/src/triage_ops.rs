//! Generic triage primitives (ADR-0022 D5).
//!
//! Star, flag, tag and status over *any* item, regardless of which app wrote
//! it. Everything here is a two-line wrapper over [`FieldMutation`] — the
//! point is not the implementation but having one named place where the
//! store-agnostic triage verbs live, so the `#[impress_service]` twin of the
//! GUI triage menu does not have to reach into `imbib-core` (a publication
//! store) to star a manuscript.
//!
//! ## The `status` field
//!
//! `status` is a free-form payload string with no Rust validation — impart's
//! and impel's schemas must stay free to use their own vocabularies. Two
//! values are reserved chassis-wide ([`STATUS_DISMISSED`],
//! [`STATUS_ARCHIVED`]); see `docs/status-lifecycle.md`.
//!
//! **Publications are the documented exception**: imbib dismisses a paper by
//! moving it to the Dismissed *library*, not by writing `status`, and the
//! "dismissed papers must never re-enter the inbox" invariant is enforced on
//! that library move. [`set_status`] on a publication would therefore write a
//! field nothing reads. Use imbib-core's own dismissal ops for papers.

use uuid::Uuid;

use crate::item::{FlagState, ItemId, Value};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{FieldMutation, ItemStore, StoreError};

/// Payload field carrying the cross-schema lifecycle status.
pub const STATUS_FIELD: &str = "status";

/// Reserved status: swept out of the working set, hidden from every scope
/// except Dismissed. Never destructive.
pub const STATUS_DISMISSED: &str = "dismissed";

/// Reserved status: a deliberate end-state for finished work. Listed under
/// Archive; restorable.
pub const STATUS_ARCHIVED: &str = "archived";

/// Star or unstar an item.
pub fn set_starred(store: &SqliteItemStore, id: &str, starred: bool) -> Result<(), StoreError> {
    store.update(parse_id(id)?, vec![FieldMutation::SetStarred(starred)])
}

/// Mark an item read or unread.
pub fn set_read(store: &SqliteItemStore, id: &str, read: bool) -> Result<(), StoreError> {
    store.update(parse_id(id)?, vec![FieldMutation::SetRead(read)])
}

/// Set an item's flag colour, or clear it with `None` (or an empty string).
///
/// Style and length are left at their defaults; the GUI's flag styling is a
/// presentation concern the triage verb does not need.
pub fn set_flag(store: &SqliteItemStore, id: &str, color: Option<&str>) -> Result<(), StoreError> {
    let flag = color
        .map(str::trim)
        .filter(|c| !c.is_empty())
        .map(|c| FlagState {
            color: c.to_string(),
            style: None,
            length: None,
        });
    store.update(parse_id(id)?, vec![FieldMutation::SetFlag(flag)])
}

/// Add a tag path to an item. Idempotent — the store deduplicates.
pub fn add_tag(store: &SqliteItemStore, id: &str, tag: &str) -> Result<(), StoreError> {
    let tag = tag.trim();
    if tag.is_empty() {
        return Err(StoreError::Validation("tag must not be empty".into()));
    }
    store.update(parse_id(id)?, vec![FieldMutation::AddTag(tag.to_string())])
}

/// Remove a tag path from an item. A tag the item does not carry is a no-op.
pub fn remove_tag(store: &SqliteItemStore, id: &str, tag: &str) -> Result<(), StoreError> {
    let tag = tag.trim();
    if tag.is_empty() {
        return Err(StoreError::Validation("tag must not be empty".into()));
    }
    store.update(
        parse_id(id)?,
        vec![FieldMutation::RemoveTag(tag.to_string())],
    )
}

/// Set (or clear, with `None`) the payload `status` string.
///
/// No validation: `status` is schema-owned free-form text apart from the two
/// reserved values above. See the module docs for why publications do not go
/// through here.
pub fn set_status(
    store: &SqliteItemStore,
    id: &str,
    status: Option<&str>,
) -> Result<(), StoreError> {
    let id = parse_id(id)?;
    let mutation = match status.map(str::trim).filter(|s| !s.is_empty()) {
        Some(s) => FieldMutation::SetPayload(STATUS_FIELD.into(), Value::String(s.to_string())),
        None => FieldMutation::RemovePayload(STATUS_FIELD.into()),
    };
    store.update(id, vec![mutation])
}

/// Read back an item's status, if it has one.
pub fn status(store: &SqliteItemStore, id: &str) -> Result<Option<String>, StoreError> {
    let id = parse_id(id)?;
    let item = store.get(id)?.ok_or(StoreError::NotFound(id))?;
    Ok(match item.payload.get(STATUS_FIELD) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    })
}

fn parse_id(id: &str) -> Result<ItemId, StoreError> {
    Uuid::parse_str(id).map_err(|_| StoreError::Validation(format!("invalid UUID: {id}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{Item, Priority, Visibility};
    use chrono::Utc;
    use std::collections::BTreeMap;

    fn open() -> SqliteItemStore {
        SqliteItemStore::open_in_memory().expect("open in-memory store")
    }

    fn make_item(store: &SqliteItemStore, schema: &str) -> String {
        let now = Utc::now();
        let item = Item {
            id: Uuid::new_v4(),
            schema: schema.into(),
            payload: BTreeMap::new(),
            created: now,
            modified: now,
            author: store.default_author.clone(),
            author_kind: store.default_author_kind,
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
}
